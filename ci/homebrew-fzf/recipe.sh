#!/usr/bin/env bash
# Shared fzf recipe. Preflight is read-only; mutations always require --execute.
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
mode=${1:-preflight}; shift || true
lock="$root/fzf.lock.json"; work=''; artifact=''; execute=0; disposable=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --lock) lock=$2; shift 2 ;;
    --work) work=$2; shift 2 ;;
    --artifact) artifact=$2; shift 2 ;;
    --execute) execute=1; shift ;;
    --disposable-runner) disposable=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
read -r version revision core_rev formula_sha go_version go_sha < <(
  python3 - "$root" "$lock" <<'PY'
import sys
sys.path.insert(0,sys.argv[1]); import state
x=state.validate(state.read(sys.argv[2]))
print(x['version'],x['revision'],x['core_revision'],x['formula_sha256'],x['go']['version'],x['go']['formula_sha256'])
PY
)
# Nonpersistent normalization; never update Homebrew, remove packages or change user PATH.
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_AUTOREMOVE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
export HOMEBREW_NO_INSTALL_FROM_API=1 HOMEBREW_MAKE_JOBS=2 GOMAXPROCS=2 GOFLAGS=-p=2
preflight() {
  python3 - "$core_rev" "$go_version" "$root" "$lock" <<'PY'
import json,os,pathlib,platform,subprocess,sys

def run(*args):
    try: p=subprocess.run(args,capture_output=True,text=True)
    except FileNotFoundError: return ''
    return p.stdout.strip() if p.returncode==0 else ''
sys.path.insert(0,sys.argv[3]);import state
identity={'os':platform.system(),'arch':platform.machine()}
if identity != {'os':'Darwin','arch':'x86_64'}:
    print(json.dumps({'identity':identity,'checks':{'target':False}}));sys.exit(0)
identity.update(macos_major=run('sw_vers','-productVersion').split('.')[0],prefix=run('brew','--prefix'),
    sdk=run('xcrun','--sdk','macosx','--show-sdk-version'),clang=run('xcrun','clang','--version').split('\n')[0],
    brew=run('brew','--version').split('\n')[0])
core=run('brew','--repo','homebrew/core')
go_opt=pathlib.Path('/usr/local/opt/go')
try: receipt=json.loads((go_opt/'INSTALL_RECEIPT.json').read_text())
except (OSError,ValueError): receipt={}
go_ok=state.go_matches(run(str(go_opt/'bin/go'),'env','GOVERSION'),go_opt.resolve().name,receipt,state.read(sys.argv[4]))
checks={'target':identity['macos_major']=='15' and identity['prefix']=='/usr/local',
    'core_pinned':bool(core) and run('git','-C',core,'rev-parse','HEAD')==sys.argv[1],
    'core_clean':bool(core) and not run('git','-C',core,'status','--porcelain'),
    'fzf_absent':not run('brew','list','--versions','fzf'),
    'go_exact':go_ok}
print(json.dumps({'identity':identity,'checks':checks},sort_keys=True))
PY
}
require_target() {
  preflight | python3 -c 'import json,sys; assert json.load(sys.stdin)["checks"]["target"], "requires Intel macOS15 /usr/local"'
}
require_execute() { test "$execute" = 1 || { echo 'Explicit --execute required; no changes made.' >&2; exit 2; }; }
require_runner() {
  test "$disposable" = 1 && test "${GITHUB_ACTIONS:-}" = true && test "${RUNNER_ENVIRONMENT:-}" = github-hosted || {
    echo 'Only an explicitly selected disposable GitHub-hosted runner may prepare Homebrew automatically.' >&2; exit 2;
  }
}
case "$mode" in
preflight) preflight; exit ;;
prepare-ci)
  require_execute; require_runner; require_target
  brew tap --force homebrew/core
  core=$(brew --repo homebrew/core)
  git -C "$core" fetch --depth=1 origin "$core_rev"
  git -C "$core" stash push -m fzf-disposable-runner-formulas
  git -C "$core" checkout --detach "$core_rev"
  ;;
build|verify|reuse)
  test -n "$work" || { echo '--work required' >&2; exit 2; }
  require_target
  # Key binds declared build inputs and target ABI; actual compiler/SDK are recorded as provenance.
  environment=$(preflight)
  identity=$(printf '%s' "$environment" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["identity"],sort_keys=True))')
  key=$(python3 - "$root" "$lock" "$identity" <<'PY'
import sys,json
sys.path.insert(0,sys.argv[1]);import state
print(state.key(state.read(sys.argv[2]),json.loads(sys.argv[3]),(state.ROOT/'recipe.sh').read_bytes()))
PY
)
  cached="$work/store/$key"
  if [ "$mode" = reuse ] || { [ "$mode" = build ] && [ -e "$cached" ]; }; then
    python3 - "$root" "$cached" "$key" <<'PY'
