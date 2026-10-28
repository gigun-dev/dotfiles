#!/usr/bin/env python3
"""Fast-forward a clean mini checkout; never activate host configuration."""
import argparse
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys


def run_command(argv, env, timeout):
    process = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True)
    try:
        stdout, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        raise
    return process.returncode, stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default="/Users/gigun/ghq/github.com/gigun-dev/dotfiles")
    repo = Path(parser.parse_args().repo).resolve()
    env = dict(os.environ, DOTFILES_SKIP_AUTO_SWITCH="1", GIT_TERMINAL_PROMPT="0")

    def git(*args, allow_missing=False):
        try:
            returncode, stdout = run_command(["git", "-C", str(repo), *args], env, 60)
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"git {args[0]} timed out") from None
        if returncode and not (allow_missing and returncode == 1):
            raise RuntimeError(f"git {args[0]} failed (exit {returncode})")
        return stdout.strip()

    def guard(expected_head=None):
        if git("symbolic-ref", "--quiet", "--short", "HEAD", allow_missing=True) != "main":
            raise RuntimeError("checkout is not on main")
        hooks = git("config", "--path", "--get", "core.hooksPath", allow_missing=True)
        if hooks:
            raise RuntimeError("custom Git hook path requires review")
        hookdir = gitdir / "hooks"
        if hookdir.is_dir() and any(
            not item.name.endswith(".sample") and item.is_file() and os.access(item, os.X_OK)
            for item in hookdir.iterdir()
        ):
            raise RuntimeError("executable Git hooks require review")
        if git("status", "--porcelain=v1", "--untracked-files=all"):
            raise RuntimeError("checkout has uncommitted or untracked files")
        head = git("rev-parse", "HEAD")
        if expected_head and head != expected_head:
            raise RuntimeError("HEAD changed during fetch")
        for name in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"):
            if (gitdir / name).exists():
                raise RuntimeError("another Git operation is in progress")
        return head

    try:
        if Path(git("rev-parse", "--show-toplevel")).resolve() != repo:
            raise RuntimeError("repo is not the checkout root")
        gitdir = Path(git("rev-parse", "--absolute-git-dir"))
        with (gitdir / "mini-checkout-sync.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError("another checkout sync is running") from None
            old = guard()
            git("-c", "maintenance.auto=false", "-c", "gc.auto=0",
                "fetch", "--no-tags", "origin", "refs/heads/main:refs/remotes/origin/main")
            incoming = git("rev-parse", "refs/remotes/origin/main")
            guard(old)
            git("merge-base", "--is-ancestor", old, incoming)
            if old != incoming:
                git("merge", "--ff-only", "--no-overwrite-ignore", incoming)
            print(f"checkout sync: {old} -> {incoming}")
    except (OSError, RuntimeError) as error:
        print(f"checkout sync stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
