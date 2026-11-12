#!/usr/bin/env python3
"""Validate a hash-authorized executor candidate; install only with --apply.

No code is executed, no users or sudo rules are changed. Existing targets are
never adopted or overwritten. Run a reviewed root-owned copy for application.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess

FILES = ('build_archive.py', 'run.py', 'archive_digest.py', 'ad_hoc.py')
VERSION_BASE = Path('/Library/PrivilegedHelperTools/asc-executor/versions')
JOB_BASE = Path('/Library/Application Support/asc-executor/jobs')


def read_regular(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 1024 * 1024:
            raise ValueError('candidate must contain bounded regular files')
        data = b''
        while len(data) <= 1024 * 1024:
            chunk = os.read(fd, min(65536, 1024 * 1024 + 1 - len(data)))
            if not chunk:
                break
            data += chunk
        if len(data) > 1024 * 1024:
            raise ValueError('candidate too large')
        return data
    finally:
        os.close(fd)


def candidate(bundle, expected):
    if not re.fullmatch('[a-f0-9]{64}', expected):
        raise ValueError('an exact manifest SHA-256 is required')
    info = bundle.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o022:
        raise ValueError('candidate directory must not be a link or writable by others')
    raw = read_regular(bundle / 'manifest.json')
    if hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError('manifest hash mismatch')
    manifest = json.loads(raw)
    revision = manifest['sourceRevision']
    if manifest['schemaVersion'] != 1 or not re.fullmatch('[a-f0-9]{40}', revision):
        raise ValueError('invalid manifest')
    if manifest['plannedVersionDirectory'] != str(VERSION_BASE / revision):
        raise ValueError('unexpected installation destination')
    entries = manifest['files']
    if len(entries) != len(FILES) or {entry['name'] for entry in entries} != set(FILES):
        raise ValueError('unexpected executor files')
    blobs = {}
    for entry in entries:
        if entry['plannedOwner'] != 'root' or entry['plannedMode'] != '0444':
            raise ValueError('unexpected executor ownership')
        data = read_regular(bundle / entry['name'])
        if hashlib.sha256(data).hexdigest() != entry['sha256']:
            raise ValueError('executor hash mismatch')
        blobs[entry['name']] = data
    return revision, blobs


def protected_ancestors(path, include_self=True):
    """Reject symlinks, writeable ancestors and all explicit macOS ACLs."""
    paths = [path] + list(path.parents) if include_self else list(path.parents)
    for item in reversed(paths):
        try:
            info = item.lstat()
        except FileNotFoundError:
            continue
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError('installation ancestors must be protected root directories')
        result = subprocess.run(['/bin/ls', '-lde', str(item)], capture_output=True,
                                text=True, check=True)
        if len(result.stdout.splitlines()) != 1:
            raise ValueError('explicit ACLs require separate review')


def targets(revision, build_user, sign_user):
    build, sign = pwd.getpwnam(build_user), pwd.getpwnam(sign_user)
    if min(build.pw_uid, sign.pw_uid) < 500 or build.pw_uid == sign.pw_uid:
        raise ValueError('distinct existing non-system executor users required')
    paths = [VERSION_BASE / revision, JOB_BASE / 'build', JOB_BASE / 'sign']
    for path in paths:
        if path.exists() or path.is_symlink():
            raise FileExistsError('installation targets must all be new')
        protected_ancestors(path, include_self=False)
    return paths, build, sign


def execute(args):
    revision, blobs = candidate(args.bundle, args.manifest_sha256)
    paths, build, sign = targets(revision, args.build_user, args.sign_user)
    report = {'operation': 'apply' if args.apply else 'plan', 'sourceRevision': revision,
              'newTargets': list(map(str, paths)), 'existingTargetsChanged': False,
              'toolchainInstalled': False, 'runnerChanged': False}
    if not args.apply:
        return report
    if os.geteuid() != 0:
        raise ValueError('apply requires administrator execution')
    script = Path(__file__).absolute()
    info = script.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise ValueError('installer must be a reviewed root-owned regular file')
    protected_ancestors(script.parent)
    created_files, created_dirs = [], []
    def mkdirs(path):
        if path.exists():
            return
        mkdirs(path.parent)
        path.mkdir(mode=0o755)
        created_dirs.append(path)
        path.chmod(0o755)
        os.chown(path, 0, 0)
    try:
        for path in paths:
            mkdirs(path.parent)
            path.mkdir(mode=0o755)
            created_dirs.append(path)
            path.chmod(0o755)
            os.chown(path, 0, 0)
        for name, data in blobs.items():
            path = paths[0] / name
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o444)
            created_files.append(path)
            with os.fdopen(fd, 'wb') as stream:
                os.fchmod(stream.fileno(), 0o444)
                os.fchown(stream.fileno(), 0, 0)
                stream.write(data)
        for path, account in zip(paths[1:], (build, sign)):
            path.chmod(0o700)
            os.chown(path, account.pw_uid, account.pw_gid)
    except BaseException:
        # These paths were created here; never recursively delete caller input.
        for path in reversed(created_files):
            path.unlink()
        for path in reversed(created_dirs):
            path.rmdir()
        raise
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--build-user', required=True)
    parser.add_argument('--sign-user', required=True)
    parser.add_argument('--apply', action='store_true')
    print(json.dumps(execute(parser.parse_args())))


if __name__ == '__main__':
    main()
