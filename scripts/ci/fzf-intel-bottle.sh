#!/usr/bin/env bash
# Bounded trial: official Homebrew formulas, no host installation or scheduled updates.
set -euo pipefail
CORE_REV=f8967c7840b2c8af6d0df4a47aaf01140307e725
FZF_SHA=f4cae1e193a4c2a5a01cbeed469f26931b3b067cf22f5f505b97de46574128d7
GO_SHA=60d78711c1300f95a5f3f5ef6f0a1892517e5bdff0c6068d2b0c71bd3233b1f9
out="${RUNNER_TEMP:?}/fzf-artifact"
case "${1:-}" in
prepare)
  test "$(uname -m)" = x86_64
  [[ "$(sw_vers -productVersion)" == 15.* ]]
  test "$(brew --prefix)" = /usr/local
  mkdir -p "$out"
  brew tap --force homebrew/core
  core=$(brew --repo homebrew/core)
  git -C "$core" fetch --depth=1 origin "$CORE_REV"
  git -C "$core" stash push -m fzf-trial-runner-formulas
  git -C "$core" checkout --detach "$CORE_REV"
  cd "$core"
  printf '%s  %s\n' "$FZF_SHA" Formula/f/fzf.rb "$GO_SHA" Formula/g/go.rb | shasum -a 256 -c -
  cp Formula/f/fzf.rb Formula/g/go.rb "$out/"
  printf '%s\n' "$CORE_REV" > "$out/core-revision.txt"
  brew config > "$out/brew-config.txt"
  df -h / > "$out/disk-before.txt"
  ;;
build)
  if brew list --versions fzf >/dev/null 2>&1; then
    echo 'Unexpected preinstalled fzf; refusing replacement.' >&2; exit 1
  fi
  started=$(date +%s)
  if brew list --versions go >/dev/null 2>&1; then
    brew reinstall --build-from-source homebrew/core/go
  else
    brew install --build-from-source homebrew/core/go
  fi
  test "$(/usr/local/opt/go/bin/go env GOVERSION)" = go1.27.3
  brew install --build-bottle homebrew/core/fzf
  brew test fzf
  cd "$out"
  brew bottle --json homebrew/core/fzf
  shasum -a 256 ./*.bottle.tar.gz > SHA256SUMS
  /usr/local/opt/go/bin/go version -m /usr/local/opt/fzf/bin/fzf > buildinfo.txt
  printf '%s\n' "$(( $(date +%s) - started ))" > build-seconds.txt
  du -k ./*.bottle.tar.gz > bottle-size-kib.txt
  df -h / > disk-after.txt
  ;;
verify)
  cd "$out"
  shasum -a 256 -c SHA256SUMS
  bottles=(fzf--0.74.5*.bottle.tar.gz)
  test "${#bottles[@]}" = 1 && test -f "${bottles[0]}"
  if brew list --versions fzf >/dev/null 2>&1; then
    echo 'Unexpected preinstalled fzf; refusing replacement.' >&2; exit 1
  fi
  # Same standard local-bottle route validated by the Tailscale trial.
  go_state() {
    if [ -f /usr/local/opt/go/INSTALL_RECEIPT.json ]; then
      shasum -a 256 /usr/local/opt/go/INSTALL_RECEIPT.json
      stat -f '%m' /usr/local/opt/go/INSTALL_RECEIPT.json
    else
      echo absent
    fi
  }
  go_state > go-before.txt
  HOMEBREW_DEVELOPER=1 brew install --skip-link "$PWD/${bottles[0]}" 2>&1 | tee bottle-install.log
  go_state > go-after.txt
  cmp go-before.txt go-after.txt
  test ! -e /usr/local/bin/fzf
  fzf=/usr/local/opt/fzf/bin/fzf
  "$fzf" --version | tee verified-version.txt
  grep -q '^0.74.5' verified-version.txt
  file "$fzf" | tee architecture.txt
  grep -q 'Mach-O 64-bit executable x86_64' architecture.txt
  test "$(printf 'hello\nworld\n' | "$fzf" --filter=wld)" = world
  brew test fzf
  brew info --json=v2 fzf > installed-formula.json
  ruby -rjson -e 'f=JSON.parse(File.read("installed-formula.json"))["formulae"].first; abort "not poured" unless f["installed"].any? { |i| i["version"] == "0.74.5" && i["poured_from_bottle"] }'
  ;;
*) echo 'usage: fzf-intel-bottle.sh prepare|build|verify' >&2; exit 2 ;;
esac
