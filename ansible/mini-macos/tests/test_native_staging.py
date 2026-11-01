"""Verify staged plist installation using macOS plutil."""
from pathlib import Path
import unittest

import test_migration


class NativeStaging(test_migration.MigrationFixture, unittest.TestCase):
    def test_staging_check_apply_and_idempotency(self):
        stage = Path(self.variables["mini_stage_dir"])
        result = self.run_tasks("launchd.yml", check=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(stage.exists())
        result = self.run_tasks("launchd.yml")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((stage / "network-watchdog.sh").read_bytes(),
                         (test_migration.ROOT.parent.parent / "nix/modules/darwin/network-watchdog.sh").read_bytes())
        result = self.run_tasks("launchd.yml")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"changed=0\s")
