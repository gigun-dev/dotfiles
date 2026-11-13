#!/usr/bin/env python3
"""Create an owner-local SOPS signing vault; never decrypt or delete signing inputs.

The command requires an explicit --apply-encryption. Original inputs remain in
place until separately reviewed recovery, signing and retirement operations.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess

import asc_se_canary as se
import asc_signing_vault_plan as planner


def encrypt_fd(command, env, source_fd):
    """Pass an already checked descriptor directly to SOPS; capture ciphertext only."""
    process = subprocess.Popen(command, stdin=source_fd, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, env=env,
                               start_new_session=True, umask=0o077)
    try:
        ciphertext, _ = process.communicate(timeout=120)
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
    if process.returncode or not ciphertext or len(ciphertext) > 4 * 1024 * 1024:
        raise ValueError('signing input encryption did not complete')
    return ciphertext


def open_bound(binding):
    fd = os.open(binding['path'], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    info = os.fstat(fd)
    actual = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_mode & 0o777)
    expected = tuple(binding[k] for k in ('device', 'inode', 'size', 'mtimeNS', 'mode'))
    if actual != expected or info.st_uid != os.geteuid() or info.st_nlink != 1:
        os.close(fd)
        raise ValueError('signing input metadata changed')
    if not 0 < info.st_size <= 1024 * 1024:
        os.close(fd)
        raise ValueError('bounded nonempty signing input required')
    return fd


def execute(output, expected_user, tool_directory, identity_directory, private_key, recipients_file):
    owner = se.account(expected_user)
    home = Path(owner.pw_dir)
    output = Path(output)
    plan = planner.plan(home, owner.pw_uid, owner.pw_name, identity_directory,
                        private_key, output, recipients_file)
    commands = se.tools(Path(tool_directory))
    # Open and pin all sources before creating a vault. No source bytes enter Python.
    descriptors = []
    try:
        for binding in plan['sourceMetadataBindings']:
            descriptors.append(open_bound(binding))
        output.mkdir(mode=0o700)
        (output / 'config').mkdir(mode=0o700)
        env = {'HOME': owner.pw_dir, 'USER': owner.pw_name, 'LOGNAME': owner.pw_name,
               'PATH': str(tool_directory) + ':/usr/bin:/bin',
               'XDG_CONFIG_HOME': str(output / 'config'), 'SOPS_DISABLE_VERSION_CHECK': '1'}
        identity = output / 'se-identity.txt'
        se.run([commands['age-plugin-se'], 'keygen', '--access-control', 'none',
                '--accessibility', 'after-first-unlock', '-o', str(identity)], env)
        se.private_file(identity)
        recipient = se.run([commands['age-plugin-se'], 'recipients', '-i', str(identity)], env).decode().strip()
        if not recipient.startswith('age1se1') or any(c.isspace() for c in recipient):
            raise ValueError('invalid SE recipient')
        public = [recipient, *(x['recipient'] for x in plan['recoveryRecipients'])]
        recipients = ','.join(public)
        config = output / 'sops.yaml'
        se.write(config, json.dumps({'creation_rules': [{'age': recipients}]}).encode())
        common = [commands['sops'], '--config', str(config), '--input-type', 'binary', '--output-type', 'binary']
        encrypt = [*common, '--encrypt', '--age', recipients, '/dev/stdin']
        # The only decryption performed is of fixed public canary bytes.
        canary = se.run(encrypt, env, se.CANARY)
        se.write(output / 'canary.sops', canary)
        if se.run([*common, '--decrypt', str(output / 'canary.sops')],
                  {**env, 'SOPS_AGE_KEY_FILE': str(identity)}) != se.CANARY:
            raise ValueError('new SE canary roundtrip did not match')
        receipts = []
        for binding, fd, name in zip(plan['sourceMetadataBindings'], descriptors,
                                     ('distribution.p12.sops', 'identity-password.sops', 'distribution.key.sops')):
            cipher = encrypt_fd(encrypt, env, fd)
            # Recheck the open inode before accepting its output.
            info = os.fstat(fd)
            if info.st_size != binding['size'] or info.st_mtime_ns != binding['mtimeNS']:
                raise ValueError('signing input changed during encryption')
            se.write(output / name, cipher)
            receipts.append({'file': name, 'ciphertextSHA256': hashlib.sha256(cipher).hexdigest()})
        result = {'operation': 'encrypt-only', 'owner': expected_user,
                  'accessibilityClass': 'after-first-unlock', 'recoveryRecipientCount': 2,
                  'newSECanaryPassed': True, 'sourceMetadataBindings': plan['sourceMetadataBindings'],
                  'encryptedArtifacts': receipts, 'realMaterialDecrypted': False,
                  'sourceFilesChanged': False, 'sourceFilesDeleted': False,
                  'realMaterialRecoveryAccepted': False, 'signingAccepted': False,
                  'postRebootAccepted': False, 'externalEffects': False}
        se.write(output / 'receipt.json', (json.dumps(result, indent=2) + '\n').encode())
        return {k: v for k, v in result.items() if k not in ('sourceMetadataBindings', 'encryptedArtifacts')}
    finally:
        for fd in descriptors:
            os.close(fd)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--expected-user', required=True)
    p.add_argument('--tool-directory', required=True, type=Path)
    p.add_argument('--identity-directory', required=True, type=Path)
    p.add_argument('--private-key', required=True, type=Path)
    p.add_argument('--recovery-recipients-file', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--apply-encryption', required=True, action='store_true')
    a = p.parse_args()
    print(json.dumps(execute(a.output, a.expected_user, a.tool_directory,
                             a.identity_directory, a.private_key, a.recovery_recipients_file)))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError):
        raise SystemExit('owner-local encryption did not complete; original inputs retained; do not rerun into the same output')
