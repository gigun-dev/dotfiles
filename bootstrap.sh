#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

. "${DOTFILES_DIR}/scripts/bootstrap-route.sh"
dotfiles_bootstrap_route "$@"

# 以下は互換用 fallback。CLT/Homebrew/uv tools の導入や launchd の変更を伴う。
# Pro の通常設定管理には使わない。Guard は同じ正本を guard-apply.sh で配置する。
# ---------------------------------------------------------------------------
# 1. Xcode Command Line Tools
# ---------------------------------------------------------------------------
if ! /usr/bin/xcrun -f clang >/dev/null 2>&1; then
  echo "Installing Xcode Command Line Tools..."
  touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  PROD=$(/usr/sbin/softwareupdate -l | grep "\*.*Command Line" | tail -n 1 | sed 's/^[^C]* //')
  /usr/sbin/softwareupdate -i "$PROD" --verbose
  echo "Xcode CLT installed."
else
  echo "Xcode CLT already installed."
fi

# ---------------------------------------------------------------------------
# 2. Homebrew
# ---------------------------------------------------------------------------
if ! command -v brew &>/dev/null; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Set up brew in current session
  if [[ "$(uname -m)" == "arm64" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  echo "Homebrew installed."
else
  echo "Homebrew already installed."
fi

# ---------------------------------------------------------------------------
# 3. Symlinks (same targets as dotfiles.nix)
# ---------------------------------------------------------------------------
echo "Creating symlinks..."

# mini の5リンクは Ansible が所有する。DHCP由来の hostname やCPUで判定しない。
mini_shell_ansible=0
if [[ "$(uname -s)" == Darwin ]] && [[ "$(/usr/sbin/scutil --get LocalHostName 2>/dev/null)" == mini ]]; then
  mini_shell_ansible=1
fi
if [[ "$mini_shell_ansible" == 0 ]]; then
  mkdir -p "${HOME}/.config/sheldon" "${HOME}/.config/zeno"
fi
mkdir -p "${HOME}/.config/zsh" "${HOME}/.config/claude-code"

link() {
  local src="$1" dst="$2"
  # 古い clone には無いファイルがありうる ([実測 2026-09-03] mini の clone は
  # npm/ bun/ を持たない rev だった)。無い src を張ると宙吊りリンクになり、
  # npm 等が読みに行って壊れるので、ensure_installed パターンと同じく静かに
  # スキップする。git pull で追いつけば次回の実行で張られる。
  if [[ ! -e "$src" ]]; then
    echo "  skip (missing in repo): $src"
    return 0
  fi
  if [[ -L "$dst" ]]; then
    rm "$dst"
  elif [[ -e "$dst" ]]; then
    mv "$dst" "${dst}.backup"
    echo "  Backed up existing $dst → ${dst}.backup"
  fi
  ln -sf "$src" "$dst"
  echo "  $dst → $src"
}

if [[ "$mini_shell_ansible" == 0 ]]; then
  link "${DOTFILES_DIR}/zsh/.zshrc" "${HOME}/.zshrc"
  link "${DOTFILES_DIR}/zsh/.zshenv" "${HOME}/.zshenv"
  link "${DOTFILES_DIR}/sheldon" "${HOME}/.config/sheldon"
  link "${DOTFILES_DIR}/zeno" "${HOME}/.config/zeno"
  link "${DOTFILES_DIR}/zsh/functions" "${HOME}/.config/zsh/functions"
fi
link "${DOTFILES_DIR}/zsh/.zprofile" "${HOME}/.zprofile"
# global ignore (nix 側は dotfiles.nix が同じ場所へ張る)
mkdir -p "${HOME}/.config/git"
link "${DOTFILES_DIR}/git/ignore" "${HOME}/.config/git/ignore"

# 欠損や未知の既存設定を黙って飛ばさず、全件の事前検査後に Guard だけ配置する。
/bin/sh "${DOTFILES_DIR}/scripts/guard-apply.sh" --apply
link "${DOTFILES_DIR}/claude/langfuse-endpoints.env" "${HOME}/.config/claude-code/langfuse-endpoints.env"

# Keep user-global agent instructions consistent with home-manager setup.
# Codex 用は断片を連結した生成物 (dotfiles.nix と同じスクリプト)。古い clone には無い。
mkdir -p "${HOME}/.claude" "${HOME}/.codex"
link "${DOTFILES_DIR}/agents/AGENTS.md" "${HOME}/.claude/CLAUDE.md"
link "${DOTFILES_DIR}/agents/shared" "${HOME}/.claude/shared"
if [[ -f "${DOTFILES_DIR}/agents/codex-agents-md.sh" ]]; then
  codex_agents_tmp="$(mktemp "${HOME}/.codex/.AGENTS.md.XXXXXX")"
  if sh "${DOTFILES_DIR}/agents/codex-agents-md.sh" "${DOTFILES_DIR}/agents" >"$codex_agents_tmp"; then
    # mv は旧運用の symlink 自体を置き換え、リンク先 (repo のファイル) には書かない
    chmod 644 "$codex_agents_tmp"
    mv "$codex_agents_tmp" "${HOME}/.codex/AGENTS.md"
    echo "  ${HOME}/.codex/AGENTS.md (generated)"
  else
    rm -f "$codex_agents_tmp"
    echo "  skip: could not generate ${HOME}/.codex/AGENTS.md" >&2
  fi
fi

# zsh/functions の permission を 755 に固定 (compinit insecure 対策)
# 777 だと compinit が全補完スキップする
chmod -R go-w "${DOTFILES_DIR}/zsh/functions" 2>/dev/null || true

# git hooks を有効化 (pre-commit の nix fmt 自動適用と、pull 後の Nix 構成の自動 switch)
# 古い clone には git/hooks が無いので、あるときだけ (link() の存在ガードと同じ理由)
if [[ -d "${DOTFILES_DIR}/git/hooks" ]]; then
  git -C "${DOTFILES_DIR}" config --local core.hooksPath git/hooks
  chmod +x "${DOTFILES_DIR}/git/hooks/"* 2>/dev/null || true
fi

# uv tool の宣言分 (uv/tools.txt) を入れる。uv が無ければ黙って飛ばす。
# home.activation の syncUvTools と同じスクリプト。
if [[ -f "${DOTFILES_DIR}/uv/sync-tools.sh" ]]; then
  bash "${DOTFILES_DIR}/uv/sync-tools.sh" || true
fi

# ---------------------------------------------------------------------------
# 4. Sheldon
# ---------------------------------------------------------------------------
if ! command -v sheldon &>/dev/null; then
  echo "Installing sheldon..."
  curl --proto '=https' -fLsS https://rossmacarthur.github.io/install/crate.sh |
    bash -s -- --repo rossmacarthur/sheldon --to "${HOME}/.local/bin"
  echo "sheldon installed to ~/.local/bin"
else
  echo "sheldon already installed."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "Bootstrap complete!"
echo ""
echo "Next steps:"
echo "  1. Restart your shell (exec zsh)"
echo "  2. To enable full nix management:"
echo "     curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh"
echo "     nix run .#switch"
