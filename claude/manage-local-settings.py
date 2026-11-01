#!/usr/bin/env python3
"""Reconcile the declared Claude settings with host-local edits."""
import json
import os
from pathlib import Path
import subprocess
import stat
import sys
import tempfile


def identity(path):
    info = path.lstat()
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def encode(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key in settings")
        result[key] = value
    return result


def decode(data):
    return json.loads(data, object_pairs_hook=unique_object)


def with_marketplace(data, marketplace):
    data["extraKnownMarketplaces"]["gigun"]["source"]["path"] = marketplace
    return data


MISSING = object()


def same(left, right):
    if left is MISSING or right is MISSING:
        return left is right
    return encode(left) == encode(right)


def reconcile(base, local, desired):
    if same(local, base):
        return desired
    if same(desired, base) or same(local, desired):
        return local
    if base is MISSING and isinstance(local, dict) and isinstance(desired, dict):
        base = {}
    if all(isinstance(value, dict) for value in (base, local, desired)):
        result = {}
        for key in base.keys() | local.keys() | desired.keys():
            value = reconcile(base.get(key, MISSING), local.get(key, MISSING), desired.get(key, MISSING))
            if value is not MISSING:
                result[key] = value
        return result
    raise ValueError("local and declared settings conflict; no settings changed")


def atomic_write(path, content, mode=0o600, verify=None):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".claude-settings-", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as output:
            output.write(content)
        if verify is not None:
            verify()
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def main():
    settings, tracked, template, state = map(Path, sys.argv[1:5])
    marketplace, git = sys.argv[5:7]
    desired = with_marketplace(decode(template.read_bytes()), marketplace)
    exists = settings.exists() or settings.is_symlink()
    if exists:
        if settings.is_symlink() and settings.resolve(strict=True) != tracked.resolve(strict=True):
            raise ValueError("settings symlink is not the dotfiles template")
        if not settings.is_file():
            raise ValueError("settings is not a regular file")
        before = identity(settings)
        mode = stat.S_IMODE(settings.stat().st_mode)
        original = settings.read_bytes()
        local = decode(original)
        if state.exists():
            base = decode(state.read_bytes())
        else:
            # The checkout HEAD records the template before its local edits.
            result = subprocess.run(
                [git, "-C", str(tracked.parent.parent), "show", "HEAD:claude/settings.json"],
                check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            )
            base = with_marketplace(decode(result.stdout), marketplace)
            # Do not guess a prior declaration after the state file is lost.
            if not same(decode(tracked.read_bytes()), base):
                raise ValueError("cannot establish the previous declared settings")
        merged = reconcile(base, local, desired)
        if merged["extraKnownMarketplaces"]["gigun"]["source"]["path"] != marketplace:
            raise ValueError("local marketplace path differs from declared path")
        content = original if same(merged, local) else encode(merged)
        if identity(settings) != before or stat.S_IMODE(settings.stat().st_mode) != mode or settings.read_bytes() != original:
            raise ValueError("settings changed during reconciliation")
    else:
        content = encode(desired)

    def verify_settings():
        if exists:
            if identity(settings) != before or stat.S_IMODE(settings.stat().st_mode) != mode or settings.read_bytes() != original:
                raise ValueError("settings changed during reconciliation")
        elif settings.exists() or settings.is_symlink():
            raise ValueError("settings appeared during initialization")

    # Write settings before recording the base: an interrupted retry stays conservative.
    # Recheck after staging as well; rename is not a compare-and-swap operation.
    verify_settings()
    if not exists or settings.is_symlink() or content != original:
        atomic_write(settings, content, mode if exists else 0o600, verify=verify_settings)
    atomic_write(state, encode(desired))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"Claude settings: {error}", file=sys.stderr)
        sys.exit(1)
