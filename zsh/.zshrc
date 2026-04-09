# =============================================================================
# XDG Base Directory
# =============================================================================
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

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
# Options (mozumasu pattern)
# =============================================================================
setopt hist_ignore_dups
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

function _deferred_compinit() {
  autoload -Uz compinit
  _comp_dump="${ZDOTDIR:-$HOME}/.zcompdump"
  _comp_zwc="$_comp_dump.zwc"
  if [[ -r "$_comp_zwc" && "$_comp_zwc" -nt "$_comp_dump" ]]; then
    source "$_comp_dump"
  elif [[ -r "$_comp_dump" ]]; then
    source "$_comp_dump"
    zcompile "$_comp_dump"
  else
    compinit -d "$_comp_dump"
    zcompile "$_comp_dump"
  fi
  unset _comp_dump _comp_zwc
}
zsh-defer _deferred_compinit

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
fi

# =============================================================================
# Aliases — コマンド置換のみ（略語は zeno snippet で管理）
# =============================================================================
command -v eza &>/dev/null && alias ls='eza'
command -v bat &>/dev/null && alias cat='bat'
alias clr='clear'

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
