#!/usr/bin/env python3
"""Prepare only a private three-job registration candidate; never issue or apply tokens."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import stat
import uuid

SOURCES = ("mini-vm-autoswitch", "mini-vm-lock-fast", "mini-vm-lock-slow")


def host_helper():
    spec = importlib.util.spec_from_file_location(
        "host_registration", Path(__file__).with_name("prepare-host-heartbeat-registration.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def prepare(existing, tokens):
    helper = host_helper()
    helper.validate_credentials(existing)
    if not isinstance(tokens, dict) or set(tokens) != set(SOURCES):
        raise ValueError("invalid job sources")
    references = [item for item in existing if item["source"] == "mini-vm"]
    if (len(references) != 1 or references[0]["ownerId"] != "homelab"
            or references[0]["destinations"] != ["bark"]):
        raise ValueError("unexpected reference routing")
    # Reuse the established credential/routing validation before comparing any entry.
    desired = helper.prepare([references[0]], "mini-vm", {s: tokens[s] for s in SOURCES})[1:]
    missing = {}
    for item in desired:
        matches = [old for old in existing if old["source"] == item["source"]]
        if matches and (len(matches) != 1 or matches[0] != item):
            raise ValueError("existing job registration differs")
        if not matches:
            missing[item["source"]] = item["token"]
    # prepare() changes only missing sources. Existing entries, order and fields survive.
    return helper.prepare(existing, "mini-vm", missing) if missing else existing


def read_private_json(path):
    # O_NOFOLLOW and fstat validate the actual opened inode, not a prior path lookup.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "r") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_uid != os.geteuid()):
            raise ValueError("input must be a private regular file")
        if info.st_size > 131072:
            raise ValueError("input too large")
        return json.load(stream, object_pairs_hook=unique_object)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def write_candidate(path, result):
    # Hold the verified directory inode throughout publication, even if renamed.
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    temporary = None
    try:
        info = os.fstat(directory)
        if (not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700
                or info.st_uid != os.geteuid()):
            raise ValueError("output directory must be private and owned")
        name = ".job-registration-" + uuid.uuid4().hex
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=directory)
        temporary = name
        with os.fdopen(fd, "w") as output:
            os.fchmod(output.fileno(), 0o600)
            json.dump(result, output)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        # No overwrite, including symlinks or a concurrent preparer's output.
        os.link(temporary, path.name, src_dir_fd=directory, dst_dir_fd=directory,
                follow_symlinks=False)
        os.fsync(directory)
    finally:
        try:
            if temporary is not None:
                os.unlink(temporary, dir_fd=directory)
        finally:
            os.close(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credentials-file", required=True, type=Path)
    parser.add_argument("--tokens-file", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = prepare(read_private_json(args.credentials_file), read_private_json(args.tokens_file))
    write_candidate(args.output, result)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, ImportError):
        raise SystemExit("job registration preparation failed; no credentials printed or applied")
