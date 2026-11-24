"""Exercise flake-lock-candidates.py against a fake GitHub API."""
import datetime
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci/flake-lock-candidates.py"
NOW = datetime.datetime.now(datetime.timezone.utc)
DAY = datetime.timedelta(days=1)

spec = importlib.util.spec_from_file_location("flake_lock_candidates", SCRIPT)
candidates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidates)

FAKE_GH = """
import json, os, re, sys
args = sys.argv[1:]
fixture = json.load(open(os.environ['FIXTURE']))
with open(os.environ['AUDIT'], 'a') as audit:
    audit.write(json.dumps(args) + '\\n')

def walk(repo, expression):
    sha, *steps = expression.split('~')
    for _ in range(sum(int(step) for step in steps)):
        sha = repo['commits'].get(sha, {}).get('parent')
    if sha not in repo['commits']:
        return None
    return {'oid': sha, 'committedDate': repo['commits'][sha]['date']}

if args[:2] == ['api', 'graphql']:
    fields = dict(arg.split('=', 1) for arg in args[3::2])
    name = fields['owner'] + '/' + fields['repo']
    if name in fixture.get('fail', []):
        sys.exit(1)
    repo = fixture['repos'][name]
    if 'ref' in fields:
        tip = repo['refs'].get(fields['ref'])
        data = {'object': {'oid': tip} if tip else None}
    else:
        aliases = re.findall(r'(c\\d+):object\\(expression:"([^"]+)"\\)', fields['query'])
        data = {alias: walk(repo, expression) for alias, expression in aliases}
    print(json.dumps({'data': {'repository': data}}))
elif args[:2] == ['pr', 'list']:
    print(json.dumps([{'headRefName': branch} for branch in fixture.get('behind', {})]
                     + [{'headRefName': 'feature/unrelated'}]))
elif args[0] == 'api':
    match = re.fullmatch(r'repos/(.+)/compare/(.+)\\.\\.\\.(.+)', args[1])
    owner_repo, base, head = match.groups()
    if base == 'main':
        print(fixture['behind'][head])
    else:
        print(fixture['repos'][owner_repo]['compare'].get(base + '...' + head, 'diverged'))
"""


