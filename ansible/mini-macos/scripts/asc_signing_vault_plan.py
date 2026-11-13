#!/usr/bin/env python3
"""Plan an owner-local signing vault without reading any signing secret bytes.

No apply mode, encryption, decryption, source deletion, or external operations.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import stat


def private_metadata(path, owner_uid, home):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts or not path.is_relative_to(home):
        raise ValueError('signing path must stay in owner home')
    for parent in [path.parent, *path.parent.parents]:
        if not parent.is_relative_to(home):
            break
        info = parent.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != owner_uid or info.st_mode & 0o077:
            raise ValueError('private signing ancestor required')
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != owner_uid or info.st_mode & 0o077 or info.st_nlink != 1:
        raise ValueError('private regular signing input required')
    # Metadata binding only. The planner never opens this path.
    return {'path': str(path), 'device': info.st_dev, 'inode': info.st_ino,
            'size': info.st_size, 'mtimeNS': info.st_mtime_ns, 'mode': info.st_mode & 0o777}


def recovery_metadata(path):
    if path is None:
        return [], ['recovery-recipient-metadata-missing']
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 16384:
            raise ValueError('bounded public recipient file required')
        raw = source.read(16385)
    if len(raw) > 16384:
        raise ValueError('recipient metadata too large')
    # Native age -R recipient-file syntax: one public recipient per line,
    # ignoring blank/comment lines. This is a snapshot, not a new secret registry.
    public = [line.strip() for line in raw.decode().splitlines()
              if line.strip() and not line.lstrip().startswith('#')]
    if len(public) != 2 or len(set(public)) != 2:
        raise ValueError('two distinct public recovery recipients required')
    for key in public:
        if (not key.startswith('age1yubikey1') or not 20 <= len(key) <= 256
                or any(c.isspace() for c in key)):
            raise ValueError('public YubiKey recipients required; identity files are not accepted')
    recipients = [{'role': role, 'recipient': key} for role, key in
                  zip(('recovery-a', 'recovery-b'), public)]
    # File syntax cannot prove physical key possession or successful recovery.
    return recipients, ['independent-recovery-canaries-not-accepted']


def plan(home, owner_uid, expected_user, identity_directory, key, vault, recipients=None, reboot_accepted=False):
    home, identity_directory, vault = map(Path, (home, identity_directory, vault))
    bindings = [private_metadata(identity_directory / name, owner_uid, home)
                for name in ('distribution.p12', 'identity-password')]
    bindings.append(private_metadata(Path(key), owner_uid, home))
    if not vault.is_absolute() or '..' in vault.parts or not vault.is_relative_to(home) or vault.exists() or vault.is_symlink():
        raise ValueError('new owner-home vault directory required')
    parent = vault.parent.lstat()
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != owner_uid or parent.st_mode & 0o077:
        raise ValueError('private vault parent required')
    recovery, blockers = recovery_metadata(recipients)
    if not reboot_accepted:
        blockers.append('post-reboot-first-unlock-behavior-not-accepted')
    blockers.append('real-material-application-not-authorized')
    result = {'schemaVersion': 1, 'operation': 'plan-only', 'owner': expected_user, 'ownerUID': owner_uid,
              'sourceMetadataBindings': bindings, 'recoveryRecipients': recovery,
              'accessibilityClass': 'after-first-unlock', 'vaultDirectory': str(vault),
              'effectsForFutureReview': [
                  'create a new owner-private SE identity; keep it on mini',
                  'encrypt owner-local identity and password; never copy plaintext to another UID/host',
                  'verify owner-local roundtrip and local signing/IPA before retirement',
                  'retire known plaintext key/P12/password only in a separately reviewed operation'],
              'blockers': blockers, 'readyForApply': False, 'secretBytesRead': False,
              'sourceFilesChanged': False, 'externalEffects': False}
    encoded = json.dumps(result, sort_keys=True, separators=(',', ':')).encode()
    result['planSHA256'] = hashlib.sha256(encoded).hexdigest()
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--expected-user', required=True)
    p.add_argument('--identity-directory', type=Path, required=True)
    p.add_argument('--private-key', type=Path, required=True)
    p.add_argument('--vault-directory', type=Path, required=True)
    p.add_argument('--recovery-recipients-file', type=Path, help='Public native age -R file; two distinct recovery recipients, no identities')
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    owner = pwd.getpwuid(os.geteuid())
    if owner.pw_uid == 0 or owner.pw_name != a.expected_user:
        raise ValueError('intended non-root owner required')
    result = plan(Path(owner.pw_dir), owner.pw_uid, owner.pw_name, a.identity_directory,
                  a.private_key, a.vault_directory, a.recovery_recipients_file)
    parent = a.output.parent.lstat()
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != owner.pw_uid or parent.st_mode & 0o077:
        raise ValueError('private plan output parent required')
    fd = os.open(a.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as output:
        json.dump(result, output, indent=2)
    print(json.dumps({key: result[key] for key in ['operation', 'owner', 'blockers', 'readyForApply', 'secretBytesRead', 'sourceFilesChanged', 'externalEffects', 'planSHA256']}))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError):
        raise SystemExit('metadata-only signing vault plan did not complete')
