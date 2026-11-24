"""Run propose-flake-lock.sh against a real Git repository with fake nix and gh."""
import calendar
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci/propose-flake-lock.sh"
BASH = os.environ.get("TEST_BASH") or shutil.which("bash")
GIT = shutil.which("git")
OLD = "a" * 40
TARGET = "b" * 40
FAST_INPUTS = "llm-agents claude-code-overlay cclens"
TARGET_MODIFIED = calendar.timegm((2026, 11, 20, 12, 0, 0))


def github_node(owner, repo, ref=None):
    original = {"owner": owner, "repo": repo, "type": "github"} | ({"ref": ref} if ref else {})
    return {"locked": {"lastModified": 1, "owner": owner, "repo": repo, "rev": OLD, "type": "github"},
            "original": original}


LOCK = {
    "nodes": {
        # The node key differs from the input name, as nixpkgs_4 does today.
        "root": {"inputs": {"nixpkgs": "nixpkgs_4", "llm-agents": "llm-agents",
                            "claude-code-overlay": "claude-code-overlay", "cclens": "cclens",
                            "tarball": "tarball"}},
        "nixpkgs_4": github_node("nixos", "nixpkgs", "nixpkgs-unstable"),
        "llm-agents": github_node("numtide", "llm-agents.nix"),
        "claude-code-overlay": github_node("ryoppippi", "claude-code-overlay"),
        "cclens": github_node("lambdalisue", "cclens"),
        "tarball": {"locked": {"lastModified": 1, "narHash": "sha256-fixture", "type": "tarball",
                               "url": "https://example.invalid/a.tar.gz"},
                    "original": {"type": "tarball", "url": "https://example.invalid/a.tar.gz"}},
    },
    "root": "root",
    "version": 7,
}

FAKE_NIX = """
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['AUDIT'] + '/nix', 'a') as audit:
    audit.write(' '.join(args) + '\\n')
if args[:2] == ['flake', 'update']:
    if os.environ.get('NO_CHANGE'):
        sys.exit(0)
    rest = args[2:]
    overrides = {}
    while '--override-input' in rest:
        index = rest.index('--override-input')
        overrides[rest[index + 1]] = rest[index + 2]
        del rest[index:index + 3]
    path = pathlib.Path('flake.lock')
    lock = json.loads(path.read_text())
    for name in rest:
        locked = lock['nodes'][lock['nodes']['root']['inputs'][name]]['locked']
        if name in overrides:
            locked['rev'] = 'c' * 40 if os.environ.get('WRONG_REV') else overrides[name].rsplit('/', 1)[1]
            locked['lastModified'] = int(os.environ['TARGET_MODIFIED'])
        else:
            locked['rev'] = 'f' * 40
            locked['lastModified'] = int(os.environ['LATEST_MODIFIED'])
    path.write_text(json.dumps(lock, indent=2) + '\\n')
    print('synthetic lock update')
elif args[0] == 'build' and os.environ.get('FAIL_BUILD'):
    sys.exit(19)
"""

FAKE_GH = """
import json, os, sys
args = sys.argv[1:]
with open(os.environ['AUDIT'] + '/gh', 'a') as audit:
    audit.write(json.dumps(args) + '\\n')
if args[:2] == ['pr', 'list']:
    print(os.environ.get('OPEN_PR', ''))
elif args[:2] == ['pr', 'view'] and 'number' in args:
    print(os.environ.get('OPEN_PR') or '42')
"""


class FlakeProposalTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = pathlib.Path(self.tmp.name)
        self.root = root
        self.audit = root / "audit"
        self.audit.mkdir()
        (root / "runner").mkdir()
        tools = root / "bin"
        tools.mkdir()
        for name, body in (("nix", FAKE_NIX), ("gh", FAKE_GH)):
            (tools / name).write_text(f"#!{sys.executable}\n" + textwrap.dedent(body))
            (tools / name).chmod(0o755)
        config = root / "gitconfig"
        config.write_text("[user]\nname = Synthetic\nemail = synthetic@example.invalid\n"
                          "[commit]\ngpgsign = false\n[core]\nhooksPath = /dev/null\n")
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")} | {
            "AUDIT": str(self.audit),
            "FAST_INPUTS": FAST_INPUTS,
            "GH_TOKEN": "fixture-token",
            "GITHUB_REPOSITORY": "gigun-dev/dotfiles",
            "GITHUB_OUTPUT": str(root / "github-output"),
            "GIT_ASKPASS": "/bin/false",
            "GIT_CONFIG_GLOBAL": str(config),
            "GIT_CONFIG_NOSYSTEM": "1",
            "HOME": str(root),
            "LATEST_MODIFIED": str(int(time.time()) - 5 * 86400),
            "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}",
            "RUNNER_TEMP": str(root / "runner"),
            "TARGET_MODIFIED": str(TARGET_MODIFIED),
        }
        self.remote = root / "origin.git"
        self.repo = root / "repo"
        self.repo.mkdir()
        (self.repo / "flake.lock").write_text(json.dumps(LOCK, indent=2) + "\n")
        self.git("init", "-q", "-b", "main")
        self.git("add", "flake.lock")
        self.git("commit", "-qm", "fixture")
        self.git("init", "-q", "--bare", str(self.remote), cwd=root)
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "-q", "origin", "main")

    def git(self, *args, cwd=None):
        return subprocess.run([GIT, *args], cwd=cwd or self.repo, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def run_script(self, *args, **extra):
        return subprocess.run([BASH, str(SCRIPT), *args], cwd=self.repo, env=self.env | extra,
                              text=True, capture_output=True)

    def propose(self, *args, **extra):
        prepare = self.run_script("prepare", *args, **extra)
        if prepare.returncode != 0 or "changed=true" not in self.output():
            return prepare
        return self.run_script("publish", *args, **extra)

    def output(self):
        path = self.root / "github-output"
        return path.read_text() if path.exists() else ""

    def records(self, name):
        path = self.audit / name
        return path.read_text().splitlines() if path.exists() else []

    def remote_commit(self, branch):
        result = subprocess.run([GIT, "--git-dir", str(self.remote), "log", "-1", "--format=%s%x00%T",
                                 f"refs/heads/{branch}"], env=self.env, capture_output=True, text=True)
        return result.stdout.strip().split("\0") if result.returncode == 0 else None

    def gh_calls(self):
        return [json.loads(line) for line in self.records("gh")]

    def builds(self):
        return [line for line in self.records("nix") if line.startswith("build ")]

    def test_fast_lane_updates_selected_inputs_and_opens_pr(self):
        process = self.propose("fast")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(self.records("nix")[0], f"flake update {FAST_INPUTS}")
        self.assertEqual(self.builds(), [
            "build --no-link .#nixosConfigurations.mini-vm.config.system.build.toplevel",
            "build --no-link .#homeConfigurations.gigun-mini-vm.activationPackage",
        ])
        subject, tree = self.remote_commit("bot/flake-lock-fast")
        self.assertEqual(subject, "chore(deps): flake.lock を更新 (fast)")
        self.assertEqual(tree, self.git("rev-parse", "HEAD^{tree}"))
        gh = self.gh_calls()
        self.assertTrue(any(call[:2] == ["pr", "create"] for call in gh))
        self.assertIn(["pr", "merge", "42", "--repo", "gigun-dev/dotfiles", "--auto", "--squash"], gh)

    def test_input_is_pinned_to_the_aged_target_in_its_own_branch(self):
        process = self.propose("input", "nixpkgs", TARGET_REV=TARGET)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(self.records("nix")[0],
                         f"flake update nixpkgs --override-input nixpkgs github:nixos/nixpkgs/{TARGET}")
        self.assertEqual(len(self.builds()), 2)
        title = "chore(deps): nixpkgs を更新 (aaaaaaaa → bbbbbbbb, 2026-11-20)"
        self.assertEqual(self.remote_commit("bot/flake-lock-nixpkgs")[0], title)
        self.assertIsNone(self.remote_commit("bot/flake-lock-fast"))
        create = next(call for call in self.gh_calls() if call[:2] == ["pr", "create"])
        self.assertEqual(create[create.index("--title") + 1], title)
        body = create[create.index("--body") + 1]
        self.assertIn(f"3 日以上前に commit された `{TARGET}`", body)

    def test_open_pr_is_retitled_instead_of_duplicated(self):
        process = self.propose("input", "nixpkgs", TARGET_REV=TARGET, OPEN_PR="7")
        self.assertEqual(process.returncode, 0, process.stderr)
        gh = self.gh_calls()
        self.assertFalse(any(call[:2] == ["pr", "create"] for call in gh))
        edit = next(call for call in gh if call[:2] == ["pr", "edit"])
        self.assertEqual(edit[2], "7")
        self.assertIn("nixpkgs を更新", edit[edit.index("--title") + 1])

    def test_existing_branch_is_replaced_from_the_current_main(self):
        self.assertEqual(self.propose("input", "nixpkgs", TARGET_REV=TARGET).returncode, 0)
        stale = self.git("rev-parse", "HEAD")
        self.git("reset", "-q", "--hard", "origin/main")
        (self.repo / "other.txt").write_text("main moved\n")
        self.git("add", "other.txt")
        self.git("commit", "-qm", "main moved")
        self.git("push", "-q", "origin", "main")
        (self.root / "github-output").unlink()
        process = self.propose("input", "nixpkgs", TARGET_REV=TARGET)
        self.assertEqual(process.returncode, 0, process.stderr)
        parent = subprocess.run([GIT, "--git-dir", str(self.remote), "rev-parse",
                                 "refs/heads/bot/flake-lock-nixpkgs^"], env=self.env,
                                capture_output=True, text=True).stdout.strip()
        self.assertEqual(parent, self.git("rev-parse", "origin/main"))
        self.assertNotEqual(parent, stale)

    def test_wrong_locked_revision_stops_before_build(self):
        process = self.propose("input", "nixpkgs", TARGET_REV=TARGET, WRONG_REV="1")
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("not " + TARGET, process.stderr)
        self.assertEqual(self.builds(), [])
        self.assertEqual(self.records("gh"), [])

    def test_without_target_a_young_latest_revision_is_discarded(self):
        process = self.propose("input", "tarball", LATEST_MODIFIED=str(int(time.time()) - 86400))
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(self.records("nix"), ["flake update tarball"])
        self.assertIn("changed=false", self.output())
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_without_target_an_old_latest_revision_is_proposed(self):
        process = self.propose("input", "tarball")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(self.records("nix")[0], "flake update tarball")
        self.assertIsNotNone(self.remote_commit("bot/flake-lock-tarball"))

    def test_target_requires_a_github_input(self):
        process = self.propose("input", "tarball", TARGET_REV=TARGET)
        self.assertEqual(process.returncode, 2)
        self.assertEqual(self.records("nix"), [])

    def test_tree_changed_after_build_is_not_published(self):
        prepare = self.run_script("prepare", "fast")
        self.assertEqual(prepare.returncode, 0, prepare.stderr)
        (self.repo / "flake.lock").write_text((self.repo / "flake.lock").read_text() + "\n")
        self.git("add", "flake.lock")
        publish = self.run_script("publish", "fast")
        self.assertNotEqual(publish.returncode, 0)
        self.assertIsNone(self.remote_commit("bot/flake-lock-fast"))
        self.assertEqual(self.records("gh"), [])

    def test_no_change_stops_before_write_operations(self):
        process = self.propose("fast", NO_CHANGE="1")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn("already current", process.stdout)
        self.assertEqual(self.builds(), [])
        self.assertEqual(self.records("gh"), [])
        self.assertIsNone(self.remote_commit("bot/flake-lock-fast"))

    def test_invalid_proposals_fail_before_running_tools(self):
        for args, extra, message in (
            (("unexpected",), {}, "unknown flake update proposal"),
            (("input", "llm-agents"), {}, "updated by the fast lane"),
            (("input", "fast"), {}, "invalid flake input name"),
            (("input", "../nixpkgs"), {}, "invalid flake input name"),
            (("input", "nixpkgs"), {"TARGET_REV": "main"}, "not a full commit hash"),
        ):
            with self.subTest(args=args, extra=extra):
                process = self.run_script("prepare", *args, **extra)
                self.assertEqual(process.returncode, 2)
                self.assertIn(message, process.stderr)
                self.assertEqual(self.records("nix"), [])


if __name__ == "__main__":
    unittest.main()
