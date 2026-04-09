#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# If nix is available, recommend nix run .#switch instead
# ---------------------------------------------------------------------------
if command -v nix &>/dev/null; then
  echo "nix is installed. Run 'git add . && nix run .#switch'"
  exit 0
fi

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

mkdir -p "${HOME}/.config/sheldon" \
         "${HOME}/.config/zeno" \
         "${HOME}/.config/zsh"

link() {
  local src="$1" dst="$2"
  if [[ -L "$dst" ]]; then
    rm "$dst"
  elif [[ -e "$dst" ]]; then
    mv "$dst" "${dst}.backup"
    echo "  Backed up existing $dst → ${dst}.backup"
  fi
  ln -sf "$src" "$dst"
  echo "  $dst → $src"
}

link "${DOTFILES_DIR}/zsh/.zshrc"      "${HOME}/.zshrc"
link "${DOTFILES_DIR}/sheldon"          "${HOME}/.config/sheldon"
link "${DOTFILES_DIR}/zeno"             "${HOME}/.config/zeno"
link "${DOTFILES_DIR}/zsh/functions"    "${HOME}/.config/zsh/functions"

# ---------------------------------------------------------------------------
# 4. Sheldon
# ---------------------------------------------------------------------------
if ! command -v sheldon &>/dev/null; then
  echo "Installing sheldon..."
  curl --proto '=https' -fLsS https://rossmacarthur.github.io/install/crate.sh \
    | bash -s -- --repo rossmacarthur/sheldon --to "${HOME}/.local/bin"
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
