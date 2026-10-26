#!/usr/bin/env python3
"""fzf-only lock, artifact validation and read-only upstream detection."""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent

def sha(data):
    return hashlib.sha256(data).hexdigest()

def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()

def read(path):
    return json.loads(pathlib.Path(path).read_text())

def validate(lock):
    assert lock['schema'] == 1 and lock['name'] == 'fzf'
    assert lock['target'] == {'os':'macos','major':15,'arch':'x86_64','prefix':'/usr/local'}
    assert lock['dependencies'] == {'build':['go'],'runtime':[],'macos':['ncurses']}, 'dependency expansion needs review'
    assert re.fullmatch(r'[0-9a-f]{40}', lock['core_revision'])
    for obj in [lock, lock['go']]:
        assert re.fullmatch(r'\d+\.\d+\.\d+', obj['version'])
        assert isinstance(obj['revision'], int) and obj['revision'] >= 0
        for field in ['formula_sha256','build_sha256','source_sha256']:
            assert re.fullmatch(r'[0-9a-f]{64}', obj[field])
    assert lock['parallelism'] == 2
    return lock

def go_matches(version, cellar_version, receipt, lock):
    expected = lock['go']['version'] + ('_'+str(lock['go']['revision']) if lock['go']['revision'] else '')
    source = receipt.get('source', {})
    return (version == 'go'+lock['go']['version'] and cellar_version == expected
            and source.get('tap') == 'homebrew/core'
            and source.get('tap_git_head') == lock['core_revision']
            and source.get('spec') == 'stable')

def build_hash(text):
    # Bottle publication metadata does not change this fzf source recipe.
    return sha(re.sub(r'^  bottle do\n.*?^  end\n', '', text, flags=re.M|re.S).encode())

def inputs(lock):
    relevant = {k:v for k,v in lock.items() if k not in ['core_revision','formula_sha256']}
    relevant['go'] = {k:v for k,v in lock['go'].items() if k != 'formula_sha256'}
    return relevant

def key(lock, environment, recipe):
    validate(lock)
    # SDK/clang/Brew versions are provenance, not requirements on a consumer host.
    abi = {k:environment[k] for k in ['os','arch','macos_major','prefix']}
    assert abi == {'os':'Darwin','arch':'x86_64','macos_major':'15','prefix':'/usr/local'}
    return sha(encoded({'lock': inputs(lock), 'abi': abi, 'recipe': sha(recipe)}))

def verify(directory, expected):
    directory = pathlib.Path(directory)
    assert not (directory/'validated.json').is_symlink()
    manifest = read(directory/'validated.json')
    assert manifest['schema'] == 1 and manifest['key'] == expected
    assert manifest['status'] == 'validated'
    assert manifest['checks'] == ['formula-test','x86_64','unlinked','no-nix-linkage','go-unchanged']
    assert len(manifest['files']) == 1
    assert {p.name for p in directory.glob('*.bottle.tar.gz')} == set(manifest['files'])
    for name, digest in manifest['files'].items():
        assert re.fullmatch(r'fzf--[0-9.]+(?:_\d+)?\.sequoia\.bottle\.tar\.gz', name)
        p = directory/name
        assert p.is_file() and not p.is_symlink()
        assert sha(p.read_bytes()) == digest, 'bottle checksum mismatch'
    return manifest

def verify_build(directory):
    directory = pathlib.Path(directory)
    checksum = directory/'SHA256SUMS'
    assert not checksum.is_symlink()
    lines = checksum.read_text().splitlines()
    assert len(lines) == 1
    match = re.fullmatch(r'([0-9a-f]{64})  (?:\./)?(fzf--[0-9.]+(?:_\d+)?\.sequoia\.bottle\.tar\.gz)', lines[0])
    assert match, 'unexpected checksum entry'
    bottle = directory/match[2]
    assert bottle.is_file() and not bottle.is_symlink()
    assert sha(bottle.read_bytes()) == match[1]
    assert len(list(directory.glob('*.bottle.tar.gz'))) == 1
    return bottle

def candidate(lock, revision, fzf, go):
    result = json.loads(json.dumps(lock))
    result['core_revision'] = revision
    for name, text, obj, pattern in [
        ('fzf', fzf, result, r'url "https://github.com/junegunn/fzf/archive/refs/tags/v([0-9.]+)\.tar\.gz"'),
        ('go', go, result['go'], r'url "https://go.dev/dl/go([0-9.]+)\.src\.tar\.gz"')]:
        obj['version'] = re.search(pattern, text)[1]
        obj['revision'] = int(re.search(r'^  revision (\d+)$', text, re.M)[1]) if re.search(r'^  revision ', text, re.M) else 0
        obj['formula_sha256'] = sha(text.encode())
        obj['build_sha256'] = build_hash(text)
        obj['source_sha256'] = re.search(r'^  sha256 "([0-9a-f]{64})"', text, re.M)[1]
    # Do not silently generalize this trial to a new recursive build graph.
    assert re.findall(r'^  depends_on (.+)$', fzf, re.M) == ['"go" => :build']
    assert re.findall(r'^  uses_from_macos (.+)$', fzf, re.M) == ['"ncurses"']
    assert re.findall(r'^\s*depends_on (.+)$', go, re.M) == ['macos: :monterey']
    return validate(result)

def main():
    p = argparse.ArgumentParser()
    p.add_argument('command', choices=['key','verify','detect','archive-plan'])
    p.add_argument('--lock', default=str(ROOT/'fzf.lock.json'))
    p.add_argument('--environment')
    p.add_argument('--directory')
    p.add_argument('--output')
    a = p.parse_args()
    lock = validate(read(a.lock))
    if a.command == 'detect':
        revision = subprocess.check_output(['gh','api','repos/Homebrew/homebrew-core/commits/HEAD','--jq','.sha'], text=True).strip()
        assert re.fullmatch(r'[0-9a-f]{40}', revision)
        def fetch(path):
            url = f'https://raw.githubusercontent.com/Homebrew/homebrew-core/{revision}/{path}'
            with urllib.request.urlopen(url, timeout=30) as r:
                return r.read().decode()
        proposed = candidate(lock, revision, fetch('Formula/f/fzf.rb'), fetch('Formula/g/go.rb'))
        changed = inputs(proposed) != inputs(lock)
        if changed:
            assert a.output, '--output required for changed candidate'
            pathlib.Path(a.output).write_text(json.dumps(proposed,indent=2)+'\n')
        print(json.dumps({'changed':changed,'source_key':sha(encoded(inputs(proposed)))}))
        return
    environment = read(a.environment)
    identity = key(lock, environment, (ROOT/'recipe.sh').read_bytes())
    if a.command == 'key':
        print(identity)
        return
    manifest = verify(a.directory, identity)
    if a.command == 'verify':
        print(identity)
    else:
        # This command never publishes. Destination and write authority remain unapproved.
        print(json.dumps({'enabled':False,'recommended_storage':'private GitHub Release in existing repository',
            'tag':'fzf-bottle-'+identity,'assets':['validated.json',*manifest['files']],
            'overwrite':False,'destination':read(ROOT/'policy.json')['durable_destination']},indent=2))

if __name__ == '__main__':
    main()
