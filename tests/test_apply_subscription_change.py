import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/apply-subscription-change.py"


def load_module():
    spec = importlib.util.spec_from_file_location("apply_subscription_change", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ApplySubscriptionChangeTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()
        self.source = """mode: rule
proxy-providers:
  airport:
    type: http
    url: "https://old.example/sub"
    path: ./providers/airport.yaml
proxy-groups:
  - name: PROXY
    type: select
rules:
  - MATCH,PROXY
"""

    def test_upsert_preserves_existing_provider(self):
        lines = self.module.upsert_provider(self.source.splitlines(), "backup", "https://new.example/sub")
        text = "\n".join(lines) + "\n"
        self.assertIn("  airport:", text)
        self.assertIn("  backup:", text)
        self.assertIn("https://new.example/sub", text)

    def test_delete_provider(self):
        lines = self.module.remove_provider(self.source.splitlines(), "airport")
        text = "\n".join(lines) + "\n"
        self.assertNotIn("  airport:", text)
        self.assertIn("proxy-groups:", text)


if __name__ == "__main__":
    unittest.main()
