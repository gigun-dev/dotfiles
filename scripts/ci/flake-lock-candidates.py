#!/usr/bin/env python3
"""Choose the flake.lock proposals one workflow run prepares.

Runs with a read-only token and no Nix: it only reads flake.lock and GitHub
metadata. The writer token and the candidate builds live in the next job.
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys

BRANCH_PREFIX = "bot/flake-lock-"
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")
SHA = re.compile(r"^[0-9a-f]{40}$")
# GraphQL resolves `<rev>~N` along first parents only. A date-filtered commit list
# would also return commits of merged side branches, whose trees can be older
# than the lock (ryoppippi/dotfiles 7931ffbc hit this with nixpkgs).
PAGE_SIZE = 128
# nixpkgs-unstable gains about 250 first-parent commits a day (measured
# 2026-11-24: ~250 → 11-21, ~2000 → 11-15). Stop well past three days of that
# instead of walking a whole history on an unexpected ref.
MAX_PAGES = 40


class Unavailable(Exception):
    """GitHub could not answer; the caller decides how to degrade."""


def gh(*args):
    try:
        result = subprocess.run(["gh", *args], capture_output=True, text=True)
    except OSError as error:
        raise Unavailable(str(error)) from error
    if result.returncode != 0:
        raise Unavailable(f"gh {args[0]} {args[1]} exited {result.returncode}: {result.stderr.strip()}")
    return result.stdout


def graphql(query, **variables):
    args = ["api", "graphql", "-f", f"query={query}"]
    for key, value in variables.items():
        args += ["-f", f"{key}={value}"]
    try:
        repository = json.loads(gh(*args))["data"]["repository"]
    except (ValueError, KeyError, TypeError) as error:
        raise Unavailable(f"unexpected GraphQL response: {error}") from error
    if repository is None:
        raise Unavailable("repository not found")
    return repository


def select_aged_commit(commits, cutoff):
    """Pick the first commit at or before cutoff from one first-parent page.

    A None entry means the history ended inside this page.
    """
    for commit in commits:
        if commit is not None and parse_date(commit["committedDate"]) <= cutoff:
            return {"status": "found", "sha": commit["oid"], "date": commit["committedDate"]}
    if any(commit is None for commit in commits):
        return {"status": "none"}
    return {"status": "more", "next": commits[-1]["oid"] + "~1"}


def aged_commit(owner, repo, ref, cutoff):
    tip_query = ("query($owner:String!,$repo:String!,$ref:String!){repository(owner:$owner,name:$repo)"
                 "{object(expression:$ref){... on Commit{oid}}}}")
    tip = graphql(tip_query, owner=owner, repo=repo, ref=ref or "HEAD")["object"]
    if not tip:
        raise Unavailable(f"{ref or 'HEAD'} does not resolve to a commit")
    revision = tip["oid"]
    for _ in range(MAX_PAGES):
        fields = " ".join(
            f"c{index}:object(expression:{json.dumps(f'{revision}~{index}')}){{... on Commit{{oid committedDate}}}}"
            for index in range(PAGE_SIZE)
        )
        page = graphql("query($owner:String!,$repo:String!){repository(owner:$owner,name:$repo){" + fields + "}}",
                       owner=owner, repo=repo)
        result = select_aged_commit([page.get(f"c{index}") for index in range(PAGE_SIZE)], cutoff)
        if result["status"] != "more":
            return result
        revision = result["next"]
    raise Unavailable(f"no commit older than the cutoff within {MAX_PAGES * PAGE_SIZE} first-parent commits")


def parse_date(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def root_inputs(lock):
    nodes = lock["nodes"]
    for name, node in sorted(nodes["root"]["inputs"].items()):
        # A list is `follows`: the input is another input's node, not its own lock entry.
        if isinstance(node, str):
            yield name, nodes[node]


def warn(message):
    print(f"::warning::{message}")


def input_candidate(name, node, cutoff, min_age_days):
    """Return a matrix entry when `name` has an update old enough to propose."""
    original = node.get("original", {})
    current = node.get("locked", {}).get("rev", "")
    entry = {"kind": "input", "name": name, "target": ""}
    if "rev" in original:
        print(f"{name}: pinned to a revision in flake.nix, skipped")
        return None
    owner, repo = original.get("owner", ""), original.get("repo", "")
    # Without a GitHub history to walk, the prepare job updates to the latest
    # revision and discards it when lastModified is younger than the minimum age.
    if original.get("type") != "github" or not owner or not repo:
        print(f"{name}: not a GitHub input, prepare checks lastModified instead")
        return entry
    try:
        target = aged_commit(owner, repo, original.get("ref", ""), cutoff)
    except Unavailable as error:
        warn(f"{name}: could not walk commit history ({error}); prepare checks lastModified instead")
        return entry
    if target["status"] == "none":
        print(f"{name}: no commit is {min_age_days} days old yet")
        return None
    sha = target["sha"]
    if not SHA.match(sha):
        raise SystemExit(f"{name}: GitHub returned a malformed revision")
    if sha == current:
        print(f"{name}: already at the newest aged revision {sha[:8]}")
        return None
    # The aged revision can be older than, or off the history of, a lock that a
    # human or the latest-tracking fast lane already moved forward. Proposing it
    # would be a downgrade or a branch switch (ryoppippi/dotfiles 4d02b87d).
    if current:
        try:
            status = gh("api", f"repos/{owner}/{repo}/compare/{current}...{sha}", "--jq", ".status").strip()
        except Unavailable as error:
            warn(f"{name}: could not compare {current[:8]}...{sha[:8]} ({error}); skipped")
            return None
        if status != "ahead":
            print(f"{name}: aged revision {sha[:8]} is {status} relative to {current[:8]}, skipped")
            return None
    print(f"{name}: {current[:8] or 'unknown'} -> {sha[:8]} ({target['date']})")
    return entry | {"target": sha}


def open_bot_branches(repository):
    """Bot proposal branches that main has moved past since they were pushed."""
    listing = json.loads(gh("pr", "list", "--repo", repository, "--state", "open", "--base", "main",
                            "--limit", "200", "--json", "headRefName"))
    behind = []
    for pr in listing:
        branch = pr["headRefName"]
        if not branch.startswith(BRANCH_PREFIX):
            continue
        count = gh("api", f"repos/{repository}/compare/main...{branch}", "--jq", ".behind_by").strip()
        if count != "0":
            behind.append(branch[len(BRANCH_PREFIX):])
    return behind


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("lane", choices=["fast", "inputs", "refresh"])
    parser.add_argument("--input", default="", help="limit the inputs lane to one root input")
    parser.add_argument("--lock", default="flake.lock")
    args = parser.parse_args()

    fast_inputs = os.environ["FAST_INPUTS"].split()
    min_age_days = int(os.environ.get("MINIMUM_RELEASE_AGE_DAYS", "3"))
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=min_age_days)
    with open(args.lock) as handle:
        inputs = dict(root_inputs(json.load(handle)))
    # Each input's branch is bot/flake-lock-<name>, so an input called "fast"
    # would share the fast lane's branch.
    slow_inputs = {name: node for name, node in inputs.items()
                   if name not in fast_inputs and name != "fast" and NAME.match(name)}

    fast = False
    names = []
    if args.lane == "fast":
        fast = True
    elif args.lane == "inputs":
        names = sorted(slow_inputs)
        if args.input:
            if args.input not in slow_inputs:
                print(f"{args.input} is not a root input outside the fast lane", file=sys.stderr)
                return 2
            names = [args.input]
    else:
        # main requires branches to be up to date, so merging one proposal stalls
        # every other auto-merge. Rebuild only the stale ones from the new main.
        for name in open_bot_branches(os.environ["GITHUB_REPOSITORY"]):
            if name == "fast":
                fast = True
            elif name in slow_inputs:
                names.append(name)
            else:
                warn(f"{BRANCH_PREFIX}{name} does not match a root input")

    entries = [{"kind": "fast", "name": "fast", "target": ""}] if fast else []
    for name in names:
        entry = input_candidate(name, slow_inputs[name], cutoff, min_age_days)
        if entry:
            entries.append(entry)
        elif args.lane == "refresh":
            warn(f"{BRANCH_PREFIX}{name} has nothing left to propose; close its PR by hand")

    print(f"{len(entries)} proposal(s): {' '.join(entry['name'] for entry in entries) or '<none>'}")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"matrix={json.dumps({'include': entries}, separators=(',', ':'))}\n")
        output.write(f"count={len(entries)}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
