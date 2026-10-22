#!/bin/sh
# Guard-only deployment. No package manager, shell profile, or activation is executed.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mode=${1:---check}
case "$mode" in --check|--apply) ;; *) echo 'usage: guard-apply.sh [--check|--apply]' >&2; exit 2;; esac
[ "$#" -le 1 ] || exit 2
config=${XDG_CONFIG_HOME:-"$HOME/.config"}
case "$config" in /*) ;; *) echo 'XDG_CONFIG_HOME must be absolute' >&2; exit 1;; esac

files() {
  "$1" "$root/npm/npmrc" "$HOME/.npmrc"
  "$1" "$root/bun/bunfig.toml" "$HOME/.bunfig.toml"
  "$1" "$root/bun/bunfig.toml" "$config/.bunfig.toml"
  "$1" "$root/uv/uv.toml" "$config/uv/uv.toml"
  "$1" "$root/pip/pip.conf" "$config/pip/pip.conf"
  if [ "$(uname -s)" = Darwin ]; then
    "$1" "$root/pip/pip.conf" "$HOME/Library/Application Support/pip/pip.conf"
  fi
}

normalized() { sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d; s/[[:space:]]//g' "$1"; }
validate() {
  [ -f "$1" ] || { echo "missing source: $1" >&2; exit 1; }
  # Migrate only the known obsolete Bun link. Unknown/unreadable links stay intact.
  if [ "$2" = "$config/.bunfig.toml" ] && [ -L "$2" ] && [ ! -e "$2" ]; then
    legacy=$(readlink "$2")
    case "$legacy" in
      "$root/bunfig.toml"|"$HOME/ghq/github.com/gigun-dev/dotfiles/bunfig.toml")
        [ -r "$(dirname "$legacy")" ] && [ -x "$(dirname "$legacy")" ] && return ;;
    esac
  fi
  if [ -e "$2" ] || [ -L "$2" ]; then
    [ -f "$2" ] && [ -r "$2" ] || { echo "unreadable destination: $2" >&2; exit 1; }
    # Only an already-equivalent anonymous configuration may be replaced.
    # Credentials, unrelated options, or another registry require a human merge.
    [ "$(normalized "$1")" = "$(normalized "$2")" ] || {
      echo "existing configuration differs; preserved: $2" >&2; exit 1;
    }
  fi
}
check() {
  [ -f "$2" ] && cmp -s "$1" "$2" || {
    echo "missing or unapplied: $2" >&2; return 1;
  }
}
apply() {
  src=$1 dst=$2
  mkdir -p -- "$(dirname -- "$dst")"
  # Snapshot copy; never write through an old symlink or require a Nix GC root.
  temp=$(mktemp "${dst}.guard.XXXXXX")
  cp -p "$src" "$temp"
  if [ -f "$dst" ] && [ ! -L "$dst" ]; then
    if [ "$(uname -s)" = Darwin ]; then
      permissions=$(stat -f '%Lp' "$dst")
    else
      permissions=$(stat -c '%a' "$dst")
    fi
    chmod "$permissions" "$temp"
  fi
  mv -f "$temp" "$dst"
  echo "applied: $dst"
}

# Validate every source and destination before making any changes.
files validate
if [ "$mode" = --check ]; then files check; else files apply; fi
