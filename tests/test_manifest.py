import json
import tomllib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ManifestTests(unittest.TestCase):
    def test_manifest_contract(self):
        manifest = tomllib.loads((ROOT / "plugin.toml").read_text(encoding="utf-8"))
        self.assertEqual(manifest["id"], "LyraVoid/mihomo-tun")
        self.assertEqual(manifest["license"], "MIT")
        self.assertGreaterEqual(manifest["plugin_api"], 14)
        self.assertEqual(manifest["widget"][0]["entry"], "widget.luau")

        panel = next(item for item in manifest["panel"] if item["id"] == "panel")
        self.assertEqual(panel["placement"], "floating")
        self.assertEqual(panel["position"], "top_right")

    def test_translation_keys_match(self):
        en = json.loads((ROOT / "translations/en.json").read_text(encoding="utf-8"))
        zh = json.loads((ROOT / "translations/zh-Hans.json").read_text(encoding="utf-8"))
        self.assertEqual(self._flatten(en), self._flatten(zh))

    def test_required_runtime_files_exist(self):
        for relative in (
            "panel.luau",
            "widget.luau",
            "service.luau",
            "shortcut.luau",
            "scripts/mihomo-ctl.py",
        ):
            self.assertTrue((ROOT / relative).is_file(), relative)

    @staticmethod
    def _flatten(value, prefix=""):
        keys = set()
        if isinstance(value, dict):
            for key, child in value.items():
                path = f"{prefix}.{key}" if prefix else key
                if isinstance(child, dict):
                    keys.update(ManifestTests._flatten(child, path))
                else:
                    keys.add(path)
        return keys


if __name__ == "__main__":
    unittest.main()
