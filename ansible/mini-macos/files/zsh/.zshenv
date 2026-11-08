# Intel mini の macOS 専用の最小 zsh 設定 (Ansible の shell 対象が ~/.zshenv へリンクする)。
# 共通の zsh/.zshenv は Nix の hm-session-vars を前提にするので、凍結した Nix に依存しない
# mini には配らない (docs/adr/0014)。/nix や /etc/profiles を参照する行は足さないこと。
# 全ての zsh (zsh -c や ssh 経由を含む) が読むため、fork を伴う処理は置かない。

# PATH と結び付いた配列の重複を除く。login shell の path_helper や .zprofile の再追加への備え。
typeset -gU PATH path

# XDG: ツールの置き場所を shell の種別によらず揃える
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

# Homebrew (Intel の /usr/local) の `brew shellenv zsh` 相当を静的に書く。
# eval だと shell 起動のたびに brew を fork するうえ、非 interactive の zsh -c では
# 誰も呼ばないので、この mini の役割 (limactl / tailscale / cloudflared / rg 等を Homebrew 由来で
# 使う) では .zshenv に固定値で置くほうが確実。
export HOMEBREW_PREFIX=/usr/local
export HOMEBREW_CELLAR=/usr/local/Cellar
export HOMEBREW_REPOSITORY=/usr/local/Homebrew
path=(/usr/local/bin /usr/local/sbin $path)
[[ -d /usr/local/share/man ]] && export MANPATH="/usr/local/share/man:${MANPATH-}"

# ~/.local/bin は宣言管理できない例外ツール (asc 等) の置き場。末尾=低優先度で、
# Homebrew やシステムのコマンドを覆わない。
path+=("$HOME/.local/bin")