def iso(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def chain(prefix, ages):
    """First-parent history, tip first, as {sha: {parent, date}} with fake SHAs."""
    shas = [f"{prefix}{index:0{40 - len(prefix)}x}" for index in range(len(ages))]
    commits = {sha: {"parent": shas[index + 1] if index + 1 < len(shas) else None, "date": iso(NOW - age)}
               for index, (sha, age) in enumerate(zip(shas, ages))}
    return shas, commits


def github_node(owner, repo, locked_rev, **original):
    return {"locked": {"owner": owner, "repo": repo, "rev": locked_rev, "type": "github"},
            "original": {"owner": owner, "repo": repo, "type": "github"} | original}


class CandidatesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        tools = self.root / "bin"
        tools.mkdir()
        (tools / "gh").write_text(f"#!{sys.executable}\n" + textwrap.dedent(FAKE_GH))
        (tools / "gh").chmod(0o755)
        # nixpkgs: one commit every 20 minutes, so three days back is commit 216,
        # on the second 128-commit page.
        self.nixpkgs, nixpkgs_commits = chain("a", [index * datetime.timedelta(minutes=20) for index in range(300)])
        self.young, young_commits = chain("b", [datetime.timedelta(hours=1), datetime.timedelta(hours=2)])
        self.home, home_commits = chain("c", [DAY, 4 * DAY, 5 * DAY])
        self.fixture = {
            "repos": {
                "nixos/nixpkgs": {"refs": {"nixpkgs-unstable": self.nixpkgs[0]}, "commits": nixpkgs_commits,
                                  "compare": {f"{self.nixpkgs[250]}...{self.nixpkgs[216]}": "ahead"}},
                "example/young": {"refs": {"HEAD": self.young[0]}, "commits": young_commits, "compare": {}},
                "nix-community/home-manager": {"refs": {"HEAD": self.home[0]}, "commits": home_commits,
                                               "compare": {f"{self.home[2]}...{self.home[1]}": "ahead"}},
                "example/current": {"refs": {"HEAD": self.home[0]}, "commits": home_commits, "compare": {}},
                "example/newer": {"refs": {"HEAD": self.home[0]}, "commits": home_commits,
                                  "compare": {f"{self.home[0]}...{self.home[1]}": "behind"}},
            },
            "fail": ["example/down"],
            "behind": {},
        }
        self.lock = {
            "nodes": {
                "root": {"inputs": {
                    "nixpkgs": "nixpkgs_4",
                    "home-manager": "home-manager",
                    "young": "young",
                    "current": "current",
                    "newer": "newer",
                    "down": "down",
                    "tarball": "tarball",
                    "pinned": "pinned",
                    "fast": "fast-named",
                    "llm-agents": "llm-agents",
                    "follower": ["home-manager"],
                }},
                "nixpkgs_4": github_node("nixos", "nixpkgs", self.nixpkgs[250], ref="nixpkgs-unstable"),
                "home-manager": github_node("nix-community", "home-manager", self.home[2]),
                "young": github_node("example", "young", "0" * 40),
                "current": github_node("example", "current", self.home[1]),
                "newer": github_node("example", "newer", self.home[0]),
                "down": github_node("example", "down", "0" * 40),
                "tarball": {"locked": {"type": "tarball", "url": "https://example.invalid/a.tar.gz"},
                            "original": {"type": "tarball", "url": "https://example.invalid/a.tar.gz"}},
                "pinned": github_node("example", "pinned", "1" * 40, rev="1" * 40),
                "fast-named": github_node("example", "fast", "0" * 40),
                "llm-agents": github_node("numtide", "llm-agents.nix", "0" * 40),
            },
            "root": "root",
            "version": 7,
        }

    def run_lane(self, *args):
        (self.root / "fixture.json").write_text(json.dumps(self.fixture))
        (self.root / "flake.lock").write_text(json.dumps(self.lock))
        output = self.root / "github-output"
        output.unlink(missing_ok=True)
        audit = self.root / "audit"
        audit.unlink(missing_ok=True)
        env = os.environ | {
            "AUDIT": str(audit),
            "FAST_INPUTS": "llm-agents claude-code-overlay cclens",
            "FIXTURE": str(self.root / "fixture.json"),
            "GITHUB_OUTPUT": str(output),
            "GITHUB_REPOSITORY": "gigun-dev/dotfiles",
            "PATH": f"{self.root / 'bin'}{os.pathsep}{os.environ['PATH']}",
        }
        process = subprocess.run([sys.executable, str(SCRIPT), *args, "--lock", str(self.root / "flake.lock")],
                                 env=env, text=True, capture_output=True)
        values = dict(line.split("=", 1) for line in output.read_text().splitlines()) if output.exists() else {}
        matrix = json.loads(values["matrix"])["include"] if "matrix" in values else None
        calls = [json.loads(line) for line in audit.read_text().splitlines()] if audit.exists() else []
        return process, matrix, calls

    def test_inputs_lane_pins_each_input_to_its_aged_first_parent_commit(self):
        process, matrix, calls = self.run_lane("inputs")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(matrix, [
            {"kind": "input", "name": "down", "target": ""},
            {"kind": "input", "name": "home-manager", "target": self.home[1]},
            {"kind": "input", "name": "nixpkgs", "target": self.nixpkgs[216]},
            {"kind": "input", "name": "tarball", "target": ""},
        ])
        # One tip lookup and two first-parent pages for nixpkgs.
        nixpkgs = [call for call in calls if call[:2] == ["api", "graphql"] and "owner=nixos" in call]
        self.assertEqual(len(nixpkgs), 3)
        self.assertIn("young: no commit is 3 days old yet", process.stdout)
        self.assertIn("current: already at the newest aged revision", process.stdout)
        self.assertIn("is behind relative to", process.stdout)
        self.assertIn("::warning::down: could not walk commit history", process.stdout)
        self.assertIn("pinned: pinned to a revision", process.stdout)

    def test_inputs_lane_excludes_fast_and_follows_inputs(self):
        _, matrix, calls = self.run_lane("inputs")
        names = {entry["name"] for entry in matrix}
        self.assertFalse(names & {"llm-agents", "fast", "follower", "pinned"})
        self.assertFalse(any("repo=llm-agents.nix" in call for call in calls))

    def test_input_filter(self):
        process, matrix, _ = self.run_lane("inputs", "--input", "nixpkgs")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual([entry["name"] for entry in matrix], ["nixpkgs"])
        for name in ("llm-agents", "follower", "missing"):
            with self.subTest(name=name):
                process, matrix, _ = self.run_lane("inputs", "--input", name)
                self.assertEqual(process.returncode, 2)
                self.assertIsNone(matrix)

    def test_fast_lane_needs_no_github_calls(self):
        process, matrix, calls = self.run_lane("fast")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(matrix, [{"kind": "fast", "name": "fast", "target": ""}])
        self.assertEqual(calls, [])

    def test_refresh_rebuilds_only_bot_branches_behind_main(self):
        self.fixture["behind"] = {
            "bot/flake-lock-fast": 1,
            "bot/flake-lock-nixpkgs": 0,
            "bot/flake-lock-home-manager": 2,
            "bot/flake-lock-young": 1,
            "bot/flake-lock-gone": 1,
        }
        process, matrix, _ = self.run_lane("refresh")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(matrix, [
            {"kind": "fast", "name": "fast", "target": ""},
            {"kind": "input", "name": "home-manager", "target": self.home[1]},
        ])
        self.assertIn("bot/flake-lock-gone does not match a root input", process.stdout)
        self.assertIn("bot/flake-lock-young has nothing left to propose", process.stdout)

    def test_refresh_without_bot_prs_is_empty(self):
        process, matrix, _ = self.run_lane("refresh")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(matrix, [])

    def test_select_aged_commit(self):
        cutoff = NOW - 3 * DAY
        young = {"oid": "y", "committedDate": iso(NOW)}
        old = {"oid": "o", "committedDate": iso(NOW - 4 * DAY)}
        self.assertEqual(candidates.select_aged_commit([young, old], cutoff)["sha"], "o")
        self.assertEqual(candidates.select_aged_commit([young, None], cutoff), {"status": "none"})
        self.assertEqual(candidates.select_aged_commit([young, young], cutoff), {"status": "more", "next": "y~1"})


if __name__ == "__main__":
    unittest.main()
