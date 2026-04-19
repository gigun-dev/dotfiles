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
_config_cache="${XDG_CACHE_HOME}/zsh/config.zsh"
if [[ ! -f "$_config_cache" || "${ZDOTDIR:-$HOME}/.zshrc" -nt "$_config_cache" ]]; then
  mkdir -p "${XDG_CACHE_HOME}/zsh"
  {
    # brew shellenv (architecture-aware)
    if [[ "$(uname -m)" == "arm64" ]]; then
      /opt/homebrew/bin/brew shellenv 2>/dev/null
    else
      /usr/local/bin/brew shellenv 2>/dev/null
    fi
    # Tool init (skipped if not installed)
    if command -v vivid &>/dev/null; then
      echo "export LS_COLORS=\"$(vivid generate gruvbox-dark)\""
    fi
    ensure_installed direnv hook zsh
    ensure_installed zoxide init zsh
  } > "$_config_cache"
  zcompile "$_config_cache"
fi
source "$_config_cache"
unset _config_cache

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
# Pure prompt activation (sheldon 経由で源ファイルはロード済み)
# =============================================================================
autoload -Uz promptinit && promptinit
prompt pure 2>/dev/null || true

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
# home-manager で入れたパッケージ (gh, git, etc.) の補完を有効化
fpath=(
  "$HOME/.nix-profile/share/zsh/site-functions"
  "$HOME/.nix-profile/share/zsh/$ZSH_VERSION/functions"
  /nix/var/nix/profiles/default/share/zsh/site-functions
  $fpath
)

# Nix 環境では zsh 自身の補完 (_cd / _ls 等の Completion/Unix/) が自動で
# fpath に入らないため、zsh インストール先の Completion サブディレクトリを追加。
# Mac は nix-darwin の programs.zsh が処理するので不要だが、無害。
_zsh_share="$(dirname "$(dirname "$(readlink -f "$(command -v zsh)")")")/share/zsh/$ZSH_VERSION"
if [[ -d "$_zsh_share/functions/Completion" ]]; then
  fpath=( "$_zsh_share/functions/Completion"/*(/N) $fpath )
fi
unset _zsh_share

# WezTerm shell integration (OSC 7): 新規タブ/分割を現在のディレクトリで開く
# WEZTERM_PANE は WezTerm が子プロセスに設定するが、WSL では WSLENV に
# 含まれていないと継承されないので $TERM=wezterm でも有効化 (TERM は WSLENV 継承される)。
if [[ -n "$WEZTERM_PANE" || "$TERM" == wezterm* ]]; then
  function _wezterm_osc7() {
    printf "\e]7;file://%s%s\e\\" "$HOSTNAME" "$PWD"
  }
  autoload -Uz add-zsh-hook
  add-zsh-hook chpwd _wezterm_osc7
  _wezterm_osc7
fi

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
# 起動時に同期実行 (WSL では zsh-defer の遅延が発火しないケースがあり、
# defer だと Tab 補完が効かない問題が発生。Mac では defer 発火するが
# 両環境で確実に動くよう同期実行に統一)
_deferred_compinit

# =============================================================================
# Zeno (mozumasu pattern)
# =============================================================================
export ZENO_HOME="${XDG_CONFIG_HOME}/zeno"
export ZENO_ENABLE_SOCK=1
export ZENO_GIT_CAT="bat --color=always"
export ZENO_GIT_TREE="eza --tree"

if [[ -n $ZENO_LOADED ]]; then
  bindkey ' '    zeno-auto-snippet
  bindkey '^m'   zeno-auto-snippet-and-accept-line
  bindkey '^i'   zeno-completion
  bindkey '^r'   zeno-smart-history-selection
  bindkey '^x^s' zeno-insert-snippet

  # zsh-autosuggestions は defer で遅延ロードされるため、
  # zeno ウィジェットを clear リストに追加してゴーストテキスト残留を防止
  zsh-defer -c 'ZSH_AUTOSUGGEST_CLEAR_WIDGETS+=(zeno-auto-snippet-and-accept-line zeno-auto-snippet); _zsh_autosuggest_bind_widgets'
fi

# =============================================================================
# Aliases — コマンド置換のみ（略語は zeno snippet で管理）
# =============================================================================
command -v eza &>/dev/null && alias ls='eza'
command -v bat &>/dev/null && alias cat='bat'
alias clr='clear'
alias notchbar-cli="$HOME/ghq/github.com/gigun-dev/notchbar/.build/debug/notchbar-cli"

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
