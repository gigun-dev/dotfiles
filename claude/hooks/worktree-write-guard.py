#!/usr/bin/env python3
"""Reject Write/Edit escapes into another checkout of the same repository.

This checks structured file paths, not shell commands. Different repositories
remain outside this guard; their checkout must be assigned by the parent.
"""

import json
import os
from pathlib import Path
import subprocess
import sys


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))


def repository(directory):
    # Clear inherited Git routing so cwd, not a caller's GIT_DIR, selects the repo.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("GIT_")}
    env["LC_ALL"] = "C"

    def query(*args):
        result = subprocess.run(
            ["git", "-C", str(directory), "rev-parse", *args],
            capture_output=True, text=True, env=env, timeout=1,
        )
        if result.returncode:
            if "not a git repository (or any" in result.stderr:
                return None
            raise RuntimeError(f"Git could not inspect {directory}: {result.stderr.strip()}")
        return result.stdout.strip()

    git_dir = query("--absolute-git-dir")
    if git_dir is None:
        return None
    common = query("--path-format=absolute", "--git-common-dir")
    root = query("--show-toplevel")
    if common is None or root is None:
        raise RuntimeError(f"Git repository changed while inspecting {directory}")
    return Path(git_dir).resolve(), Path(common).resolve(), Path(root).resolve()


def main():
    try:
        event = json.load(sys.stdin)
        if not isinstance(event, dict):
            raise ValueError("Hook input must be an object")
        if event.get("tool_name") not in ("Write", "Edit"):
            return
        cwd = Path(event["cwd"]).resolve(strict=True)
        current = repository(cwd)
        if current is None or current[0] == current[1]:
            return
        file_path = event["tool_input"]["file_path"]
        if not isinstance(file_path, str) or not file_path:
            raise ValueError("Write/Edit file_path is missing or empty")
        target = Path(file_path)
        if not target.is_absolute():
            target = cwd / target
        # resolve follows existing symlinks even when the final file is new.
        target = target.resolve()
        ancestor = target
        while not ancestor.exists():
            ancestor = ancestor.parent
        if not ancestor.is_dir():
            ancestor = ancestor.parent
        destination = repository(ancestor)
        if (destination is not None and destination[1] == current[1]
                and destination[2] != current[2]):
            deny(f"Write/Edit targets another checkout of this repository: {target}. "
                 f"Use the assigned worktree {current[2]}.")
    except (OSError, ValueError, KeyError, TypeError, RuntimeError,
            subprocess.SubprocessError) as error:
        # A broken Git query must not silently turn protection off.
        deny(f"Worktree write guard could not verify this write: {error}")


if __name__ == "__main__":
    main()
