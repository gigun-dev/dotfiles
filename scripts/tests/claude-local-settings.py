import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "claude/manage-local-settings.py"
GIT = shutil.which("git")
MARKET = "/local/marketplace"


class SettingsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.repo = self.home / "repo"
        self.repo.mkdir()
        self.tracked = self.repo / "claude/settings.json"
        self.tracked.parent.mkdir()
        self.template = self.home / "desired.json"
        self.settings = self.home / "settings.json"
        self.state = self.home / "state/base.json"
        self.base = {
            "extraKnownMarketplaces": {"gigun": {"source": {"path": "/mac/marketplace"}}},
            "permissions": {"allow": ["initial"]},
            "enabledPlugins": {"retired@gigun": True},
            "zzz": "unchanged",
        }
        self.tracked.write_text(json.dumps(self.base, indent=2) + "\n")
        subprocess.run([GIT, "init", "-q", str(self.repo)], check=True)
        subprocess.run([GIT, "-C", str(self.repo), "add", "claude/settings.json"], check=True)
        subprocess.run([GIT, "-C", str(self.repo), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture"], check=True)
        self.template.write_text(json.dumps(self.base))

    def apply(self, marketplace=MARKET):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.settings), str(self.tracked), str(self.template), str(self.state), marketplace, GIT], capture_output=True)

    def live_data(self):
        value = json.loads(json.dumps(self.base))
        value["extraKnownMarketplaces"]["gigun"]["source"]["path"] = MARKET
        return value

    def test_symlink_migration_and_reapply_preserves_updates(self):
        original = (json.dumps(self.live_data(), indent=4) + "\n").encode()
        self.tracked.write_bytes(original)
        self.tracked.chmod(0o644)
        self.settings.symlink_to(self.tracked)
        self.assertEqual(self.apply().returncode, 0)
        self.assertFalse(self.settings.is_symlink())
        self.assertEqual(self.settings.stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.settings.read_bytes(), original)
        data = json.loads(original)
        data["unmanaged"] = "Claude update"
        self.settings.write_text(json.dumps(data))
        self.assertEqual(self.apply().returncode, 0)
        self.assertEqual(json.loads(self.settings.read_bytes()), data)
        self.assertEqual(self.tracked.read_bytes(), original)

    def test_missing_file_uses_template_and_declared_marketplace(self):
        self.assertEqual(self.apply().returncode, 0)
        self.assertEqual(json.loads(self.settings.read_bytes()), self.live_data())
        self.assertTrue(self.state.is_file())

    def test_declared_changes_and_unmanaged_values_are_merged(self):
        self.assertEqual(self.apply().returncode, 0)
        local = json.loads(self.settings.read_bytes())
        local["zz_local_only"] = {"keep": True}
        self.settings.write_text(json.dumps(local))
        new = json.loads(json.dumps(self.base))
        new["permissions"]["allow"] = ["updated"]
        new["enabledPlugins"].pop("retired@gigun")
        self.template.write_text(json.dumps(new))
        self.assertEqual(self.apply().returncode, 0)
        result = json.loads(self.settings.read_bytes())
        self.assertEqual(result["permissions"]["allow"], ["updated"])
        self.assertNotIn("retired@gigun", result["enabledPlugins"])
        self.assertEqual(result["zz_local_only"], {"keep": True})
        self.assertEqual(self.apply().returncode, 0)
        self.assertEqual(json.loads(self.settings.read_bytes()), result)

    def test_preserves_new_plugin_while_removing_retired_plugin(self):
        self.assertEqual(self.apply().returncode, 0)
        local = json.loads(self.settings.read_bytes())
        local["enabledPlugins"]["custom@other"] = True
        self.settings.write_text(json.dumps(local))
        new = json.loads(json.dumps(self.base))
        new["enabledPlugins"].pop("retired@gigun")
        self.template.write_text(json.dumps(new))
        self.assertEqual(self.apply().returncode, 0)
        plugins = json.loads(self.settings.read_bytes())["enabledPlugins"]
        self.assertEqual(plugins, {"custom@other": True})

    def test_json_boolean_and_number_remain_distinct(self):
        self.assertEqual(self.apply().returncode, 0)
        local = json.loads(self.settings.read_bytes())
        local["enabledPlugins"]["retired@gigun"] = 1
        self.settings.write_text(json.dumps(local))
        self.assertEqual(self.apply().returncode, 0)
        self.assertIs(type(json.loads(self.settings.read_bytes())["enabledPlugins"]["retired@gigun"]), int)

    def test_conflict_fails_without_changing_settings_or_base(self):
        self.assertEqual(self.apply().returncode, 0)
        local = json.loads(self.settings.read_bytes())
        local["permissions"]["allow"] = ["local"]
        self.settings.write_text(json.dumps(local))
        before, base_before = self.settings.read_bytes(), self.state.read_bytes()
        new = json.loads(json.dumps(self.base))
        new["permissions"]["allow"] = ["upstream"]
        self.template.write_text(json.dumps(new))
        self.assertNotEqual(self.apply().returncode, 0)
        self.assertEqual(self.settings.read_bytes(), before)
        self.assertEqual(self.state.read_bytes(), base_before)

    def test_interrupted_base_update_can_be_retried(self):
        self.assertEqual(self.apply().returncode, 0)
        old_base = self.state.read_bytes()
        new = json.loads(json.dumps(self.base))
        new["permissions"]["allow"] = ["updated"]
        self.template.write_text(json.dumps(new))
        self.assertEqual(self.apply().returncode, 0)
        changed = self.settings.read_bytes()
        self.state.write_bytes(old_base)
        self.assertEqual(self.apply().returncode, 0)
        self.assertEqual(self.settings.read_bytes(), changed)

    def test_duplicate_json_key_fails_without_mutation(self):
        self.settings.write_text('{"permissions": {}, "permissions": {}}')
        before = self.settings.read_bytes()
        self.assertNotEqual(self.apply().returncode, 0)
        self.assertEqual(self.settings.read_bytes(), before)
        self.assertFalse(self.state.exists())

    def test_existing_different_marketplace_fails_without_mutation(self):
        self.settings.write_text(json.dumps(self.live_data()))
        before = self.settings.read_bytes()
        self.assertNotEqual(self.apply("/other").returncode, 0)
        self.assertEqual(self.settings.read_bytes(), before)
        self.assertFalse(self.state.exists())

    def test_other_symlink_fails_without_mutation(self):
        other = self.home / "other.json"
        other.write_text(json.dumps(self.live_data()))
        self.settings.symlink_to(other)
        self.assertNotEqual(self.apply().returncode, 0)
        self.assertTrue(self.settings.is_symlink())
        self.assertFalse(self.state.exists())


if __name__ == "__main__":
    unittest.main()
