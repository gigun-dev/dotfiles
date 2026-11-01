import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / "claude/manage-local-settings.py"
GIT = shutil.which("git")
MARKET = "/local/marketplace"
SPEC = importlib.util.spec_from_file_location("claude_local_settings", SCRIPT)
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)


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

    def test_removed_managed_key_conflicts_with_local_edit(self):
        self.assertEqual(self.apply().returncode, 0)
        local = json.loads(self.settings.read_bytes())
        local["enabledPlugins"]["retired@gigun"] = False
        self.settings.write_text(json.dumps(local))
        before, base = self.settings.read_bytes(), self.state.read_bytes()
        new = json.loads(json.dumps(self.base))
        del new["enabledPlugins"]["retired@gigun"]
        self.template.write_text(json.dumps(new))
        self.assertNotEqual(self.apply().returncode, 0)
        self.assertEqual(self.settings.read_bytes(), before)
        self.assertEqual(self.state.read_bytes(), base)

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

    def helper_args(self):
        return [str(SCRIPT), str(self.settings), str(self.tracked), str(self.template), str(self.state), MARKET, GIT]

    def test_concurrent_atomic_replacement_is_detected(self):
        self.assertEqual(self.apply().returncode, 0)
        old_base = self.state.read_bytes()
        changed = json.loads(self.settings.read_bytes())
        changed["zz_concurrent"] = "kept"
        concurrent = json.dumps(changed).encode()
        real_identity = HELPER.identity
        calls = 0

        def replace_during_reconciliation(path):
            nonlocal calls
            calls += 1
            if calls == 2:
                other = self.home / "claude-write.json"
                other.write_bytes(concurrent)
                other.replace(self.settings)
            return real_identity(path)

        with mock.patch.object(sys, "argv", self.helper_args()), mock.patch.object(HELPER, "identity", side_effect=replace_during_reconciliation):
            with self.assertRaisesRegex(ValueError, "changed during reconciliation"):
                HELPER.main()
        self.assertEqual(self.settings.read_bytes(), concurrent)
        self.assertEqual(self.state.read_bytes(), old_base)

    def test_symlink_replaced_during_migration_is_preserved(self):
        original = (json.dumps(self.live_data(), indent=4) + "\n").encode()
        self.tracked.write_bytes(original)
        self.settings.symlink_to(self.tracked)
        changed = self.live_data()
        changed["zz_concurrent"] = "kept"
        concurrent = json.dumps(changed).encode()
        real_identity = HELPER.identity
        calls = 0

        def replace_symlink_during_migration(path):
            nonlocal calls
            calls += 1
            if calls == 2:
                other = self.home / "claude-write.json"
                other.write_bytes(concurrent)
                other.replace(self.settings)
            return real_identity(path)

        with mock.patch.object(sys, "argv", self.helper_args()), mock.patch.object(HELPER, "identity", side_effect=replace_symlink_during_migration):
            with self.assertRaisesRegex(ValueError, "changed during reconciliation"):
                HELPER.main()
        self.assertFalse(self.settings.is_symlink())
        self.assertEqual(self.settings.read_bytes(), concurrent)
        self.assertEqual(self.tracked.read_bytes(), original)
        self.assertFalse(self.state.exists())

    def test_interrupted_before_base_replace_can_be_retried(self):
        self.assertEqual(self.apply().returncode, 0)
        old_base = self.state.read_bytes()
        new = json.loads(json.dumps(self.base))
        new["permissions"]["allow"] = ["updated"]
        self.template.write_text(json.dumps(new))
        real_replace = HELPER.os.replace

        def interrupt_base(source, destination):
            if Path(destination) == self.state:
                raise OSError("simulated interruption")
            return real_replace(source, destination)

        with mock.patch.object(sys, "argv", self.helper_args()), mock.patch.object(HELPER.os, "replace", side_effect=interrupt_base):
            with self.assertRaisesRegex(OSError, "simulated interruption"):
                HELPER.main()
        self.assertEqual(self.state.read_bytes(), old_base)
        self.assertEqual(json.loads(self.settings.read_bytes())["permissions"]["allow"], ["updated"])
        self.assertEqual(self.apply().returncode, 0)
        self.assertEqual(json.loads(self.state.read_bytes())["permissions"]["allow"], ["updated"])

    def test_missing_base_with_ambiguous_checkout_fails_safely(self):
        self.assertEqual(self.apply().returncode, 0)
        before = self.settings.read_bytes()
        self.state.unlink()
        self.assertNotEqual(self.apply().returncode, 0)
        self.assertEqual(self.settings.read_bytes(), before)
        self.assertFalse(self.state.exists())

    def test_duplicate_json_key_fails_without_mutation(self):
        self.settings.write_text('{"permissions": {}, "permissions": {}}')
        before = self.settings.read_bytes()
        self.assertNotEqual(self.apply().returncode, 0)
        self.assertEqual(self.settings.read_bytes(), before)
        self.assertFalse(self.state.exists())

    def test_declared_marketplace_change_applies_when_local_is_unchanged(self):
        self.assertEqual(self.apply().returncode, 0)
        self.assertEqual(self.apply("/new/marketplace").returncode, 0)
        result = json.loads(self.settings.read_bytes())
        self.assertEqual(result["extraKnownMarketplaces"]["gigun"]["source"]["path"], "/new/marketplace")
        self.assertEqual(self.apply(MARKET).returncode, 0)
        result = json.loads(self.settings.read_bytes())
        self.assertEqual(result["extraKnownMarketplaces"]["gigun"]["source"]["path"], MARKET)

    def test_local_marketplace_change_is_not_overwritten(self):
        self.assertEqual(self.apply().returncode, 0)
        data = json.loads(self.settings.read_bytes())
        data["extraKnownMarketplaces"]["gigun"]["source"]["path"] = "/user/marketplace"
        self.settings.write_text(json.dumps(data))
        before, base = self.settings.read_bytes(), self.state.read_bytes()
        self.assertNotEqual(self.apply("/new/marketplace").returncode, 0)
        self.assertEqual(self.settings.read_bytes(), before)
        self.assertEqual(self.state.read_bytes(), base)

    def test_write_during_temporary_file_staging_is_detected(self):
        self.assertEqual(self.apply().returncode, 0)
        state_before = self.state.read_bytes()
        new = json.loads(json.dumps(self.base))
        new["permissions"]["allow"] = ["updated"]
        self.template.write_text(json.dumps(new))
        changed = json.loads(self.settings.read_bytes())
        changed["zz_concurrent"] = "kept"
        concurrent = json.dumps(changed).encode()
        real_mkstemp = HELPER.tempfile.mkstemp

        def concurrent_during_staging(*args, **kwargs):
            fd, name = real_mkstemp(*args, **kwargs)
            if Path(kwargs["dir"]) == self.settings.parent:
                self.settings.write_bytes(concurrent)
            return fd, name

        with mock.patch.object(sys, "argv", self.helper_args()), mock.patch.object(HELPER.tempfile, "mkstemp", side_effect=concurrent_during_staging):
            with self.assertRaisesRegex(ValueError, "changed during reconciliation"):
                HELPER.main()
        self.assertEqual(self.settings.read_bytes(), concurrent)
        self.assertEqual(self.state.read_bytes(), state_before)

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
