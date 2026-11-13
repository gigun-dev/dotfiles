#!/usr/bin/env python3
"""Initialize Xcode SDK/runtime metadata from a pinned public Apple index.

Run in the intended unprivileged account. No downloads, overrides, credentials,
SDK installation, or existing metadata replacement. Default is read-only plan.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import stat
import subprocess
import sys

LIMIT = 8 * 1024 * 1024
RELATIVE = Path('Library/Developer/Xcode/SDKToSimulatorIndexMapping.plist')


def select_mapping(data, digest, sdk, sdk_build, runtime_build):
    if (len(data) > LIMIT or not re.fullmatch(r'[a-f0-9]{64}', digest)
            or hashlib.sha256(data).hexdigest() != digest):
        raise ValueError('public index digest mismatch')
    if (not re.fullmatch(r'iphoneos\d+\.\d+(?:\.\d+)?', sdk)
            or any(not re.fullmatch(r'[0-9A-Za-z]+', v) for v in (sdk_build, runtime_build))):
        raise ValueError('invalid SDK/runtime identity')
    index = plistlib.loads(data)
    rows = index.get('sdkToSimulatorMappings') if isinstance(index, dict) else None
    if not isinstance(rows, list):
        raise ValueError('public index mapping list missing')
    expected = {'sdkIdentifier': sdk, 'sdkBuildUpdate': sdk_build,
                'simulatorBuildUpdate': runtime_build}
    # Only the exact official row is accepted; do not manufacture an override.
    if sum(row == expected for row in rows) != 1:
        raise ValueError('expected SDK/runtime mapping is absent or duplicated')
    return plistlib.dumps([expected], sort_keys=True)


def installed_pair(sdk, sdk_build, runtime_build):
    env = {'PATH': '/usr/bin:/bin', 'HOME': pwd.getpwuid(os.geteuid()).pw_dir,
           'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer'}
    def command(argv):
        r = subprocess.run(argv, env=env, capture_output=True, timeout=60, check=True)
        if len(r.stdout) > LIMIT:
            raise ValueError('tool output too large')
        return r.stdout
    version = command(['/usr/bin/xcrun', '--sdk', 'iphoneos', '--show-sdk-version']).decode().strip()
    build = command(['/usr/bin/xcrun', '--sdk', 'iphoneos', '--show-sdk-build-version']).decode().strip()
    if sdk != 'iphoneos' + version or build != sdk_build:
        raise ValueError('installed SDK differs from approved pair')
    runtimes = json.loads(command(['/usr/bin/xcrun', 'simctl', 'list', 'runtimes', '-j']))
    if not any(isinstance(r, dict) and r.get('identifier', '').startswith('com.apple.CoreSimulator.SimRuntime.iOS-')
               and r.get('buildversion') == runtime_build and r.get('isAvailable') is True
               for r in runtimes.get('runtimes', [])):
        raise ValueError('approved iOS runtime is not available')


def initialize(data, digest, sdk, sdk_build, runtime_build, expected_user, apply=False):
    account = pwd.getpwuid(os.geteuid())
    if account.pw_uid == 0 or account.pw_name != expected_user:
        raise ValueError('run as the intended non-root owner')
    output = select_mapping(data, digest, sdk, sdk_build, runtime_build)
    installed_pair(sdk, sdk_build, runtime_build)
    home = Path(account.pw_dir)
    target = home / RELATIVE
    current = home
    missing = []
    for part in [None, *RELATIVE.parent.parts]:
        if part is not None:
            current = current / part
        try:
            info = current.lstat()
        except FileNotFoundError:
            missing.append(current)
            continue
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != account.pw_uid
                or info.st_mode & 0o022):
            raise ValueError('metadata ancestor is not an owner-controlled directory')
    try:
        fd = os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        fd = None
    if fd is not None:
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != account.pw_uid
                    or info.st_mode & 0o022 or stream.read(LIMIT + 1) != output):
                raise ValueError('existing metadata differs; replacement is not permitted')
        return {'status': 'already_initialized', 'changed': False}
    if not apply:
        return {'status': 'planned', 'changed': False, 'mappingCount': 1}
    created = []
    reserved = False
    try:
        for directory in missing:
            directory.mkdir(mode=0o700)
            created.append(directory)
        fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        reserved = True
        with os.fdopen(fd, 'wb') as stream:
            stream.write(output)
    except BaseException:
        if reserved:
            target.unlink()
        for directory in reversed(created):
            directory.rmdir()
        raise
    return {'status': 'initialized', 'changed': True, 'mappingCount': 1,
            'sourceSHA256': digest, 'SDKDownloaded': False, 'overrideCreated': False}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--index', required=True, help='Public Apple index file, or - for stdin')
    p.add_argument('--index-sha256', required=True)
    p.add_argument('--sdk', required=True)
    p.add_argument('--sdk-build', required=True)
    p.add_argument('--runtime-build', required=True)
    p.add_argument('--expected-user', required=True)
    p.add_argument('--apply', action='store_true')
    a = p.parse_args()
    if a.index == '-':
        data = sys.stdin.buffer.read(LIMIT + 1)
    else:
        fd = os.open(a.index, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError('public index must be a regular file')
            data = stream.read(LIMIT + 1)
    print(json.dumps(initialize(data, a.index_sha256, a.sdk, a.sdk_build,
                               a.runtime_build, a.expected_user, a.apply)))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError, plistlib.InvalidFileException):
        raise SystemExit('SDK mapping initialization failed; no existing metadata replaced')
