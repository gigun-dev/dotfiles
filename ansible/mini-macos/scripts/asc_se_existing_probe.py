#!/usr/bin/env python3
"""Verify only the existing fixed GUI canary; never generate or migrate keys."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import time

TOOLCHAIN = Path('/Library/PrivilegedHelperTools/asc-se-canary/versions/se-0.1.4-age-1.3.2-sops-3.13.3-a')
CORE_SHA256 = '8f7a8e8e85b60fcc216c0c4eecc8a59c780c2a100dfb34fbf4957f4293ab7e2e'
CIPHER_SHA256 = '70778f740a0cd96f52a6fc015ba61b93d5778536c4625ecc4c06f90d808bdf61'
FIXTURE = Path('/Users/gigun/asc-se-gui-canary-1jwj6xem/result')
LABELS = ('unlocked', 'locked', 'after-unlock', 'after-reboot')


def execute(label, delay):
    if label not in LABELS or type(delay) is not int or not 0 <= delay <= 60:
        raise ValueError('invalid canary observation label or delay')
    core = TOOLCHAIN / 'asc_se_canary.py'
    if hashlib.sha256(core.read_bytes()).hexdigest() != CORE_SHA256:
        raise ValueError('protected canary core differs')
    ns = runpy.run_path(str(core))
    owner = ns['account']('gigun')
    for name in ('canary.sops', 'se-identity.txt', 'sops.yaml', 'result.json'):
        ns['private_file'](FIXTURE / name)
    fd = os.open(FIXTURE / 'canary.sops', os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as source:
        data = source.read(1024 * 1024 + 1)
    if hashlib.sha256(data).hexdigest() != CIPHER_SHA256:
        raise ValueError('existing nonsecret canary ciphertext differs')
    result_path = FIXTURE / ('probe-' + label + '.json')
    if result_path.exists() or result_path.is_symlink():
        raise FileExistsError('this canary observation already exists')
    commands = ns['tools'](TOOLCHAIN / 'bin')
    env = {'HOME': owner.pw_dir, 'USER': owner.pw_name, 'LOGNAME': owner.pw_name,
           'PATH': str(TOOLCHAIN / 'bin') + ':/usr/bin:/bin',
           'XDG_CONFIG_HOME': str(FIXTURE / 'config'), 'SOPS_DISABLE_VERSION_CHECK': '1',
           'SOPS_AGE_KEY_FILE': str(FIXTURE / 'se-identity.txt')}
    if delay:
        print(json.dumps({'canaryOnly': True, 'waitingSeconds': delay}), flush=True)
        time.sleep(delay)
    passed = False
    try:
        plain = ns['run']([commands['sops'], '--config', str(FIXTURE / 'sops.yaml'),
            '--input-type', 'binary', '--output-type', 'binary', '--decrypt',
            str(FIXTURE / 'canary.sops')], env)
        passed = plain == ns['CANARY']
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    result = {'canaryOnly': True, 'observationLabel': label, 'stateObservedByOS': False,
              'seDecryptPassed': passed, 'existingCiphertextMatched': True,
              'newKeyGenerated': False, 'realSigningMaterialUsed': False,
              'plaintextSHA256': hashlib.sha256(ns['CANARY']).hexdigest() if passed else None}
    ns['write'](result_path, (json.dumps(result) + '\n').encode())
    return result


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--label', choices=LABELS, required=True)
    p.add_argument('--delay', type=int, default=0)
    a = p.parse_args()
    try:
        print(json.dumps(execute(a.label, a.delay)))
    except (OSError, ValueError, subprocess.SubprocessError):
        raise SystemExit('existing nonsecret canary probe did not complete; no keys regenerated')
