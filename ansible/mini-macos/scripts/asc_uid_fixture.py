#!/usr/bin/env python3
"""One-shot, non-secret UID permission fixture. No users or services are changed.

Run a reviewed root-owned copy on mini. This tests fixed canaries only; it does
not authorize an archive, execute build code, or prove runner/keychain isolation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import shutil
import stat
import subprocess
import tempfile


CANARY = b'asc uid fixture: public disposable bytes\n'
CREATE = 'from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(bytes.fromhex(sys.argv[2]))'
READ = 'from pathlib import Path; import hashlib,sys; print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())'
DENY = '''from pathlib import Path
import sys
try:
    with Path(sys.argv[1]).open(sys.argv[2]):
        pass
except PermissionError:
    raise SystemExit(0)
raise SystemExit(1)
'''


def as_user(account, home, code, *args):
    # No ambient secret environment or supplemental groups reaches the child.
    return subprocess.run(['/usr/bin/python3', '-I', '-c', code, *map(str, args)],
        user=account.pw_uid, group=account.pw_gid, extra_groups=[],
        env={'PATH': '/usr/bin:/bin', 'HOME': str(home)},
        cwd=str(home), capture_output=True, text=True, timeout=15, check=True)


def execute(build_user, sign_user):
    if os.geteuid() != 0:
        raise ValueError('run the reviewed fixture as root')
    build, sign = pwd.getpwnam(build_user), pwd.getpwnam(sign_user)
    if build.pw_uid < 500 or sign.pw_uid < 500 or build.pw_uid == sign.pw_uid:
        raise ValueError('two distinct non-system users are required')
    script = Path(__file__).absolute()
    for path, kind in [(script, stat.S_ISREG), (script.parent, stat.S_ISDIR)]:
        info = path.lstat()
        if not kind(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError('reviewed script and its directory must be root-owned and not writable by others')
    expected = hashlib.sha256(CANARY).hexdigest()
    # sudo can preserve a caller-private TMPDIR which neither child can traverse.
    with tempfile.TemporaryDirectory(prefix='asc-uid-fixture-', dir='/private/tmp') as temporary:
        root = Path(temporary)
        root.chmod(0o711)
        homes = []
        for label, account in [('build', build), ('sign', sign)]:
            home = root / label
            home.mkdir(mode=0o700)
            os.chown(home, account.pw_uid, account.pw_gid)
            homes.append(home)
        build_home, sign_home = homes
        original = build_home / 'canary'
        accepted = sign_home / 'accepted'
        as_user(build, build_home, CREATE, original, CANARY.hex())
        as_user(sign, sign_home, DENY, original, 'rb')
        # Root acts only as a fixture copier. Production handoff policy is not
        # implemented here. The signer still independently checks its copy.
        if original.read_bytes() != CANARY:
            raise ValueError('fixture source mismatch')
        shutil.copyfile(original, accepted)
        accepted.chmod(0o600)
        os.chown(accepted, sign.pw_uid, sign.pw_gid)
        result = as_user(sign, sign_home, READ, accepted)
        if result.stdout.strip() != expected:
            raise ValueError('fixture handoff digest mismatch')
        as_user(build, build_home, DENY, accepted, 'rb')
        as_user(build, build_home, DENY, accepted, 'wb')
    return {'status': 'passed', 'canaryOnly': True, 'crossUserReadWriteDenied': True,
            'handoffDigestMatched': True, 'temporaryFilesRemoved': not root.exists(),
            'productionBoundary': 'not_assessed'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-user', required=True)
    parser.add_argument('--sign-user', required=True)
    parser.add_argument('--run-fixture', action='store_true', required=True)
    args = parser.parse_args()
    print(json.dumps(execute(args.build_user, args.sign_user)))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError):
        raise SystemExit('UID fixture failed; no production boundary accepted')
