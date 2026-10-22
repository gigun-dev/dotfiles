#!/usr/bin/env bash
# checkout とユーザー Guard 設定の限定検査。全体 activation は呼ばない。
set -euo pipefail
mode=${1:-}
if [ "$#" -gt 1 ] || { [ -n "$mode" ] && [ "$mode" != --declarations ]; }; then
  echo 'usage: bash scripts/check.sh [--declarations]' >&2
  exit 2
fi
root=$(git rev-parse --show-toplevel)
cd "$root"
"${CHECK_PYTHON:-python3}" -I -S -B scripts/guard-check.py --repo "$root"
if [ "$mode" = --declarations ]; then
  if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo '--declarations は Pro 用。mini の Nix 凍結は解除しません' >&2
    exit 1
  fi
  nix eval --offline --no-write-lock-file --option allow-import-from-derivation false --json \
    .#darwinConfigurations.gigun-aarch64-darwin.config.home-manager.users.gigun.home.file \
    --apply 'files: builtins.mapAttrs (_: path: { inherit (files.${path}) enable; sha256 = builtins.hashString "sha256" files.${path}.text; }) {
      npm = ".npmrc"; bun = ".bunfig.toml"; bunXdg = ".config/.bunfig.toml";
      uv = ".config/uv/uv.toml"; pip = ".config/pip/pip.conf";
      pipMac = "Library/Application Support/pip/pip.conf";
    }'
fi
printf '%s\n' '限定検査のみ。全体構成の評価・ビルド・世代切替の成功は示しません。'
