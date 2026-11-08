# Intel mini の macOS 専用の最小 interactive 設定 (~/.zshrc へリンクされる)。
# mini の対話シェルは iPhone バックアップ・Xcode・Lima・Tailscale の操作と保守に限る。
# 開発作業は mini-vm で行うので、sheldon / zeno / eza / mise などは持ち込まない (docs/adr/0014)。
# PATH と XDG は .zshenv で設定済み。

# history: 保守作業の記録が残れば足りる。複数 shell 間で共有する
HISTFILE="$XDG_STATE_HOME/zsh/history"
HISTSIZE=10000
SAVEHIST=10000
[[ -d ${HISTFILE:h} ]] || mkdir -p "${HISTFILE:h}"
setopt APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE

setopt AUTO_CD INTERACTIVE_COMMENTS

# 補完: Homebrew 提供の補完 (limactl / tailscale 等) を拾うため site-functions を足す。
# -u は所有者違いのディレクトリで確認を求められて起動が止まるのを避ける。
[[ -d /usr/local/share/zsh/site-functions ]] && fpath=(/usr/local/share/zsh/site-functions $fpath)
[[ -d ${XDG_CACHE_HOME}/zsh ]] || mkdir -p "${XDG_CACHE_HOME}/zsh"
autoload -Uz compinit && compinit -u -d "${XDG_CACHE_HOME}/zsh/zcompdump"

# 素朴なプロンプト: user@host dir %。直前のコマンドが失敗したら赤くする
PROMPT='%F{cyan}%n@%m%f %F{blue}%~%f %(?.%#.%F{red}%#%f) '

alias ls='ls -G'

# fzf / zoxide は Ansible が /usr/local/bin に選択リンクした場合だけ有効にする。
# 無くても shell が壊れないよう存在確認してから init する。
(( $+commands[fzf] )) && source <(fzf --zsh)
(( $+commands[zoxide] )) && eval "$(zoxide init zsh)"
