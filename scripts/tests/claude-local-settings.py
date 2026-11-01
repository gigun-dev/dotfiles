import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "claude/manage-local-settings.py"
MARKET = "/local/marketplace"


class SettingsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.template = self.home / "template.json"
        self.settings = self.home / "settings.json"
        self.original = (json.dumps({"extraKnownMarketplaces": {"gigun": {"source": {"path": MARKET}}}, "other": {"keep": True}}, indent=4) + "\n").encode()
        self.template.write_bytes(self.original)

    def apply(self, path=MARKET):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.settings), str(self.template), path], capture_output=True)

    def test_symlink_migration_and_reapply_preserves_updates(self):
        self.settings.symlink_to(self.template)
        self.assertEqual(self.apply().returncode, 0)
        self.assertFalse(self.settings.is_symlink())
        self.assertEqual(self.settings.read_bytes(), self.original)
        updated = self.original.replace(b'true', b'false')
        self.settings.write_bytes(updated)
        self.assertEqual(self.apply().returncode, 0)
        self.assertEqual(self.settings.read_bytes(), updated)
        self.assertEqual(self.template.read_bytes(), self.original)

    def test_missing_file_uses_template_and_declared_marketplace(self):
        self.assertEqual(self.apply('/another/marketplace').returncode, 0)
        result = json.loads(self.settings.read_bytes())
        self.assertEqual(result['extraKnownMarketplaces']['gigun']['source']['path'], '/another/marketplace')
        self.assertTrue(result['other']['keep'])
        self.assertEqual(self.template.read_bytes(), self.original)

    def test_existing_different_marketplace_fails_without_mutation(self):
        self.settings.write_bytes(self.original)
        self.assertNotEqual(self.apply('/other').returncode, 0)
        self.assertEqual(self.settings.read_bytes(), self.original)

    def test_other_symlink_fails_without_mutation(self):
        other = self.home / 'other.json'
        other.write_bytes(self.original)
        self.settings.symlink_to(other)
        self.assertNotEqual(self.apply().returncode, 0)
        self.assertTrue(self.settings.is_symlink())
        self.assertEqual(other.read_bytes(), self.original)


if __name__ == '__main__':
    unittest.main()
