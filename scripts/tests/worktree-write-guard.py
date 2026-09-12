#!/usr/bin/env python3
"""Exercise real linked checkouts without changing the user's repository."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HOOK = Path(__file__).resolve().parents[2] / "claude/hooks/worktree-write-guard.py"


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="worktree guard ")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.main = self.base / "main checkout"
        self.work = self.base / "assigned worktree"
        self.sibling = self.base / "sibling worktree"
        self.other = self.base / "other repo"
        self.outside = self.base / "non git"
        self.outside.mkdir()
        for repo in (self.main, self.other):
            self.git("init", str(repo))
            self.git("-C", str(repo), "-c", "user.name=Fixture", "-c",
                     "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "initial")
        for branch, path in (("assigned", self.work), ("sibling", self.sibling)):
            self.git("-C", str(self.main), "worktree", "add", "-b", branch, str(path))
        (self.work / "main link").symlink_to(self.main, target_is_directory=True)
        (self.work / "self link").symlink_to(self.work, target_is_directory=True)
        (self.main / "existing file").write_text("fixture")
        (self.work / "file link").symlink_to(self.main / "existing file")

    @staticmethod
    def git(*args):
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        subprocess.run(["git", *args], check=True, capture_output=True, env=env)

    def check(self, cwd, path, denied=False, tool="Write", env=None):
        result = subprocess.run([sys.executable, str(HOOK)], input=json.dumps({
            "cwd": str(cwd), "tool_name": tool, "tool_input": {"file_path": str(path)}
        }), capture_output=True, text=True, check=True, env=env)
        if denied:
            output = json.loads(result.stdout)["hookSpecificOutput"]
            self.assertEqual(output["hookEventName"], "PreToolUse")
            self.assertEqual(output["permissionDecision"], "deny")
            self.assertTrue(output["permissionDecisionReason"])
        else:
            self.assertEqual(result.stdout, "")

    def test_checkout_boundaries(self):
        cases = [
            (self.work, self.work / "new dir/file", False),
            (self.work, "relative file", False),
            (self.work, self.main / "new dir/file", True),
            (self.work, self.sibling / "file", True),
            (self.work, self.work / "main link/new dir/file", True),
            (self.work, self.work / "self link/new dir/file", False),
            (self.work, self.main / "existing file", True),
            (self.work, self.work / "file link", True),
            (self.work, self.other / "file", False),
            (self.work, self.outside / "file", False),
            (self.outside, self.main / "file", False),
            (self.main, self.sibling / "file", False),
        ]
        for cwd, path, denied in cases:
            for tool in ("Write", "Edit"):
                with self.subTest(cwd=cwd, path=path, tool=tool):
                    self.check(cwd, path, denied, tool)

    def test_bash_is_outside_scope(self):
        self.check(self.work, self.main / "file", tool="Bash")

    def test_git_failure_denies(self):
        env = dict(os.environ, PATH=str(self.outside))
        self.check(self.work, self.work / "file", True, env=env)

    def test_inherited_git_dir_does_not_redirect_inspection(self):
        env = dict(os.environ, GIT_DIR=str(self.other / ".git"))
        self.check(self.work, self.main / "file", True, env=env)

    def test_broken_git_pointer_denies(self):
        (self.work / ".git").write_text(f"gitdir: {self.base / 'missing git dir'}\n")
        self.check(self.work, self.work / "file", True)


if __name__ == "__main__":
    unittest.main()
