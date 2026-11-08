#!/usr/bin/env python3
"""Compare a prepared private export and restore without printing their metadata."""

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import stat


FAILURE = "private restore verification failed; no paths, contents, or digests printed"
MANIFEST_LIMIT = 64 * 1024
FILE_LIMIT = 16 * 1024 * 1024
ID = re.compile(r"[a-z][a-z0-9-]{0,63}\Z")
TOP_KEYS = {
    "schema_version", "owner_role", "primary_store_ref", "backup_store_ref",
    "failure_domains_independent", "objects",
}
OBJECT_KEYS = {
    "id", "primary_file", "restored_file", "expected_mode", "public_counterparts",
    "primary_read_verified", "backup_read_verified", "human_readable_verified",
    "restore_test_at", "remaining_gaps",
}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def _private_regular(info, limit):
    return (
        stat.S_ISREG(info.st_mode)
        and stat.S_IMODE(info.st_mode) == 0o600
        and info.st_uid == os.geteuid()
        and info.st_nlink == 1
        and info.st_size <= limit
    )


def read_private_manifest(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        if not _private_regular(info, MANIFEST_LIMIT):
            raise ValueError("unsafe manifest")
        data = b""
        while True:
            part = os.read(fd, min(65536, MANIFEST_LIMIT + 1 - len(data)))
            if not part:
                break
            data += part
            if len(data) > MANIFEST_LIMIT:
                raise ValueError("large manifest")
        return json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)
    finally:
        os.close(fd)


def _identifier(value):
    return type(value) is str and ID.fullmatch(value) is not None


def _basename(value):
    return (
        type(value) is str
        and value not in {"", ".", ".."}
        and "/" not in value
        and "\\" not in value
        and "\0" not in value
        and os.path.basename(value) == value
    )


def _public_path(value):
    if type(value) is not str or not value or "\\" in value or "\0" in value:
        return False
    if any(part in {"", ".", ".."} for part in value.split("/")):
        return False
    path = Path(value)
    return not path.is_absolute()


def _timestamp(value):
    if type(value) is not str or not value.endswith("Z"):
        return False
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return False
    return True


def validate_manifest(value, *, require_attestation=True):
    if type(value) is not dict or set(value) != TOP_KEYS:
        raise ValueError("manifest shape")
    if value["schema_version"] != 1 or type(value["schema_version"]) is not int:
        raise ValueError("schema")
    if not all(_identifier(value[key]) for key in ("owner_role", "primary_store_ref", "backup_store_ref")):
        raise ValueError("identifier")
    if value["primary_store_ref"] == value["backup_store_ref"]:
        raise ValueError("store identity")
    if type(value["failure_domains_independent"]) is not bool:
        raise ValueError("independence type")
    if require_attestation and not value["failure_domains_independent"]:
        raise ValueError("independence")
    objects = value["objects"]
    if type(objects) is not list or not 1 <= len(objects) <= 32:
        raise ValueError("objects")
    ids = set()
    primary_files = set()
    restored_files = set()
    for item in objects:
        if type(item) is not dict or set(item) != OBJECT_KEYS:
            raise ValueError("object shape")
        if not _identifier(item["id"]) or item["id"] in ids:
            raise ValueError("object id")
        ids.add(item["id"])
        for key, seen in (("primary_file", primary_files), ("restored_file", restored_files)):
            name = item[key]
            if not _basename(name) or name in seen:
                raise ValueError("file name")
            seen.add(name)
        if item["expected_mode"] != "0600":
            raise ValueError("mode")
        counterparts = item["public_counterparts"]
        if type(counterparts) is not list or not all(_public_path(path) for path in counterparts):
            raise ValueError("public path")
        if len(counterparts) != len(set(counterparts)):
            raise ValueError("duplicate public path")
        for key in ("primary_read_verified", "backup_read_verified", "human_readable_verified"):
            if type(item[key]) is not bool:
                raise ValueError("attestation type")
            if require_attestation and not item[key]:
                raise ValueError("attestation")
        if item["restore_test_at"] is not None and not _timestamp(item["restore_test_at"]):
            raise ValueError("timestamp")
        if require_attestation and not _timestamp(item["restore_test_at"]):
            raise ValueError("timestamp missing")
        gaps = item["remaining_gaps"]
        if type(gaps) is not list or not all(type(gap) is str and gap for gap in gaps):
            raise ValueError("gaps")
        if require_attestation and gaps:
            raise ValueError("remaining gaps")
    return value


def open_private_root(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700 or info.st_uid != os.geteuid():
            raise ValueError("unsafe root")
    except Exception:
        os.close(fd)
        raise
    return fd, info


def open_private_file(root_fd, name):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=root_fd)
    try:
        info = os.fstat(fd)
        if not _private_regular(info, FILE_LIMIT):
            raise ValueError("unsafe file")
    except Exception:
        os.close(fd)
        raise
    return fd, info


def _identity(info):
    return info.st_dev, info.st_ino


def _snapshot(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def compare_open_files(primary_fd, restored_fd, primary_info, restored_info):
    if _identity(primary_info) == _identity(restored_info):
        raise ValueError("same inode")
    while True:
        left = os.read(primary_fd, 65536)
        right = os.read(restored_fd, 65536)
        if left != right:
            raise ValueError("content mismatch")
        if not left:
            break
    if _snapshot(primary_info) != _snapshot(os.fstat(primary_fd)):
        raise ValueError("primary changed")
    if _snapshot(restored_info) != _snapshot(os.fstat(restored_fd)):
        raise ValueError("restore changed")


def verify(manifest_path, primary_path, restored_path):
    manifest = validate_manifest(read_private_manifest(manifest_path))
    primary_root, primary_root_info = open_private_root(primary_path)
    restored_root = None
    try:
        restored_root, restored_root_info = open_private_root(restored_path)
        if _identity(primary_root_info) == _identity(restored_root_info):
            raise ValueError("same root")
        for item in manifest["objects"]:
            primary_fd = restored_fd = None
            try:
                primary_fd, primary_info = open_private_file(primary_root, item["primary_file"])
                restored_fd, restored_info = open_private_file(restored_root, item["restored_file"])
                compare_open_files(primary_fd, restored_fd, primary_info, restored_info)
            finally:
                if restored_fd is not None:
                    os.close(restored_fd)
                if primary_fd is not None:
                    os.close(primary_fd)
    finally:
        if restored_root is not None:
            os.close(restored_root)
        os.close(primary_root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--primary-root", required=True, type=Path)
    parser.add_argument("--restored-root", required=True, type=Path)
    args = parser.parse_args()
    verify(args.manifest, args.primary_root, args.restored_root)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError, UnicodeError, json.JSONDecodeError):
        raise SystemExit(FAILURE)
