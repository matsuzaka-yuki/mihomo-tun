import importlib.util
import tempfile
import types
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/configure-direct-rules.py"


def load_module():
    spec = importlib.util.spec_from_file_location("configure_direct_rules", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.args = types.SimpleNamespace(rules_path="/tmp/noctalia-direct.yaml")
    return module


class ConfigureDirectRulesTests(unittest.TestCase):
    def test_inserts_provider_and_rule(self):
        module = load_module()
        source = """mode: rule
proxy-groups:
  - name: PROXY
    type: select
rules:
  - GEOSITE,cn,DIRECT
  - MATCH,PROXY
"""
        rendered = module.render_config(source)
        self.assertIn("rule-providers:", rendered)
        self.assertIn("noctalia-direct:", rendered)
        self.assertIn("RULE-SET,noctalia-direct,DIRECT", rendered)
        self.assertLess(
            rendered.index("RULE-SET,noctalia-direct,DIRECT"),
            rendered.index("GEOSITE,cn,DIRECT"),
        )

    def test_is_idempotent(self):
        module = load_module()
        source = """rule-providers:
  existing:
    type: file
proxy-groups:
  - name: PROXY
rules:
  - MATCH,PROXY
"""
        once = module.render_config(source)
        twice = module.render_config(once)
        self.assertEqual(once, twice)

    def test_prepares_provider_under_config_directory(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.yaml"
            config.write_text("rules:\n  - MATCH,PROXY\n", encoding="utf-8")
            rules_path = Path(tmp) / "noctalia/direct-rules.yaml"
            module.args = types.SimpleNamespace(rules_path=str(rules_path))
            module.prepare_rules_path(config)
            self.assertTrue(rules_path.is_file())
            self.assertIn("payload: []", rules_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
