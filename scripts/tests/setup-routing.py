"""Routing and shell-init regression tests; no real activation or package tools."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class Routing(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="setup-routing-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.home = self.base / "home"
        self.repo = self.home / "ghq/github.com/gigun-dev/dotfiles"
        self.repo.mkdir(parents=True)
        shutil.copyfile(ROOT / "bootstrap.sh", self.repo / "bootstrap.sh")
        (self.repo / "scripts").mkdir(exist_ok=True)
        shutil.copyfile(ROOT / "scripts/bootstrap-route.sh", self.repo / "scripts/bootstrap-route.sh")
        for name in ("npm/npmrc", "bun/bunfig.toml", "uv/uv.toml", "pip/pip.conf", "scripts/guard-apply.sh", "zsh/.zprofile"):
            file = self.repo / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("# fixture\n")
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.log = self.base / "commands"
        self.env = {"HOME": str(self.home), "PATH": f"{self.bin}:{os.environ.get('TEST_PATH', '/usr/bin:/bin')}", "LOG": str(self.log)}
        self.fake("uname", 'case "$1" in -s) echo Darwin;; -m) echo arm64;; esac')
        self.fake("nix", 'printf "nix:%s\\n" "$*" >> "$LOG"; pwd > "$LOG.cwd"')

    def fake(self, name, body):
        p = self.bin / name
        p.write_text("#!" + os.environ.get("TEST_SH", "/bin/sh") + "\n" + body + "\n")
        p.chmod(0o755)

    def run_script(self, *args, prefix=False):
        file = self.repo / "bootstrap.sh"
        if prefix:
            file = self.repo / "routing-only.sh"
            file.write_text('DOTFILES_DIR="' + str(self.repo) + '"\n' +
                            '. "$DOTFILES_DIR/scripts/bootstrap-route.sh"\n' +
                            'dotfiles_bootstrap_route "$@"\n' +
                            'printf "fallback:%s\\n" "$WITH_NET_WATCHDOG" >> "$LOG"\n')
        return subprocess.run([os.environ.get("TEST_BASH", "/bin/bash"), str(file), *args], cwd=self.repo, env=self.env, capture_output=True, text=True)

    def commands(self):
        return self.log.read_text() if self.log.exists() else ""

    def test_delegates_only_same_switch_from_canonical_checkout(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.commands(), "nix:run .#switch\n")
        self.assertEqual(Path(str(self.log) + ".cwd").read_text().strip(), str(self.repo))

    def test_git_auto_switch_skips_frozen_intel_only(self):
        self.fake("git", 'echo git-invoked >> "$LOG"; exit 42')
        for arch, expected in [("x86_64", ""), ("arm64", "git-invoked\n")]:
            with self.subTest(arch=arch):
                self.log.unlink(missing_ok=True)
                self.fake("uname", f'case "$1" in -s) echo Darwin;; -m) echo {arch};; esac')
                result = subprocess.run(
                    [os.environ.get("TEST_BASH", "/bin/bash"),
                     str(ROOT / "git/hooks/switch-on-nix-change"), "post-merge"],
                    env=self.env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.commands(), expected)

    def test_switch_failure_never_falls_back(self):
        self.fake("nix", "exit 42")
        self.assertEqual(self.run_script().returncode, 42)
        self.assertEqual(self.commands(), "")

    def test_worktree_is_not_applied(self):
        self.repo = self.base / "worktree"
        self.repo.mkdir()
        shutil.copyfile(ROOT / "bootstrap.sh", self.repo / "bootstrap.sh")
        (self.repo / "scripts").mkdir(exist_ok=True)
        shutil.copyfile(ROOT / "scripts/bootstrap-route.sh", self.repo / "scripts/bootstrap-route.sh")
        self.assertEqual(self.run_script().returncode, 1)
        self.assertEqual(self.commands(), "")

    def test_frozen_mini_cannot_default_switch(self):
        self.fake("uname", 'case "$1" in -s) echo Darwin;; -m) echo x86_64;; esac')
        self.assertEqual(self.run_script().returncode, 1)
        self.assertEqual(self.commands(), "")

    def test_unknown_option_does_nothing(self):
        self.assertEqual(self.run_script("--typo").returncode, 2)
        self.assertEqual(self.commands(), "")

    def test_guard_only_keeps_nix_out(self):
        (self.repo / "scripts/guard-apply.sh").write_text('printf "guard:%s\\n" "$*" >> "$LOG"\n')
        self.assertEqual(self.run_script("--guard-only").returncode, 0)
        self.assertEqual(self.commands(), "guard:--apply\n")

    def test_no_nix_preserves_legacy_route(self):
        (self.bin / "nix").unlink()
        self.assertEqual(self.run_script(prefix=True).returncode, 0)
        self.assertEqual(self.commands(), "fallback:0\n")

    def test_explicit_legacy_preserves_route(self):
        self.assertEqual(self.run_script("--legacy", prefix=True).returncode, 0)
        self.assertEqual(self.commands(), "fallback:0\n")

    def test_watchdog_preserves_route(self):
        self.assertEqual(self.run_script("--net-watchdog", prefix=True).returncode, 0)
        self.assertEqual(self.commands(), "fallback:1\n")

    def test_missing_guard_source_stops_legacy(self):
        (self.repo / "uv/uv.toml").unlink()
        self.assertEqual(self.run_script("--legacy", prefix=True).returncode, 1)
        self.assertEqual(self.commands(), "")

    def test_profile_is_shared_by_home_manager_and_legacy(self):
        (self.repo / "zsh/.zprofile").unlink()
        self.assertEqual(self.run_script("--legacy", prefix=True).returncode, 1)
        self.assertEqual(self.commands(), "")

    def test_legacy_profile_backup_collision_stops_before_installation(self):
        (self.home / ".zprofile").write_text("preserve profile")
        (self.home / ".zprofile.backup").write_text("preserve backup")
        self.assertEqual(self.run_script("--legacy", prefix=True).returncode, 1)
        self.assertEqual(self.commands(), "")
        self.assertEqual((self.home / ".zprofile").read_text(), "preserve profile")
        self.assertEqual((self.home / ".zprofile.backup").read_text(), "preserve backup")


if __name__ == "__main__":
    unittest.main()
