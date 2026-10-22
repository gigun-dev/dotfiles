# Sourced by bootstrap.sh. Returning means the legacy installer may continue.
dotfiles_bootstrap_route() {
  # Guard だけの反映: Homebrew / uv tool / launchd には触れず Nix 有無にも依存しない。
  if [[ "${1:-}" == "--guard-only" && "$#" == 1 ]]; then
    exec /bin/sh "${DOTFILES_DIR}/scripts/guard-apply.sh" --apply
  fi

  # Pro は Nix/Home Manager に委譲し、未導入時・凍結ホストの互換経路を残す。
  WITH_NET_WATCHDOG=0
  LEGACY=0
  for arg in "$@"; do
    case "$arg" in
    --legacy) LEGACY=1 ;;
    --net-watchdog) WITH_NET_WATCHDOG=1; LEGACY=1 ;;
    --help|-h)
      echo "usage: $0 [--guard-only | --legacy [--net-watchdog]]"
      echo "default: Nix 導入済みなら通常 switch、未導入なら従来の導入・リンク経路。"
      exit 0 ;;
    *) echo "unknown argument: $arg (see --help)" >&2; exit 2 ;;
    esac
  done
  if [ "$LEGACY" = 0 ] && command -v nix >/dev/null 2>&1; then
    if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = x86_64 ]; then
      echo "Intel Mac の Nix 適用は凍結中。Guard のみ: bash bootstrap.sh --guard-only" >&2
      echo "旧導入経路が必要な場合のみ --legacy / --net-watchdog を明示する。" >&2
      exit 1
    fi
    # HM のライブリンクも同じ固定 checkout を参照する。隔離 worktree を誤適用しない。
    expected="$HOME/ghq/github.com/gigun-dev/dotfiles"
    if [ "$DOTFILES_DIR" != "$expected" ]; then
      echo "Nix の設定元は $expected です。この checkout からは適用しません。" >&2
      exit 1
    fi
    cd "$DOTFILES_DIR"
    exec nix run .#switch
  fi

  # Nix 未導入時は従来の fallback を維持する（導入・リンク処理を伴う）。
  # 欠損 checkout で導入を始めない。正本は HM と共有する。
  for source in npm/npmrc bun/bunfig.toml uv/uv.toml pip/pip.conf scripts/guard-apply.sh zsh/.zprofile; do
    if [ ! -r "$DOTFILES_DIR/$source" ]; then
      echo "missing source: $source; checkout を確認してください" >&2
      exit 1
    fi
  done

  # 今回管理へ取り込む通常 .zprofile の既存退避先を上書きしない。
  if [[ -e "$HOME/.zprofile" && ! -L "$HOME/.zprofile" ]] &&
    [[ -e "$HOME/.zprofile.backup" || -L "$HOME/.zprofile.backup" ]]; then
    echo "existing .zprofile.backup; preserve and review before bootstrap" >&2
    exit 1
  fi

}
