import os
import pathlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci/github-app-push-branch.sh"


class GitHubAppPushTest(unittest.TestCase):
    def run_push(self, mode: str):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            tool = root / "git"
            audit = root / "audit"
            bash = os.environ.get("TEST_BASH") or shutil.which("bash")
            self.assertIsNotNone(bash)
            tool.write_text(
                f"#!{bash}\n"
                + textwrap.dedent(
                    """\
                    printf '%s\n' "$*" >> "$AUDIT"
                    if [[ "$1" = ls-remote ]]; then
                      [[ "$MODE" = absent ]] && exit 2
                      printf '%040d\trefs/heads/bot/test\n' 1
                      exit 0
                    fi
                    if [[ "$1" = push && "$2" = --force-with-lease=* ]]; then
                      case "$MODE" in
                        workflow-denied)
                          echo 'refusing workflow update without workflows permission' >&2
                          exit 1
                          ;;
                        other-denied)
                          echo 'remote unavailable' >&2
                          exit 1
                          ;;
                      esac
                    fi
                    exit 0
                    """
                )
            )
            tool.chmod(0o755)
            process = subprocess.run(
                [os.environ.get("TEST_BASH", "bash"), str(SCRIPT), "bot/test"],
                env=os.environ
                | {
                    "AUDIT": str(audit),
                    "GH_TOKEN": "fixture-token",
                    "GIT_ASKPASS": str(tool),
                    "MODE": mode,
                    "PATH": f"{root}:{os.environ['PATH']}",
                    "RUNNER_TEMP": str(root),
                },
                text=True,
                capture_output=True,
            )
            return process, audit.read_text().splitlines()

    def test_new_branch_uses_non_force_push(self):
        process, calls = self.run_push("absent")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(calls[-1], "push origin HEAD:refs/heads/bot/test")

    def test_existing_branch_uses_exact_force_with_lease(self):
        process, calls = self.run_push("existing")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn(
            "push --force-with-lease=refs/heads/bot/test:0000000000000000000000000000000000000001 origin HEAD:refs/heads/bot/test",
            calls,
        )
        self.assertFalse(any("--delete" in call for call in calls))

    def test_workflow_permission_denial_recreates_branch(self):
        process, calls = self.run_push("workflow-denied")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn("push origin --delete bot/test", calls)
        self.assertEqual(calls[-1], "push origin HEAD:refs/heads/bot/test")

    def test_other_push_failure_does_not_delete_branch(self):
        process, calls = self.run_push("other-denied")
        self.assertEqual(process.returncode, 1)
        self.assertIn("remote unavailable", process.stderr)
        self.assertFalse(any("--delete" in call for call in calls))


if __name__ == "__main__":
    unittest.main()
