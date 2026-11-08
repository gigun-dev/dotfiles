# git-wtpr shell hook for zsh
# Wraps `git` so `git wtpr` can cd into the new worktree, chaining onto the
# `git` wrapper that `git-wt --init zsh` defines (source this after it).
#
# Local change from upstream: upstream emits init.bash for zsh, but there
# `declare -F` is `typeset -F` (declare a float), so the existence checks
# define a float named `git` instead of testing for the function. zsh's
# `$+functions[...]` replaces them; the cd contract is unchanged.

if (( $+functions[git] && ! $+functions[__git_wtpr_inner] )); then
  eval "__git_wtpr_inner() { ${functions[git]} }"
fi

git() {
  if [[ $1 == "wtpr" ]]; then
    shift
    local nocd_flag=false
    local nocd_mode
    nocd_mode="$(command git config --get wt.nocd 2>/dev/null || true)"
    local existing_worktrees=""
    if [[ $nocd_mode == "create" ]]; then
      existing_worktrees=$(command git worktree list --porcelain 2>/dev/null | grep '^worktree ' | cut -d' ' -f2- || true)
    fi
    local arg
    for arg in "$@"; do
      if [[ $arg == "--nocd" || $arg == "--no-switch-directory" ]]; then
        nocd_flag=true
      fi
    done
    local result exit_code last_line
    result=$(GIT_WT_SHELL_INTEGRATION=1 command git-wtpr "$@")
    exit_code=$?
    last_line=$(printf '%s\n' "$result" | tail -n 1)
    if [[ $exit_code -eq 0 && -d $last_line ]]; then
      printf '%s\n' "$result" | sed '$d'
      local should_cd=true
      if [[ $nocd_flag == "true" ]]; then
        should_cd=false
      elif [[ $nocd_mode == "true" || $nocd_mode == "all" ]]; then
        should_cd=false
      elif [[ $nocd_mode == "create" ]]; then
        if printf '%s\n' "$existing_worktrees" | grep -qxF "$last_line"; then
          should_cd=true
        else
          should_cd=false
        fi
      fi
      if [[ $should_cd == "true" ]]; then
        cd "$last_line" || return
      else
        printf '%s\n' "$last_line"
      fi
    else
      printf '%s\n' "$result"
      return "$exit_code"
    fi
  elif (( $+functions[__git_wtpr_inner] )); then
    __git_wtpr_inner "$@"
  else
    command git "$@"
  fi
}
