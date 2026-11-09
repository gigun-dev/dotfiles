import os
import pathlib
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci/propose-flake-lock.sh"


class FlakeProposalTest(unittest.TestCase):
    def run_proposal(self, lane: str, changed: bool):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            tools = root / "bin"
            tools.mkdir()
            audit = root / "audit"
            audit.mkdir()

            (tools / "nix").write_text(
                '#!/usr/bin/env bash\nprintf \'%s\\n\' "$*" >> "$AUDIT/nix"\n'
            )
            (tools / "git").write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    printf '%s\n' "$*" >> "$AUDIT/git"
                    if [[ "$*" = "diff --cached --name-only" ]]; then printf 'flake.lock\n'; exit 0; fi
                    if [[ "$*" = "diff --quiet -- flake.lock" ]]; then
                      [[ -n "${PUBLISHING:-}" || "$CHANGED" = 0 ]]; exit
                    fi
                    if [[ "$1" = write-tree || "$1" = rev-parse ]]; then printf 'fixture-tree\n'; exit 0; fi
                    if [[ "$1" = ls-remote ]]; then exit 2; fi
                    exit 0
                    """
                )
            )
            (tools / "gh").write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    printf '%s\n' "$*" >> "$AUDIT/gh"
                    if [[ "$1 $2" = "pr view" && "$*" = *"--json number"* ]]; then
                      printf '42\n'
                    fi
                    """
                )
            )
            for tool in tools.iterdir():
                tool.chmod(0o755)

            environment = os.environ | {
                "AUDIT": str(audit),
                "CHANGED": "1" if changed else "0",
                "GH_TOKEN": "fixture-token",
                "GITHUB_REPOSITORY": "gigun-dev/dotfiles",
                "GIT_ASKPASS": str(tools / "git"),
                "PATH": f"{tools}:{os.environ['PATH']}",
                "RUNNER_TEMP": str(root),
                "GITHUB_OUTPUT": str(root / "github-output"),
            }
            prepare = subprocess.run(
                [os.environ.get("TEST_BASH", "bash"), str(SCRIPT), "prepare", lane],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
            )
            process = prepare
            if prepare.returncode == 0 and changed:
                process = subprocess.run(
                    [os.environ.get("TEST_BASH", "bash"), str(SCRIPT), "publish", lane],
                    cwd=ROOT,
                    env=environment | {"PUBLISHING": "1"},
                    text=True,
                    capture_output=True,
                )
            records = {
                name: (audit / name).read_text().splitlines()
                if (audit / name).exists()
                else []
                for name in ("nix", "git", "gh")
            }
            return process, records

    def test_fast_lane_updates_selected_inputs_and_opens_pr(self):
        process, records = self.run_proposal("fast", changed=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(
            records["nix"][0],
            "flake update llm-agents claude-code-overlay cclens",
        )
        self.assertIn(
            "build --no-link .#nixosConfigurations.mini-vm.config.system.build.toplevel",
            records["nix"],
        )
        self.assertIn(
            "build --no-link .#homeConfigurations.gigun-mini-vm.activationPackage",
            records["nix"],
        )
        self.assertTrue(any(line.startswith("push origin HEAD:refs/heads/bot/flake-lock-fast") for line in records["git"]))
        self.assertTrue(any(line.startswith("pr create ") for line in records["gh"]))
        self.assertTrue(any(line.startswith("pr merge 42 ") for line in records["gh"]))

    def test_slow_lane_updates_all_inputs(self):
        process, records = self.run_proposal("slow", changed=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(records["nix"][0], "flake update")

    def test_no_change_stops_before_write_operations(self):
        process, records = self.run_proposal("fast", changed=False)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn("already current", process.stdout)
        self.assertEqual(records["gh"], [])
        self.assertFalse(any(line.startswith("commit ") for line in records["git"]))
        self.assertFalse(any(line.startswith("push ") for line in records["git"]))

    def test_unknown_lane_fails_before_running_tools(self):
        process, records = self.run_proposal("unexpected", changed=True)
        self.assertEqual(process.returncode, 2)
        self.assertIn("unknown flake update lane", process.stderr)
        self.assertEqual(records, {"nix": [], "git": [], "gh": []})


if __name__ == "__main__":
    unittest.main()
