# =============================================================================
# Nix (Linux WSL multi-user: /etc/zsh/zshenv does not source /etc/profile)
# Mac は nix-darwin が PATH を処理するので不要だが、無害
# =============================================================================
if [ -z "$__NIX_SOURCED" ]; then
  if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  elif [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
  fi
  export __NIX_SOURCED=1
fi

# =============================================================================
# Auto-zcompile (mozumasu pattern): source 経由で読まれるファイルを自動 zwc 化
# =============================================================================
ensure_zcompiled() {
  local src=$1 zwc="$1.zwc" dir="${1:h}"
  [[ -w "$dir" ]] || return
  [[ ! -r "$zwc" || "$src" -nt "$zwc" ]] && zcompile "$src"
}
source() { ensure_zcompiled "$1"; builtin source "$@"; }

# =============================================================================
# XDG Base Directory
# =============================================================================
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

# Locale
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

# Bun global bin
export PATH="${XDG_CACHE_HOME}/.bun/bin:$PATH"

# ~/.local/bin — nix/brew で管理できない例外ツール用（末尾=低優先度）
export PATH="$PATH:$HOME/.local/bin"

# zeno: 起動時の `deno cache cli.ts` を毎回実行しない (mise shim 経由 deno で固まる)
# 初回のみ手動で `deno cache <ZENO_ROOT>/src/cli.ts` を打てばよい。
# sheldon が zeno.zsh を source する前に効かせる必要があるためこの位置で export する
export ZENO_DISABLE_EXECUTE_CACHE_COMMAND=1
# zeno.zsh は起動時に `$(deno -V)` を fork する。mise activate は defer 後なので
# deno が PATH に未登録でこの fork が空回り → SIGCHLD race の温床。
# DISABLE_SOCK=1 で zeno-server 起動を抑止し fork を排除する (パフォーマンス影響軽微)。
export ZENO_DISABLE_SOCK=1

# pure prompt は precmd で `who -m` を fork する (pure.zsh:650-656)。
#   if [[ -z $SSH_CONNECTION ]] && (( $+commands[who] )); then who_out=$(who -m); fi
# macOS zsh 5.9 の SIGCHLD race で precmd 段の fork が高頻度で固まる。
# SSH_CONNECTION にダミー値を入れて条件分岐を skip させる (色や user 表示は出ない)。
[[ -z "$SSH_CONNECTION" ]] && export SSH_CONNECTION="local"

# =============================================================================
# Emacs keybind (mozumasu pattern — must be before other bindkey calls)
# =============================================================================
bindkey -e

# =============================================================================
# ensure_installed — skip silently when a tool is missing (nix-free safe)
# =============================================================================
ensure_installed() {
  local cmd=$1; shift
  if command -v "$cmd" &>/dev/null; then
    "$cmd" "$@"
  fi
}

# =============================================================================
# Config cache (ryoppippi pattern + ZWC compile)
# =============================================================================
# brew env は nix-darwin の programs.zsh.shellInit で /etc/zshenv に静的 export 済み。
# vivid LS_COLORS は home.sessionVariables 経由で nix が build 時評価して export 済み。
#
# direnv の自動フック (`direnv hook zsh`) は precmd_functions に登録された
# `_direnv_hook` が毎プロンプトで `direnv export zsh` を fork する設計で、
# macOS 26 + zsh 5.9 の SIGCHLD race を高頻度で踏むため対話が固まる。
# 自動フックを外し、必要時のみ `direnv exec . <cmd>` または明示的に
#   eval "$(direnv export zsh)"
# で env を流し込む手動運用にする。
#
# zoxide も同じく chpwd で `zoxide add` を fork するが、`z`/`zi` 自体は
# fork なしで動くため、init 出力から chpwd 登録行だけを除いて使う。
_zoxide_cache="${XDG_CACHE_HOME}/zsh/zoxide.zsh"
if command -v zoxide &>/dev/null; then
  if [[ ! -r "$_zoxide_cache" || "${commands[zoxide]}" -nt "$_zoxide_cache" ]]; then
    mkdir -p "${_zoxide_cache:h}"
    # `add-zsh-hook chpwd __zoxide_hook` を sed で除去 → 自動 add を無効化
    zoxide init zsh | sed '/add-zsh-hook .* __zoxide_hook/d' > "$_zoxide_cache"
    zcompile "$_zoxide_cache"
  fi
  source "$_zoxide_cache"
fi
unset _zoxide_cache

# =============================================================================
# Sheldon cache (mozumasu pattern)
# =============================================================================
_sheldon_cache="${XDG_CACHE_HOME}/sheldon.zsh"
_sheldon_toml="${XDG_CONFIG_HOME}/sheldon/plugins.toml"
if [[ ! -r "$_sheldon_cache" || "$_sheldon_toml" -nt "$_sheldon_cache" ]]; then
  if command -v sheldon &>/dev/null; then
    sheldon source > "$_sheldon_cache"
    zcompile "$_sheldon_cache"
  fi
fi
[[ -r "$_sheldon_cache" ]] && source "$_sheldon_cache"
unset _sheldon_cache _sheldon_toml

# =============================================================================
# mise (shims のみ: activate を使わず PATH に shims を入れるだけ)
# `mise activate zsh` は precmd で `eval "$(mise hook-env)"` を fork する設計で、
# macOS 26 + zsh 5.9 の SIGCHLD race を毎プロンプトで踏んで対話が固まる。
# shim binary は cwd を見て tool-version を自動解決するので CLI 利用は同等。
# .tool-versions の自動 export (環境変数) は失う (実用上ほぼ影響なし)。
# =============================================================================
if [[ -d "${XDG_DATA_HOME}/mise/shims" ]]; then
  export PATH="${XDG_DATA_HOME}/mise/shims:$PATH"
fi

# =============================================================================
# Pure prompt activation (sheldon 経由で源ファイルはロード済み)
# =============================================================================
autoload -Uz promptinit && promptinit
# pure テーマ未ロード時 (sheldon キャッシュ初期化中など) の prompt usage 出力を完全抑制
prompt pure &>/dev/null || true

# =============================================================================
# History
# =============================================================================
export HISTFILE="${XDG_STATE_HOME}/zsh/history"
export HISTSIZE=100000
export SAVEHIST=100000
[[ -d "${HISTFILE:h}" ]] || mkdir -p "${HISTFILE:h}"

# =============================================================================
# Options (mozumasu pattern)
# =============================================================================
setopt hist_ignore_dups
setopt ignore_eof  # Ctrl+D でシェルが勝手に終了するのを防ぐ (10回 EOF が必要)
setopt hist_ignore_all_dups
setopt hist_ignore_space
setopt hist_reduce_blanks
setopt hist_save_no_dups
setopt inc_append_history
setopt auto_cd
setopt auto_pushd
setopt pushd_ignore_dups
setopt no_beep

# Disable flow control (allow ^S and ^R)
if [[ -t 0 ]]; then
  stty -ixon
fi

# =============================================================================
# Completion (zsh-defer — mozumasu pattern)
# =============================================================================
zstyle ':completion:*' matcher-list "" 'm:{[:lower:]}={[:upper:]}' '+m:{[:upper:]}={[:lower:]}'
zstyle ':completion:*' format '%B%F{blue}%d%f%b'
zstyle ':completion:*' group-name ""
zstyle ':completion:*:default' menu select=2

# fpath に nix profile 経由の completion ディレクトリを追加
# home-manager で入れたパッケージ (gh, git, etc.) の補完を有効化。
# typeset -U で重複除去 (sheldon プラグインや /etc/zshenv の NIX_PROFILES ループが
# 同じディレクトリを多重 prepend し、compinit の fpath 全走査が爆発するのを防ぐ)。
typeset -gU fpath
fpath=(
  "$HOME/.nix-profile/share/zsh/site-functions"
  "$HOME/.nix-profile/share/zsh/$ZSH_VERSION/functions"
  /nix/var/nix/profiles/default/share/zsh/site-functions
  $fpath
)

# Nix 環境で zsh 自身の Completion/{Base,Unix,...} を fpath に追加 (WSL 専用)。
# Mac (nix-darwin) は programs.zsh が処理済みなので不要。かつ
# `$(dirname $(dirname $(readlink -f $(command -v zsh))))` のような 4 段
# command substitution は macOS zsh 5.9 interactive で SIGCHLD レース (lost signal)
# を起こして起動が固まるため、zsh の組込モディファイア (:A:h:h) で fork 0 化する。
if [[ "$OSTYPE" != darwin* ]]; then
  _zsh_share="${commands[zsh]:A:h:h}/share/zsh/$ZSH_VERSION"
  if [[ -d "$_zsh_share/functions/Completion" ]]; then
    fpath=( "$_zsh_share/functions/Completion"/*(/N) $fpath )
  fi
  unset _zsh_share
fi

# Shell integration (OSC 7): 新規タブ/分割を現在のディレクトリで開く (WezTerm 等)
# WSL では WEZTERM_PANE が継承されず $TERM も xterm-256color になるので判定せず常時送信。
# OSC 7 は対応していないターミナルでは無視されるだけなので害なし。
function _wezterm_osc7() {
  printf "\e]7;file://%s%s\e\\" "$HOSTNAME" "$PWD"
}
autoload -Uz add-zsh-hook
add-zsh-hook chpwd _wezterm_osc7
_wezterm_osc7

function _deferred_compinit() {
  autoload -Uz compinit
  _comp_dump="${ZDOTDIR:-$HOME}/.zcompdump"
  # compinit は必ず呼ぶ必要がある (.zcompdump を source するだけでは _comps が
  # 初期化されず補完が登録されない)。24 時間以内なら -C で security check を
  # スキップして高速化、そうでなければ通常 compinit。
  # -u は WSL の nix-profile 補完ディレクトリの insecure permission を無視するため
  # (Mac でも害なし)。
  if [[ -n "$_comp_dump"(#qN.mh-24) ]]; then
    compinit -u -C -d "$_comp_dump"
  else
    compinit -u -d "$_comp_dump"
  fi
  # .zwc 再生成 (キャッシュより新しい場合のみ)
  if [[ ! -f "$_comp_dump.zwc" || "$_comp_dump" -nt "$_comp_dump.zwc" ]]; then
    zcompile "$_comp_dump"
  fi
  unset _comp_dump
}
# compinit の起動タイミング:
# - macOS zsh 5.9 では compdump 内の `$(typeset +fm '_*')` 等の command
#   substitution が SIGCHLD レースで永久 block する症状があり、同期実行すると
#   shell 起動が固まる。zsh-defer でプロンプト表示後に非同期実行すれば、
#   万一 compinit が遅くてもユーザは即座にコマンドを打てる (mozumasu pattern)。
# - WSL は zsh-defer が発火しないケースがあるため同期実行 fallback。
if [[ "$OSTYPE" == darwin* ]] && (( $+functions[zsh-defer] )); then
  zsh-defer _deferred_compinit
else
  _deferred_compinit
fi

# =============================================================================
# Zeno (mozumasu pattern)
# =============================================================================
export ZENO_HOME="${XDG_CONFIG_HOME}/zeno"
export ZENO_ENABLE_SOCK=1
export ZENO_GIT_CAT="bat --color=always"
export ZENO_GIT_TREE="eza --tree"

zeno-reload() {
  pkill -f "deno.*zeno.zsh/src/server.ts" 2>/dev/null
  zeno-enable-sock
}

if [[ -n $ZENO_LOADED ]]; then
  bindkey ' '    zeno-auto-snippet
  bindkey '^m'   zeno-auto-snippet-and-accept-line
  bindkey '^i'   zeno-completion
  bindkey '^r'   zeno-smart-history-selection
  bindkey '^x^s' zeno-insert-snippet

  # zsh-autosuggestions は defer で遅延ロードされるため、
  # zeno ウィジェットを clear リストに追加してゴーストテキスト残留を防止
  zsh-defer -c 'ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=244"; ZSH_AUTOSUGGEST_CLEAR_WIDGETS+=(zeno-auto-snippet-and-accept-line zeno-auto-snippet); _zsh_autosuggest_bind_widgets'
fi

# =============================================================================
# Aliases — コマンド置換のみ（略語は zeno snippet で管理）
# =============================================================================
command -v eza &>/dev/null && alias ls='eza'
command -v bat &>/dev/null && alias cat='bat'
alias clr='clear'
alias notchbar-cli="$HOME/ghq/github.com/gigun-dev/notchbar/.build/debug/notchbar-cli"
alias ab='agent-browser'

_ab_launch() {
  local port=$1 name=$2; shift 2
  if ! curl -sf --connect-timeout 0.2 -o /dev/null http://localhost:$port/json/version 2>/dev/null; then
    if [[ -n "$WSL_DISTRO_NAME" ]]; then
      local appdata
      appdata=$(wslpath -w "$(ls -d /mnt/c/Users/*/AppData/Local 2>/dev/null | grep -vE 'Default|Public' | head -1)")
      "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe" \
        --remote-debugging-port=$port \
        --user-data-dir="$appdata\\Google\\$name" \
        --no-first-run --no-default-browser-check &>/dev/null &!
    else
      local chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
      if [[ ! -x "$chrome" ]]; then
        echo "Chrome not found: $chrome" >&2
        return 1
      fi
      "$chrome" --remote-debugging-port=$port \
        --user-data-dir="$HOME/Library/Application Support/Google/$name" \
        --no-first-run --no-default-browser-check >/dev/null 2>&1 &!
    fi
    local i=0
    while (( i < 30 )); do
      curl -sf --max-time 1 -o /dev/null http://localhost:$port/json/version 2>/dev/null && break
      sleep 0.5
      (( i++ ))
    done
    if (( i >= 30 )); then
      echo "Chrome CDP not ready on port $port" >&2
      return 1
    fi
  fi
  agent-browser --cdp $port "$@"
}
abf() { _ab_launch 9222 chrome-for-agent "$@" }

# =============================================================================
# Hooks
# =============================================================================
# auto ls on cd (ryoppippi pattern)
autoload -Uz add-zsh-hook
_auto_ls() { command -v eza &>/dev/null && eza -hlF || ls -hlF }
add-zsh-hook chpwd _auto_ls

# =============================================================================
# Functions
# =============================================================================
_zsh_functions="${XDG_CONFIG_HOME}/zsh/functions"
if [[ -d "$_zsh_functions" ]]; then
  fpath=("$_zsh_functions" $fpath)
  for func in "$_zsh_functions"/*(.N); do
    autoload -Uz "${func:t}"
  done
fi
unset _zsh_functions

# =============================================================================
# Keybindings
# =============================================================================
zle -N ghq_fzf
bindkey '^g' ghq_fzf
