"""Pinned HM helper behavior against temporary HOME; never full activation."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class HomeManagerHandoff(unittest.TestCase):
    """Run only HM's existing collision checker/linker, never its activation."""

    @classmethod
    def setUpClass(cls):
        def unavailable(reason):
            raise AssertionError(reason)

        activation = os.environ.get("HM_TEST_ACTIVATION")
        if not activation:
            raise AssertionError("HM_TEST_ACTIVATION must name the pinned fixture generation")
        text = Path(activation).read_text()
        checker = re.search(r"bash (/nix/store/[^\s]+-check-link-targets\.sh)", text)
        linker = re.search(r"bash (/nix/store/[^\s]+-link) ", text)
        search_path = re.search(r'export PATH="([^"]+)"', text)
        if not (checker and linker and search_path):
            unavailable("pinned fixture HM helpers could not be identified")
        cls.checker, cls.linker = checker[1], linker[1]
        cls.shell = text.splitlines()[0].removeprefix("#!")
        cls.search_path = search_path[1]

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="guard-hm-handoff-")
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.home, self.generation = base / "home", base / "new-home-files"
        self.home.mkdir()
        self.paths = {
            ".npmrc": "npm/npmrc",
            ".bunfig.toml": "bun/bunfig.toml",
            ".config/.bunfig.toml": "bun/bunfig.toml",
            ".config/uv/uv.toml": "uv/uv.toml",
            ".config/pip/pip.conf": "pip/pip.conf",
            "Library/Application Support/pip/pip.conf": "pip/pip.conf",
        }
        for target, source in self.paths.items():
            for directory in (self.home, self.generation):
                path = directory / target
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / source, path)

    def helper(self, script, home=None):
        environment = {
            "HOME": str(home or self.home), "PATH": self.search_path,
            "HOME_MANAGER_BACKUP_EXT": "backup", "NO_COLOR": "1",
        }
        return subprocess.run([self.shell, script, str(self.generation),
                               *[str(self.generation / p) for p in self.paths]],
                              env=environment, capture_output=True, text=True)

    def test_copies_pass_collision_check_and_become_links_with_backups(self):
        result = self.helper(self.checker)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.helper(self.linker)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for target, source in self.paths.items():
            path = self.home / target
            self.assertTrue(path.is_symlink(), target)
            self.assertEqual(path.resolve(), (self.generation / target).resolve())
            self.assertEqual(Path(str(path) + ".backup").read_bytes(), (ROOT / source).read_bytes())

    def test_changed_file_and_existing_backup_stop_before_linking(self):
        path = self.home / ".npmrc"
        path.write_text("registry=https://private.invalid/\n")
        backup = self.home / ".npmrc.backup"
        backup.write_text("preserve-existing-backup\n")
        result = self.helper(self.checker)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(path.read_text(), "registry=https://private.invalid/\n")
        self.assertEqual(backup.read_text(), "preserve-existing-backup\n")
        self.assertFalse(path.is_symlink())

    def test_managed_profile_preserves_old_file_as_backup(self):
        # A real user's former local profile differs from the proposed HM source.
        # Exercise only existing HM helpers against a temporary HOME.
        self.paths = {".zprofile": "zsh/.zprofile"}
        old = 'export PATH="/fixture/orbstack:$PATH"\n'
        (self.home / ".zprofile").write_text(old)
        shutil.copyfile(ROOT / "zsh/.zprofile", self.generation / ".zprofile")
        result = self.helper(self.checker)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.helper(self.linker)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.home / ".zprofile").is_symlink())
        self.assertEqual((self.home / ".zprofile.backup").read_text(), old)
        self.assertEqual((self.home / ".zprofile").read_bytes(), (ROOT / "zsh/.zprofile").read_bytes())

    @unittest.skipUnless(os.environ.get("GUARD_CHECK_REAL_HOME") == "1", "opt-in read-only real-home collision check")
    def test_real_home_collision_check_is_read_only(self):
        home = Path.home()
        before = {p: ((home / p).read_bytes(), (home / p).lstat().st_mtime_ns) for p in self.paths}
        result = self.helper(self.checker, home)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        after = {p: ((home / p).read_bytes(), (home / p).lstat().st_mtime_ns) for p in self.paths}
        self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
