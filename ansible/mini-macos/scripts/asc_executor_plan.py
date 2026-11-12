#!/usr/bin/env python3
"""Create a local executor candidate from committed bytes; never install or run it."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

FILES = ('build_archive.py', 'run.py', 'archive_digest.py', 'ad_hoc.py')


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args])


def committed_blobs(repo, revision):
    if not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('an exact source commit is required')
    paths = ['scripts/' + name for name in FILES]
    if git(repo, 'status', '--porcelain', '--', *paths).strip():
        raise ValueError('executor source paths have uncommitted changes')
    if git(repo, 'rev-parse', revision + '^{commit}').decode().strip() != revision:
        raise ValueError('source commit mismatch')
    # Read every committed blob before reserving output. Missing new files at
    # an old revision must fail, never fall back to worktree bytes.
    blobs = {name: git(repo, 'show', revision + ':scripts/' + name) for name in FILES}
    if any(git(repo, 'ls-tree', revision, '--', 'scripts/' + name).split()[0] != b'100644'
           and git(repo, 'ls-tree', revision, '--', 'scripts/' + name).split()[0] != b'100755'
           for name in FILES):
        raise ValueError('executor source must be regular committed files')
    return blobs


def generate(repo, revision, output):
    blobs = committed_blobs(repo, revision)
    output.mkdir(mode=0o700)
    entries = []
    for name, data in blobs.items():
        path = output / name
        with path.open('xb') as stream:
            stream.write(data)
        path.chmod(0o600)
        entries.append({'name': name, 'sha256': hashlib.sha256(data).hexdigest(),
                        'plannedOwner': 'root', 'plannedMode': '0444'})
    manifest = {'schemaVersion': 1, 'sourceRevision': revision,
                'assessment': 'local_candidate_only; not_installed_or_executed',
                'plannedVersionDirectory': '/Library/PrivilegedHelperTools/asc-executor/versions/' + revision,
                'files': entries,
                'requiresBeforeApply': ['reviewed source commit and hashes',
                    'root-owned non-writable ancestor and ACL inspection',
                    'private build/sign job directories and existing user identities',
                    'separately approved protected toolchain', 'explicit application approval']}
    with (output / 'manifest.json').open('x') as stream:
        json.dump(manifest, stream, indent=2)
        stream.write('\n')
    (output / 'manifest.json').chmod(0o600)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if args.check:
        committed_blobs(args.source, args.revision)
        if args.output.exists() or args.output.is_symlink():
            raise FileExistsError('candidate output must be new')
    else:
        generate(args.source, args.revision, args.output)


if __name__ == '__main__':
    main()
