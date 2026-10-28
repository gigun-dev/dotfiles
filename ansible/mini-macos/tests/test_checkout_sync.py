"""Exercise checkout sync with disposable local Git repositories."""
import os
import fcntl
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[3] / "scripts/mini-checkout-sync.py"


class CheckoutSync(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="mini-checkout-sync-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.seed = self.root / "seed"
        self.remote = self.root / "remote.git"
        self.checkout = self.root / "checkout"
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
        self.run_git(self.root, "init", "-b", "main", str(self.seed))
        self.run_git(self.seed, "config", "user.email", "fixture@example.invalid")
        self.run_git(self.seed, "config", "user.name", "Fixture")
        self.run_git(self.seed, "config", "commit.gpgsign", "false")
        (self.seed / "file").write_text("initial\n")
        self.run_git(self.seed, "add", "file")
        self.run_git(self.seed, "commit", "-m", "initial")
        self.run_git(self.root, "init", "--bare", "--initial-branch=main", str(self.remote))
        self.run_git(self.seed, "remote", "add", "origin", str(self.remote))
        self.run_git(self.seed, "push", "-u", "origin", "main")
        self.run_git(self.root, "clone", str(self.remote), str(self.checkout))
        self.run_git(self.checkout, "config", "user.email", "fixture@example.invalid")
        self.run_git(self.checkout, "config", "user.name", "Fixture")
        self.run_git(self.checkout, "config", "commit.gpgsign", "false")

    def run_git(self, cwd, *args):
        return subprocess.run(["git", "-C", str(cwd), *args], env=self.env,
                              capture_output=True, text=True, check=True, timeout=30).stdout.strip()

    def advance_remote(self, name="file", content="updated\n"):
        (self.seed / name).write_text(content)
        self.run_git(self.seed, "add", name)
        self.run_git(self.seed, "commit", "-m", "remote update")
        self.run_git(self.seed, "push", "origin", "main")
        return self.run_git(self.seed, "rev-parse", "HEAD")

    def sync(self):
        return subprocess.run([sys.executable, str(SCRIPT), "--repo", str(self.checkout)],
                              env=self.env, capture_output=True, text=True, timeout=90)

    def test_clean_main_fast_forwards(self):
        target = self.advance_remote()
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.run_git(self.checkout, "rev-parse", "HEAD"), target)
        self.assertEqual((self.checkout / "file").read_text(), "updated\n")

    def test_dirty_and_untracked_are_preserved(self):
        self.advance_remote()
        old = self.run_git(self.checkout, "rev-parse", "HEAD")
        for name in ("file", "untracked"):
            with self.subTest(name=name):
                path = self.checkout / name
                path.write_text("local\n")
                result = self.sync()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(path.read_text(), "local\n")
                self.assertEqual(self.run_git(self.checkout, "rev-parse", "HEAD"), old)
                if name == "file":
                    self.run_git(self.checkout, "restore", "file")
                else:
                    path.unlink()

    def test_non_main_and_divergence_stop(self):
        self.advance_remote()
        self.run_git(self.checkout, "switch", "-c", "other")
        self.assertNotEqual(self.sync().returncode, 0)
        self.run_git(self.checkout, "switch", "main")
        (self.checkout / "local").write_text("local\n")
        self.run_git(self.checkout, "add", "local")
        self.run_git(self.checkout, "commit", "-m", "local")
        old = self.run_git(self.checkout, "rev-parse", "HEAD")
        self.assertNotEqual(self.sync().returncode, 0)
        self.assertEqual(self.run_git(self.checkout, "rev-parse", "HEAD"), old)

    def test_fetch_failure_and_executable_hook_stop(self):
        self.run_git(self.checkout, "remote", "set-url", "origin", str(self.root / "missing"))
        self.assertNotEqual(self.sync().returncode, 0)
        self.run_git(self.checkout, "remote", "set-url", "origin", str(self.remote))
        hook = self.checkout / ".git/hooks/post-index-change"
        marker = self.root / "hook-ran"
        hook.write_text(f"#!/bin/sh\ntouch '{marker}'\n")
        hook.chmod(0o755)
        result = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("executable Git hooks require review", result.stderr)
        self.assertFalse(marker.exists())

    def test_ignored_collision_is_preserved(self):
        (self.checkout / ".git/info/exclude").write_text("collision\n")
        (self.checkout / "collision").write_text("local ignored\n")
        self.advance_remote("collision", "remote\n")
        old = self.run_git(self.checkout, "rev-parse", "HEAD")
        self.assertNotEqual(self.sync().returncode, 0)
        self.assertEqual((self.checkout / "collision").read_text(), "local ignored\n")
        self.assertEqual(self.run_git(self.checkout, "rev-parse", "HEAD"), old)

    def test_another_sync_holds_the_lock(self):
        lock = self.checkout / ".git/mini-checkout-sync.lock"
        with lock.open("a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("another checkout sync is running", result.stderr)



if __name__ == "__main__":
    unittest.main()
