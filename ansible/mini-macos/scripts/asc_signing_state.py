#!/usr/bin/env python3
"""Read only bounded cleanup metadata; never read keys, passwords, or keychain contents."""
import json
import os
from pathlib import Path
import pwd
import shlex
import stat
import subprocess

OLD = Path('/tmp/asc-signing-run.1058188874')


def same_path(a, b):
    # security list-keychains は /tmp や /var を /private/tmp・/private/var の実体名で返す。
    # macOS では resolve() が /tmp -> /private/tmp を辿って一致するが、その symlink が無い
    # 環境 (CI の Linux) では一致しないので、比べる前に /private を外して揃える。
    def norm(p):
        s = str(Path(p).resolve())
        return s[len('/private'):] if s.startswith('/private/') else s
    return norm(a) == norm(b)


def private_json(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077 or info.st_size > 65536:
            raise ValueError('private bounded metadata required')
        raw = source.read(65537)
    if len(raw) > 65536:
        raise ValueError('metadata too large')
    return json.loads(raw)


def exists(path):
    try:
        path.lstat()
        return True
    except FileNotFoundError:
        return False


def main():
    account = pwd.getpwuid(os.geteuid())
    if account.pw_name != 'asc-sign' or account.pw_uid == 0:
        raise ValueError('asc-sign context required')
    home = Path(account.pw_dir)
    journal = private_json(home / 'Library/Caches/asc/signing-run/v1/journal.json')
    receipt = private_json(Path('/Library/Application Support/asc-executor/jobs/sign/mini-route-test-1/export.json.signing.json'))
    result = {'readOnly': True, 'oldTemporaryDirectoryExists': exists(OLD),
              'oldTemporaryKeychainExists': exists(OLD / 'signing.keychain-db'),
              'journalPresent': journal is not None, 'receiptPresent': receipt is not None}
    if journal is not None:
        if not isinstance(journal, dict):
            raise ValueError('invalid journal')
        result.update({'journalSchemaMatches': journal.get('schemaVersion') == 1,
                       'journalReferencesOldTemporaryDirectory': journal.get('tempDir') == str(OLD),
                       'journalReferencesOldKeychain': journal.get('keychainPath') == str(OLD / 'signing.keychain-db'),
                       'journalProfileCreated': journal.get('profileCreated') is True,
                       'journalProfilePathPresent': bool(journal.get('profilePath')),
                       'journalStagedProfilePathPresent': bool(journal.get('stagedProfilePath'))})
    if receipt is not None:
        if not isinstance(receipt, dict):
            raise ValueError('invalid receipt')
        allowed = {'success', 'completed', 'child-failed', 'setup-failed', 'cleanup-failed', 'interrupted',
                   'not-installed', 'not-created', 'removed', 'deleted', 'failed', 'pending', 'reused'}
        result['receiptStates'] = {k: receipt.get(k) if isinstance(receipt.get(k), str) and receipt.get(k) in allowed else 'unrecognized'
                                  for k in ['outcome', 'profileCleanupState', 'keychainCleanupState']}
    run = subprocess.run(['/usr/bin/security', 'list-keychains', '-d', 'user'],
                         env={'HOME': account.pw_dir, 'PATH': '/usr/bin:/bin'}, stdin=subprocess.DEVNULL,
                         start_new_session=True, capture_output=True, timeout=15)
    result['searchListExit'] = run.returncode
    if run.returncode == 0:
        entries = shlex.split(run.stdout.decode())
        result['oldKeychainInSearchList'] = any(same_path(entry, OLD / 'signing.keychain-db') for entry in entries)
    print(json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError):
        raise SystemExit('signing cleanup metadata inventory did not complete')
