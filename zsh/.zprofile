# Homebrew は nix-darwin の /etc/zshenv を正本にする。
# Nix 未導入・standalone の Mac だけ login 時に従来の shellenv を使う。
if [[ "$OSTYPE" == darwin* && -z "${__NIX_DARWIN_SET_ENVIRONMENT_DONE:-}" ]]; then
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv zsh)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv zsh)"
  fi
fi

# 旧 ~/.zprofile → OrbStack init の PATH/fpath 追加をここで宣言する。
# アプリ同梱 init は source せず、起動時の動作をこの正本に限定する。
if [[ "$OSTYPE" == darwin* && -d "$HOME/.orbstack/bin" ]]; then
  path+=("$HOME/.orbstack/bin")
  fpath+=("$HOME/.orbstack/shell/completions/zsh")
fi