import sys
sys.path.insert(0,sys.argv[1]);import state
state.verify(sys.argv[2],sys.argv[3]);print(sys.argv[2])
PY
    exit
  fi
  require_execute
  printf '%s' "$environment" | python3 -c 'import json,sys; c=json.load(sys.stdin)["checks"]; assert c["core_pinned"] and c["core_clean"] and c["fzf_absent"], "prepare a clean pinned builder explicitly; existing fzf is never replaced"'
  core=$(brew --repo homebrew/core)
  (cd "$core"; printf '%s  %s\n' "$formula_sha" Formula/f/fzf.rb "$go_sha" Formula/g/go.rb | shasum -a 256 -c -)
  mkdir -p "$work"
  printf '%s\n' "$identity" > "$work/environment.json"
  out="$work/build"
  if [ "$mode" = build ]; then
    test ! -e "$out" || { echo 'Build output exists; inspect it instead of overwriting.' >&2; exit 2; }
    started=$(date +%s)
    go_ok=$(printf '%s' "$environment" | python3 -c 'import json,sys; print(json.load(sys.stdin)["checks"]["go_exact"])')
    if [ "$go_ok" != True ]; then
      require_runner
      if brew list --versions go >/dev/null 2>&1; then
        brew reinstall --build-from-source homebrew/core/go
      else
        brew install --build-from-source homebrew/core/go
      fi
    fi
    preflight | python3 -c 'import json,sys; assert json.load(sys.stdin)["checks"]["go_exact"], "Go receipt does not match pinned core/revision"'
    mkdir -p "$out"
    brew unpack --destdir "$work/source" homebrew/core/fzf
    (
      cd "$work/source/fzf-$version"
      export GOPATH="$(brew --cache)/go_mod_cache" GOCACHE="$(brew --cache)/go_cache" GOENV=off
      /usr/local/opt/go/bin/go mod download
      /usr/local/opt/go/bin/go mod verify
    )
    export MACOSX_DEPLOYMENT_TARGET=15.0
    brew install --build-bottle homebrew/core/fzf
    brew test fzf
    (cd "$out"; brew bottle --json fzf; shasum -a 256 ./*.bottle.tar.gz > SHA256SUMS)
    cp "$lock" "$out/input.lock.json"
    cp "$work/environment.json" "$out/environment.json"
    printf '%s\n' "$key" > "$out/build-key.txt"
    printf '%s\n' "$(( $(date +%s) - started ))" > "$out/build-seconds.txt"
    echo 'Build produced an unvalidated artifact; verify on a separate clean builder.'
  else
    test -n "$artifact" || { echo '--artifact required' >&2; exit 2; }
    test "$(cat "$artifact/build-key.txt")" = "$key"
    python3 - "$root" "$lock" "$artifact/input.lock.json" <<'PYCODE'
import sys
sys.path.insert(0,sys.argv[1]);import state
assert state.inputs(state.validate(state.read(sys.argv[2]))) == state.inputs(state.validate(state.read(sys.argv[3])))
PYCODE
    python3 - "$root" "$artifact" <<'PYCODE'
import sys
sys.path.insert(0,sys.argv[1]);import state
state.verify_build(sys.argv[2])
PYCODE
    bottles=("$artifact"/fzf--*.sequoia.bottle.tar.gz)
    test "${#bottles[@]}" = 1 && test -f "${bottles[0]}"
    go_state() { if [ -f /usr/local/opt/go/INSTALL_RECEIPT.json ]; then shasum -a 256 /usr/local/opt/go/INSTALL_RECEIPT.json; stat -f '%m' /usr/local/opt/go/INSTALL_RECEIPT.json; else echo absent; fi; }
    go_state > "$work/go-before.txt"
    HOMEBREW_DEVELOPER=1 brew install --skip-link "${bottles[0]}"
    go_state > "$work/go-after.txt"; cmp "$work/go-before.txt" "$work/go-after.txt"
    test ! -e /usr/local/bin/fzf && test ! -L /usr/local/bin/fzf
    candidate=/usr/local/opt/fzf/bin/fzf
    [[ "$($candidate --version)" == "$version "* ]]
    file "$candidate" | grep -q 'Mach-O 64-bit executable x86_64'
    if otool -L "$candidate" | grep -q /nix/; then exit 1; fi
    test "$(printf 'hello\nworld\n' | "$candidate" --filter=wld)" = world
    brew test --force fzf
    brew info --json=v2 fzf > "$work/installed-formula.json"
    python3 - "$work/installed-formula.json" "$version" "$revision" <<'PYCODE'
import json,sys
f=json.load(open(sys.argv[1]))['formulae'][0]
expected=sys.argv[2]+('_'+sys.argv[3] if sys.argv[3]!='0' else '')
assert any(i['version']==expected and i['poured_from_bottle'] for i in f['installed'])
PYCODE
    python3 - "$root" "$cached" "$key" "${bottles[0]}" "$work/environment.json" <<'PY'
import sys,pathlib,json,shutil
sys.path.insert(0,sys.argv[1]);import state
p=pathlib.Path(sys.argv[2]);p.mkdir(parents=True,exist_ok=False)
b=pathlib.Path(sys.argv[4]);shutil.copy2(b,p/b.name)
m={'schema':1,'key':sys.argv[3],'status':'validated','checks':['formula-test','x86_64','unlinked','no-nix-linkage','go-unchanged'],
 'files':{b.name:state.sha(b.read_bytes())},'environment':state.read(sys.argv[5])}
(p/'validated.json').write_text(json.dumps(m,indent=2)+'\n')
state.verify(p,sys.argv[3]);print(p)
PY
  fi
  ;;
*) echo 'usage: recipe.sh preflight|prepare-ci|build|verify|reuse [--lock FILE] [--work DIR] [--artifact DIR] [--execute] [--disposable-runner]' >&2; exit 2 ;;
esac
