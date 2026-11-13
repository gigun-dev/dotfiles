#!/usr/bin/env python3
"""Exercise SOPS + age-plugin-se with fixed non-secret bytes, never real signing inputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import signal
import stat
import subprocess
import time

CANARY = b'ASC Secure Enclave NONSECRET canary v1\n'
NAMES = ('age-plugin-se', 'age', 'age-keygen', 'sops')


def account(expected):
    owner = pwd.getpwuid(os.geteuid())
    if owner.pw_uid == 0 or owner.pw_name != expected:
        raise ValueError('intended non-root canary owner required')
    return owner


def private_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError('private regular canary artifact required')


def write(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as output:
        output.write(data)


def run(argv, env, data=None):
    options = {'stdin': subprocess.PIPE if data is not None else subprocess.DEVNULL}
    process = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True, umask=0o077, **options)
    try:
        stdout, stderr = process.communicate(data, timeout=90)
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
        except ProcessLookupError:
            pass
        raise
    if process.returncode or len(stdout) > 1024 * 1024 or len(stderr) > 1024 * 1024:
        raise ValueError('noninteractive canary tool failed')
    return stdout


def tools(directory):
    for name in NAMES:
        path = directory / name
        info = path.lstat()
        if (not path.is_absolute() or not stat.S_ISREG(info.st_mode)
                or info.st_uid != 0 or info.st_mode & 0o022 or not info.st_mode & 0o111):
            raise ValueError('protected approved canary toolchain required')
    return {name: str(directory / name) for name in NAMES}


def execute(output, expected_user, tool_directory, accessibility="when-unlocked"):
    if accessibility not in ("when-unlocked", "after-first-unlock"):
        raise ValueError("invalid canary accessibility class")
    owner = account(expected_user)
    output = Path(output)
    home = Path(owner.pw_dir).resolve()
    parent = output.parent
    info = parent.lstat()
    if (not output.is_absolute() or not parent.resolve().is_relative_to(home)
            or not stat.S_ISDIR(info.st_mode) or info.st_uid != owner.pw_uid or info.st_mode & 0o077):
        raise ValueError('canary output must have a private owner-home parent')
    commands = tools(Path(tool_directory))
    output.mkdir(mode=0o700)
    (output / 'config').mkdir(mode=0o700)
    env = {'HOME': owner.pw_dir, 'USER': owner.pw_name, 'LOGNAME': owner.pw_name,
           'PATH': str(tool_directory) + ':/usr/bin:/bin',
           'XDG_CONFIG_HOME': str(output / 'config'), 'SOPS_DISABLE_VERSION_CHECK': '1'}
    def step(name, argv, environment, data=None):
        try:
            return run(argv, environment, data)
        except (OSError, ValueError, subprocess.SubprocessError):
            print(json.dumps({'failedCanaryPhase': name}), flush=True)
            raise

    identity = output / 'se-identity.txt'
    recovery = output / 'recovery-identity.txt'
    keygen = [commands['age-plugin-se'], 'keygen', '--access-control', 'none', '-o', str(identity)]
    if accessibility != 'when-unlocked':
        keygen += ['--accessibility', accessibility]
    step('se-keygen', keygen, env)
    private_file(identity)
    recipient = step('se-recipient', [commands['age-plugin-se'], 'recipients', '-i', str(identity)], env).decode().strip()
    if not recipient.startswith('age1se1') or any(c.isspace() for c in recipient):
        raise ValueError('invalid SE canary recipient')
    step('recovery-keygen', [commands['age-keygen'], '-o', str(recovery)], env)
    private_file(recovery)
    recovery_recipient = step('recovery-recipient', [commands['age-keygen'], '-y', str(recovery)], env).decode().strip()
    if not recovery_recipient.startswith('age1') or any(c.isspace() for c in recovery_recipient):
        raise ValueError('invalid recovery canary recipient')
    write(output / 'sops.yaml', json.dumps({'creation_rules': [{'age': recipient + ',' + recovery_recipient}]}).encode())
    common = [commands['sops'], '--config', str(output / 'sops.yaml'), '--input-type', 'binary', '--output-type', 'binary']
    cipher = step('sops-encrypt', [*common, '--encrypt', '--age', recipient + ',' + recovery_recipient, '/dev/stdin'], env, CANARY)
    write(output / 'canary.sops', cipher)
    for key, name in [(identity, 'se'), (recovery, 'independent-recovery')]:
        decrypt_env = {**env, 'SOPS_AGE_KEY_FILE': str(key)}
        plain = step(name + '-decrypt', [*common, '--decrypt', str(output / 'canary.sops')], decrypt_env)
        if plain != CANARY:
            raise ValueError(name + ' canary roundtrip mismatch')
    result = {'canaryOnly': True, 'owner': owner.pw_name, 'touchIDPolicy': 'none',
              'headlessSERoundtripPassed': True, 'independentCanaryRecoveryPassed': True,
              'accessibilityClass': accessibility, 'ciphertextSHA256': hashlib.sha256(cipher).hexdigest(),
              'plaintextSHA256': hashlib.sha256(CANARY).hexdigest(),
              'realSigningMaterialUsed': False, 'lockRebootAssessed': False,
              'crossUIDAssessed': False, 'fixtureRetainedForRemainingGates': True}
    write(output / 'result.json', (json.dumps(result) + '\n').encode())
    return result


def read_private(path, limit=1024 * 1024):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or info.st_mode & 0o077 or info.st_size > limit):
            raise ValueError('bounded private canary metadata required')
        data = source.read(limit + 1)
    if len(data) > limit:
        raise ValueError('canary metadata too large')
    return data


def verify_existing(output, expected_user, tool_directory, label, delay=0):
    if label not in ('unlocked', 'locked', 'after-unlock', 'after-reboot') or type(delay) is not int or not 0 <= delay <= 60:
        raise ValueError('invalid observation label or delay')
    owner = account(expected_user)
    output = Path(output)
    info = output.lstat()
    if (not output.is_absolute() or not output.parent.resolve().is_relative_to(Path(owner.pw_dir).resolve())
            or not stat.S_ISDIR(info.st_mode) or info.st_uid != owner.pw_uid or info.st_mode & 0o077):
        raise ValueError('private owner-home canary directory required')
    previous = json.loads(read_private(output / 'result.json', 65536))
    if (not isinstance(previous, dict) or previous.get('canaryOnly') is not True or previous.get('realSigningMaterialUsed') is not False
            or previous.get('owner') != owner.pw_name
            or previous.get('plaintextSHA256') != hashlib.sha256(CANARY).hexdigest()
            or previous.get('accessibilityClass') not in ('when-unlocked', 'after-first-unlock')):
        raise ValueError('original nonsecret canary receipt required')
    ciphertext = read_private(output / 'canary.sops')
    if hashlib.sha256(ciphertext).hexdigest() != previous.get('ciphertextSHA256'):
        raise ValueError('original canary ciphertext differs')
    for name in ('se-identity.txt', 'sops.yaml'):
        private_file(output / name)
    result_path = output / ('probe-' + label + '.json')
    if result_path.exists() or result_path.is_symlink():
        raise FileExistsError('this observation already exists')
    commands = tools(Path(tool_directory))
    env = {'HOME': owner.pw_dir, 'USER': owner.pw_name, 'LOGNAME': owner.pw_name,
           'PATH': str(tool_directory) + ':/usr/bin:/bin', 'XDG_CONFIG_HOME': str(output / 'config'),
           'SOPS_DISABLE_VERSION_CHECK': '1', 'SOPS_AGE_KEY_FILE': str(output / 'se-identity.txt')}
    if delay:
        print(json.dumps({'canaryOnly': True, 'waitingSeconds': delay}), flush=True)
        time.sleep(delay)
    passed = False
    try:
        plain = run([commands['sops'], '--config', str(output / 'sops.yaml'), '--input-type', 'binary',
                     '--output-type', 'binary', '--decrypt', str(output / 'canary.sops')], env)
        passed = plain == CANARY
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    result = {'canaryOnly': True, 'observationLabel': label, 'stateObservedByOS': False,
              'accessibilityClass': previous['accessibilityClass'], 'seDecryptPassed': passed,
              'existingCiphertextMatched': True, 'newKeyGenerated': False, 'realSigningMaterialUsed': False,
              'plaintextSHA256': hashlib.sha256(CANARY).hexdigest() if passed else None}
    write(result_path, (json.dumps(result) + '\n').encode())
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--expected-user', required=True)
    p.add_argument('--tool-directory', type=Path, required=True)
    p.add_argument('--accessibility', choices=['when-unlocked', 'after-first-unlock'], default='when-unlocked')
    p.add_argument('--probe-label', choices=['unlocked', 'locked', 'after-unlock', 'after-reboot'])
    p.add_argument('--delay', type=int, default=0)
    a = p.parse_args()
    if a.delay and not a.probe_label:
        p.error('--delay requires --probe-label; preparation never waits for a lock')
    if a.probe_label and a.accessibility != 'when-unlocked':
        p.error('--accessibility is only used when preparing a new canary')
    result = (verify_existing(a.output, a.expected_user, a.tool_directory, a.probe_label, a.delay) if a.probe_label
              else execute(a.output, a.expected_user, a.tool_directory, a.accessibility))
    print(json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError):
        raise SystemExit('nonsecret SE canary did not complete; do not reuse its output directory')
