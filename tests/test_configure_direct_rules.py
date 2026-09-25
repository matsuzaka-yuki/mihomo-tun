import importlib.util
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


if __name__ == "__main__":
    unittest.main()
