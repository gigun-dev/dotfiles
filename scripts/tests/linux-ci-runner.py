"""Check the self-hosted runner preflight with fake system commands."""
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RunnerPreflight(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="linux-runner-test-")
        self.addCleanup(self.tmp.cleanup)
        self.bin = Path(self.tmp.name)
        shell = os.environ.get("TEST_SH", "/bin/sh")
        for name, body in {
            "uname": 'case "$1" in -s) echo "${FAKE_OS:-Linux}";; -m) echo "${FAKE_ARCH:-x86_64}";; esac',
            "nix": '''case "$*" in
  "config show accept-flake-config") echo "${FAKE_ACCEPT:-true}";;
  "config show max-jobs") echo "${FAKE_JOBS:-1}";;
  "config show cores") echo "${FAKE_CORES:-2}";;
  "config show experimental-features") echo "${FAKE_FEATURES:-flakes nix-command}";;
  "eval --impure --raw --expr builtins.currentSystem") echo "${FAKE_SYSTEM:-x86_64-linux}";;
  *) exit 1;;
esac''',
        }.items():
            path = self.bin / name
            path.write_text(f"#!{shell}\n{body}\n")
            path.chmod(0o755)
        action = (ROOT / ".github/actions/check-linux-runner/action.yaml").read_text()
        self.script = textwrap.dedent(action.split("      run: |\n", 1)[1])

    def run_preflight(self, **variables):
        env = {"PATH": str(self.bin), **variables}
        return subprocess.run([os.environ.get("TEST_BASH", "/bin/bash"), "-c", self.script],
                              env=env, capture_output=True, text=True)

    def test_valid_runner_passes(self):
        self.assertEqual(self.run_preflight().returncode, 0)

    def test_wrong_platform_or_config_fails(self):
        for key, value in (("FAKE_OS", "Darwin"), ("FAKE_ARCH", "aarch64"),
                           ("FAKE_ACCEPT", "false"), ("FAKE_JOBS", "auto"),
                           ("FAKE_CORES", "0"), ("FAKE_FEATURES", "flakes"),
                           ("FAKE_SYSTEM", "aarch64-linux")):
            with self.subTest(key=key):
                self.assertNotEqual(self.run_preflight(**{key: value}).returncode, 0)

    def test_missing_nix_fails(self):
        (self.bin / "nix").unlink()
        self.assertNotEqual(self.run_preflight().returncode, 0)

    def test_workflow_writes_multiline_nix_config(self):
        workflow = (ROOT / ".github/workflows/nix-build.yaml").read_text()
        commands = [line.strip() for line in workflow.splitlines()
                    if line.strip().startswith("printf 'NIX_CONFIG<<EOF")]
        self.assertEqual(len(commands), 3)
        output = Path(self.tmp.name) / "github-env"
        for command in commands:
            output.write_text("")
            subprocess.run([os.environ.get("TEST_BASH", "/bin/bash"), "-c", command],
                           env={"GITHUB_ENV": str(output)}, check=True)
            self.assertEqual(output.read_text(),
                             "NIX_CONFIG<<EOF\naccept-flake-config = true\n"
                             "max-jobs = 1\ncores = 2\nEOF\n")

    def test_every_required_workflow_job_can_use_the_reviewed_runner(self):
        workflow = (ROOT / ".github/workflows/nix-build.yaml").read_text()
        selector = ("vars.DOTFILES_LINUX_CI == 'self-hosted' && "
                    "vars.DOTFILES_CI_REVIEWED_SHA != '' && "
                    "github.sha == vars.DOTFILES_CI_REVIEWED_SHA")
        self.assertEqual(workflow.count(selector), 5)
        self.assertIn("  nix-ci-gate:\n", workflow)
        self.assertIn("  secret-scan:\n", workflow)

    def test_secret_scan_is_read_only_and_required_by_the_gate(self):
        workflow = (ROOT / ".github/workflows/nix-build.yaml").read_text()
        scan = workflow.split("  secret-scan:\n", 1)[1].split("\n  check:\n", 1)[0]
        gate = workflow.split("  nix-ci-gate:\n", 1)[1]
        self.assertIn("persist-credentials: false", scan)
        self.assertIn("nix run .#gitleaks -- dir . --redact=100 --no-banner", scan)
        self.assertIn("nixpkgs#actionlint -c actionlint -no-color", scan)
        self.assertIn("nixpkgs#zizmor -c zizmor", scan)
        self.assertIn("--offline --persona regular --min-severity medium", scan)
        self.assertIn("--strict-collection --format github", scan)
        self.assertIn("--no-progress --no-config --no-ignores .", scan)
        self.assertIn("      - secret-scan\n", gate)
        self.assertIn("CI_SECRET_SCAN_RESULT: ${{ needs.secret-scan.result }}", gate)

    def test_write_checkout_explicitly_keeps_push_credentials(self):
        workflow = (ROOT / ".github/workflows/fzf-update.yml").read_text()
        self.assertIn("permissions:\n      contents: write", workflow)
        self.assertIn("persist-credentials: true", workflow)

    def test_every_always_on_linux_workflow_can_use_the_reviewed_runner(self):
        selector = ("vars.DOTFILES_LINUX_CI == 'self-hosted' && "
                    "vars.DOTFILES_CI_REVIEWED_SHA != '' && "
                    "github.sha == vars.DOTFILES_CI_REVIEWED_SHA")
        recipe = (ROOT / ".github/workflows/fzf-recipe-checks.yml").read_text()
        ansible = (ROOT / ".github/workflows/mini-ansible.yaml").read_text()
        self.assertEqual(recipe.count(selector), 1)
        self.assertEqual(ansible.count(selector), 1)
        self.assertIn("  native:\n", ansible)
        native = ansible.split("  native:\n", 1)[1]
        self.assertNotIn(selector, native)

    def test_portable_ansible_uses_existing_nix_on_reviewed_runner(self):
        workflow = (ROOT / ".github/workflows/mini-ansible.yaml").read_text()
        portable = workflow.split("  portable:\n", 1)[1].split("\n  native:\n", 1)[0]
        self.assertIn("runner.environment == 'self-hosted'", portable)
        self.assertIn("uses: ./.github/actions/check-linux-runner", portable)
        self.assertIn("runner.environment != 'self-hosted'", portable)


if __name__ == "__main__":
    unittest.main()
