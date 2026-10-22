"""Guard-only deployment regressions; run with python3 -I -S -B."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import re

ROOT = Path(__file__).resolve().parents[2]


class Guard(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="guard-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.home = self.base / "home"
        self.home.mkdir()
        self.repo = self.base / "repo"
        for relative in ("scripts/guard-apply.sh", "scripts/guard-check.py", "npm/npmrc", "bun/bunfig.toml", "uv/uv.toml", "pip/pip.conf"):
            destination = self.repo / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)
        self.env = {"HOME": str(self.home), "PATH": os.environ.get("TEST_PATH", "/usr/bin:/bin"), "XDG_CONFIG_HOME": str(self.home / ".config")}

    def apply(self, *args):
        return subprocess.run([os.environ.get("TEST_SH", "/bin/sh"), str(self.repo / "scripts/guard-apply.sh"), *args], env=self.env, capture_output=True, text=True)

    def check(self, *args):
        return subprocess.run([sys.executable, "-I", "-S", "-B", str(self.repo / "scripts/guard-check.py"), "--repo", str(self.repo), "--home", str(self.home), *map(str, args)], env=self.env, capture_output=True, text=True)

    def test_clean_env_apply_is_idempotent_and_check_is_read_only(self):
        self.assertNotEqual(self.apply("--check").returncode, 0)
        self.assertEqual(self.apply("--apply").returncode, 0)
        paths = list(self.home.rglob("*"))
        before = {str(p): (p.stat().st_mtime_ns, p.read_bytes()) for p in paths if p.is_file()}
        self.assertEqual(self.check().returncode, 0)
        after = {str(p): (p.stat().st_mtime_ns, p.read_bytes()) for p in paths if p.is_file()}
        self.assertEqual(before, after)
        self.assertEqual(self.apply("--apply").returncode, 0)
        self.assertEqual(self.apply("--check").returncode, 0)
        self.assertEqual(self.check().returncode, 0)

    def test_missing_source_fails_before_any_target_is_written(self):
        (self.repo / "uv/uv.toml").unlink()
        self.assertNotEqual(self.apply("--apply").returncode, 0)
        self.assertFalse((self.home / ".npmrc").exists())

    def test_existing_credentials_are_preserved_without_output(self):
        secret = "fixture-private-token"
        path = self.home / ".config/uv/uv.toml"
        path.parent.mkdir(parents=True)
        original = f'index-url = "https://token:{secret}@example.invalid/simple/"\n'
        path.write_text(original)
        result = self.apply("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(secret, result.stdout + result.stderr)
        self.assertEqual(path.read_text(), original)
        self.assertFalse((self.home / ".npmrc").exists())

    def test_existing_regular_permissions_and_checkout_are_preserved(self):
        path = self.home / ".npmrc"
        shutil.copyfile(self.repo / "npm/npmrc", path)
        path.chmod(0o600)
        original = (self.repo / "npm/npmrc").read_bytes()
        self.assertEqual(self.apply("--apply").returncode, 0)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.repo / "npm/npmrc").read_bytes(), original)
        (self.repo / "npm/npmrc").write_text("registry=https://changed.invalid/\n")
        self.assertEqual(path.read_bytes(), original)

    def test_mutable_symlink_and_project_overrides_are_detected_without_secrets(self):
        self.assertEqual(self.apply("--apply").returncode, 0)
        npm = self.home / ".npmrc"
        npm.unlink()
        npm.symlink_to(self.repo / "npm/npmrc")
        self.assertIn("mutable checkout", self.check().stdout)
        npm.unlink()
        self.assertEqual(self.apply("--apply").returncode, 0)
        project = self.base / "project"
        project.mkdir()
        (project / ".npmrc").write_text("@private:registry=https://token:fixture-secret@other.invalid/\n")
        (project / "uv.toml").write_text('[[index]]\nurl="https://pypi.org/simple"\ndefault=true\n')
        result = self.check("--scan", project)
        self.assertEqual(result.returncode, 2)
        self.assertIn("@private:registry", result.stdout)
        self.assertIn("uv index bypasses", result.stdout)
        self.assertNotIn("fixture-secret", result.stdout + result.stderr)

    def test_xdg_bun_and_environment_override_detection(self):
        self.env["XDG_CONFIG_HOME"] = str(self.home / "custom")
        self.assertEqual(self.apply("--apply").returncode, 0)
        self.assertTrue((self.home / "custom/.bunfig.toml").is_file())
        self.env["UV_DEFAULT_INDEX"] = "https://token:fixture-secret@other.invalid/simple/"
        result = self.check()
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("fixture-secret", result.stdout + result.stderr)

    def test_dangling_legacy_bun_link_is_replaced_without_touching_target(self):
        path = self.home / ".config/.bunfig.toml"
        path.parent.mkdir(parents=True)
        missing = self.repo / "bunfig.toml"
        path.symlink_to(missing)
        self.assertEqual(self.apply("--apply").returncode, 0)
        self.assertFalse(path.is_symlink())
        self.assertFalse(missing.exists())
        self.assertEqual(self.check().returncode, 0)

    def test_unknown_dangling_link_is_preserved_before_any_writes(self):
        path = self.home / ".npmrc"
        path.symlink_to(self.base / "missing-private-config")
        self.assertNotEqual(self.apply("--apply").returncode, 0)
        self.assertTrue(path.is_symlink())
        self.assertFalse((self.home / ".bunfig.toml").exists())


if __name__ == "__main__":
    unittest.main()
