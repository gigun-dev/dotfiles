#!/usr/bin/env python3
"""Install a hash-approved complete toolchain tree without replacing old versions.

Requires the adjacent, reviewed asc_executor_install.py for shared root/ACL
validation. Default is plan. No binary is executed by this installer.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat

spec = importlib.util.spec_from_file_location('executor_guard', Path(__file__).with_name('asc_executor_install.py'))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
BASE = Path('/Library/PrivilegedHelperTools/asc-toolchain/versions')


def read_blob(path, limit=128 * 1024 * 1024):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise ValueError('bounded regular toolchain input required')
        value = source.read(limit + 1)
    if len(value) > limit:
        raise ValueError('toolchain input too large')
    return value


def candidate(bundle, expected):
    if not re.fullmatch('[a-f0-9]{64}', expected):
        raise ValueError('exact manifest digest required')
    info = bundle.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o022:
        raise ValueError('owner-controlled candidate directory required')
    raw = read_blob(bundle / 'manifest.json', 1024 * 1024)
    if hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError('manifest digest mismatch')
    manifest = json.loads(raw)
    version = manifest['version']
    if manifest['schemaVersion'] != 1 or not re.fullmatch('[A-Za-z0-9.-]+', version):
        raise ValueError('invalid toolchain version')
    entries = manifest['files']
    if not isinstance(entries, list) or not 3 <= len(entries) <= 128:
        raise ValueError('invalid toolchain file count')
    blobs = {}
    total = 0
    for entry in entries:
        name = entry['path']; relative = Path(name)
        if (relative.is_absolute() or '..' in relative.parts or str(relative) != name
                or name in blobs):
            raise ValueError('invalid or duplicate toolchain path')
        binary = name in ('bin/asc', 'bin/xcodegen')
        preset = name.startswith('share/xcodegen/SettingPresets/') and name.endswith('.yml')
        mode = 0o555 if binary else 0o444
        if not (binary or preset) or entry['mode'] != format(mode, '04o'):
            raise ValueError('unexpected toolchain content/mode')
        for parent in relative.parents:
            info = (bundle / parent).lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o022:
                raise ValueError('candidate ancestor is not a controlled directory')
        data = read_blob(bundle / relative)
        total += len(data)
        if total > 256 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != entry['sha256']:
            raise ValueError('toolchain content digest mismatch')
        blobs[name] = (data, mode)
    if not {'bin/asc', 'bin/xcodegen', 'share/xcodegen/SettingPresets/base.yml'} <= blobs.keys():
        raise ValueError('toolchain package is incomplete')
    return version, blobs


def execute(bundle, digest, apply=False):
    version, blobs = candidate(bundle, digest)
    target = BASE / version
    if target.exists() or target.is_symlink():
        raise FileExistsError('new toolchain version required')
    guard.protected_ancestors(target, include_self=False)
    result = {'operation': 'apply' if apply else 'plan', 'target': str(target),
              'fileCount': len(blobs), 'existingTargetsChanged': False,
              'runnerChanged': False}
    if not apply:
        return result
    if os.geteuid() != 0:
        raise ValueError('administrator execution required')
    # The operator must also hash-review the adjacent shared guard before import.
    for path in (Path(__file__).absolute(), Path(guard.__file__).absolute()):
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError('reviewed root-owned installer and guard required')
        guard.protected_ancestors(path.parent)
    files, directories = [], []
    def mkdir(path):
        if path.exists():
            return
        mkdir(path.parent)
        path.mkdir(mode=0o755)
        directories.append(path)
        path.chmod(0o755)
        os.chown(path, 0, 0)
    try:
        mkdir(target)
        for name, (data, mode) in blobs.items():
            path = target / name
            mkdir(path.parent)
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
            files.append(path)
            with os.fdopen(fd, 'wb') as output:
                os.fchmod(output.fileno(), mode)
                os.fchown(output.fileno(), 0, 0)
                output.write(data)
    except BaseException:
        for path in reversed(files):
            path.unlink()
        for path in reversed(directories):
            path.rmdir()
        raise
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bundle', type=Path, required=True)
    p.add_argument('--manifest-sha256', required=True)
    p.add_argument('--apply', action='store_true')
    a = p.parse_args()
    print(json.dumps(execute(a.bundle, a.manifest_sha256, a.apply)))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError):
        raise SystemExit('complete toolchain installation failed; existing versions not replaced')
