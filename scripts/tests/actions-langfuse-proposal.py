import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci/propose-langfuse-update.sh"
COMPOSE = ROOT / "infra/langfuse/compose.yaml"


class LangfuseProposalTest(unittest.TestCase):
    def run_proposal(self, version: str, failure: str | None = None):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            compose = root / "infra/langfuse/compose.yaml"
            compose.parent.mkdir(parents=True)
            shutil.copyfile(COMPOSE, compose)
            if failure == "worker-drift":
                compose.write_text(
                    compose.read_text().replace(
                        "docker.langfuse.com/langfuse/langfuse-worker:",
                        "docker.langfuse.com/langfuse/worker:",
                    )
                )
            tools = root / "bin"
            tools.mkdir()
            audit = root / "audit"
            audit.mkdir()
            bash = os.environ.get("TEST_BASH") or shutil.which("bash")
            self.assertIsNotNone(bash)
            shebang = f"#!{bash}\n"

            release = json.dumps(
                [
                    {
                        "draft": False,
                        "prerelease": False,
                        "tag_name": f"v{version}",
                        "published_at": "2020-01-01T00:00:00Z",
                    }
                ]
            )
            (tools / "curl").write_text(
                shebang + f"printf '%s\\n' '{release}'\n"
            )
            (tools / "skopeo").write_text(
                shebang
                + textwrap.dedent(
                    """\
                    case "$*" in
                      *langfuse-worker*)
                        [[ "$FAILURE" = digest ]] && printf 'invalid\n' || printf 'sha256:%064d\n' 2
                        ;;
                      *) printf 'sha256:%064d\n' 1 ;;
                    esac
                    """
                )
            )
            (tools / "docker-compose").write_text(
                shebang + 'printf \'%s\\n\' "$*" >> "$AUDIT/compose"\n'
            )
            (tools / "nix").write_text(
                shebang + 'printf \'%s\\n\' "$*" >> "$AUDIT/nix"\n'
            )
            (tools / "git").write_text(
                shebang
                + textwrap.dedent(
                    """\
                    printf '%s\n' "$*" >> "$AUDIT/git"
                    if [[ "$*" = "diff --cached --name-only" ]]; then printf 'infra/langfuse/compose.yaml\n'; exit 0; fi
                    if [[ "$1" = write-tree || "$1" = rev-parse ]]; then printf 'fixture-tree\n'; exit 0; fi
                    if [[ "$1" = ls-remote ]]; then exit 2; fi
                    exit 0
                    """
                )
            )
            (tools / "gh").write_text(
                shebang
                + textwrap.dedent(
                    """\
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
                "GH_TOKEN": "fixture-token",
                "GITHUB_REPOSITORY": "gigun-dev/dotfiles",
                "GIT_ASKPASS": str(tools / "git"),
                "PATH": f"{tools}:{os.environ['PATH']}",
                "GITHUB_OUTPUT": str(root / "github-output"),
                "FAILURE": failure or "",
                "RUNNER_TEMP": str(root),
            }
            prepare = subprocess.run(
                [os.environ.get("TEST_BASH", "bash"), str(SCRIPT), "prepare"],
                cwd=root,
                env=environment,
                text=True,
                capture_output=True,
            )
            process = prepare
            if prepare.returncode == 0 and version == "4.99.0":
                process = subprocess.run(
                    [os.environ.get("TEST_BASH", "bash"), str(SCRIPT), "publish"],
                    cwd=root,
                    env=environment,
                    text=True,
                    capture_output=True,
                )
            records = {
                name: (audit / name).read_text().splitlines()
                if (audit / name).exists()
                else []
                for name in ("compose", "nix", "git", "gh")
            }
            return process, records, compose.read_text()

    def test_newer_release_is_pinned_built_and_proposed(self):
        process, records, compose = self.run_proposal("4.99.0")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn("langfuse:4.99.0@sha256:", compose)
        self.assertIn("langfuse-worker:4.99.0@sha256:", compose)
        self.assertEqual(
            records["compose"],
            ["-f infra/langfuse/compose.yaml config --no-interpolate --quiet"],
        )
        self.assertIn(
            "build --no-link .#nixosConfigurations.mini-vm.config.system.build.toplevel",
            records["nix"],
        )
        self.assertTrue(any(line.startswith("push origin HEAD:refs/heads/bot/langfuse-v4") for line in records["git"]))
        self.assertTrue(any(line.startswith("pr create ") for line in records["gh"]))
        self.assertTrue(any(line.startswith("pr merge 42 ") for line in records["gh"]))

    def test_older_release_stops_before_writes(self):
        process, records, compose = self.run_proposal("4.1.0")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn("より新しく", process.stdout)
        self.assertEqual(records, {"compose": [], "nix": [], "git": [], "gh": []})
        self.assertEqual(compose, COMPOSE.read_text())

    def test_malformed_digest_fails_before_staging(self):
        process, records, _ = self.run_proposal("4.99.0", "digest")
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(records["git"], [])

    def test_missing_worker_pattern_fails_closed(self):
        process, records, _ = self.run_proposal("4.99.0", "worker-drift")
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(records["compose"], [])
        self.assertEqual(records["git"], [])


if __name__ == "__main__":
    unittest.main()
