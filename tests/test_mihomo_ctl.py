import http.server
import json
import os
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "scripts/mihomo-ctl.py"


class FakeController(http.server.ThreadingHTTPServer):
    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.requests = []


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        return

    def _body(self):
        length = int(self.headers.get("Content-Length", "0"))
        return self.rfile.read(length) if length else b""

    def _json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlsplit(self.path)
        self.server.requests.append((self.command, parsed.path, dict(self.headers)))
        path = unquote(parsed.path)
        if path == "/version":
            self._json({"version": "v1.19.31"})
        elif path == "/configs":
            self._json({"mode": "rule"})
        elif path == "/proxies":
            self._json(
                {
                    "proxies": {
                        "AUTO": {"type": "URLTest", "now": "node-a", "all": ["node-a"]},
                        "PROXY": {"type": "Selector", "now": "AUTO", "all": ["AUTO", "node-a", "DIRECT"]},
                        "node-a": {"type": "Shadowsocks"},
                        "DIRECT": {"type": "Direct"},
                    }
                }
            )
        elif path == "/proxies/PROXY":
            self._json({"type": "Selector", "now": "AUTO", "all": ["AUTO", "node-a", "DIRECT"]})
        elif path == "/proxies/AUTO":
            self._json({"type": "URLTest", "now": "node-a", "all": ["node-a"]})
        elif path == "/group/PROXY/delay":
            query = parse_qs(parsed.query)
            self.assert_url = query.get("url", [""])[0]
            self._json({"node-a": 42})
        else:
            self._json({"message": "not found"}, status=404)

    def do_PATCH(self):
        parsed = urlsplit(self.path)
        body = self._body()
        self.server.requests.append((self.command, parsed.path, dict(self.headers), body))
        self._json({})

    def do_PUT(self):
        parsed = urlsplit(self.path)
        body = self._body()
        self.server.requests.append((self.command, parsed.path, dict(self.headers), body))
        self._json({})


class CliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = FakeController()
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.controller = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join(timeout=5)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.secret_file = root / "secret"
        self.secret_file.write_text("test-secret\n", encoding="utf-8")
        self.systemctl_log = root / "systemctl.log"
        bin_dir = root / "bin"
        bin_dir.mkdir()
        systemctl = bin_dir / "systemctl"
        systemctl.write_text(
            """#!/bin/sh
printf '%s %s\\n' "$1" "$2" >> "$FAKE_SYSTEMCTL_LOG"
if [ "$1" = "is-active" ]; then
  printf '%s\\n' "${FAKE_SYSTEMCTL_STATE:-active}"
  [ "${FAKE_SYSTEMCTL_STATE:-active}" = "active" ]
  exit $?
fi
exit 0
""",
            encoding="utf-8",
        )
        systemctl.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(
            {
                "PATH": f"{bin_dir}:{self.env['PATH']}",
                "MIHOMO_CONTROLLER": self.controller,
                "MIHOMO_SECRET_FILE": str(self.secret_file),
                "MIHOMO_UNIT": "mihomo.service",
                "FAKE_SYSTEMCTL_LOG": str(self.systemctl_log),
                "FAKE_SYSTEMCTL_STATE": "active",
                "MIHOMO_MAX_NODES": "80",
            }
        )

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *args):
        completed = subprocess.run(
            ["python3", str(CLI), *args],
            capture_output=True,
            text=True,
            env=self.env,
            check=False,
        )
        payload = json.loads(completed.stdout)
        return completed, payload

    def test_status_uses_secret_auth_and_returns_nodes(self):
        completed, payload = self.run_cli("status")
        self.assertEqual(completed.returncode, 0)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["mode"], "rule")
        self.assertTrue(payload["now"].startswith("AUTO"))
        self.assertEqual([node["name"] for node in payload["nodes"]], ["node-a"])
        self.assertTrue(
            all(
                request[2].get("Authorization") == "Bearer test-secret"
                for request in self.server.requests
                if request[1] != "/group/PROXY/delay"
            )
        )

    def test_mode_patch(self):
        completed, payload = self.run_cli("mode", "global")
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(payload["mode"], "global")
        request = next(item for item in self.server.requests if item[0] == "PATCH")
        self.assertEqual(json.loads(request[3]), {"mode": "global"})

    def test_select_put(self):
        completed, payload = self.run_cli("select", "PROXY", "node-a")
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(payload["now"], "node-a")
        request = next(item for item in self.server.requests if item[0] == "PUT" and item[1] == "/proxies/PROXY")
        self.assertEqual(json.loads(request[3]), {"name": "node-a"})

    def test_group_and_delay(self):
        completed, group = self.run_cli("group", "PROXY")
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(group["nodes"], ["AUTO", "node-a"])
        completed, delay = self.run_cli("delay", "PROXY")
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(delay["results"], [{"name": "node-a", "delay": 42}])

    def test_secret_is_returned_without_logging(self):
        completed, payload = self.run_cli("secret")
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(payload["secret"], "test-secret")
        self.assertNotIn("test-secret", completed.stderr)

    def test_toggle_stops_active_service(self):
        completed, payload = self.run_cli("toggle")
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(payload["verb"], "stop")
        self.assertIn("stop mihomo.service", self.systemctl_log.read_text(encoding="utf-8"))

    def test_toggle_starts_inactive_service(self):
        self.env["FAKE_SYSTEMCTL_STATE"] = "inactive"
        completed, payload = self.run_cli("toggle")
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(payload["verb"], "start")
        self.assertIn("start mihomo.service", self.systemctl_log.read_text(encoding="utf-8"))

    def test_unknown_command_fails_as_json(self):
        completed, payload = self.run_cli("not-a-command")
        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(payload["ok"])
        self.assertIn("未知子命令", payload["error"])


if __name__ == "__main__":
    unittest.main()
