# PATH と結び付いた zsh 配列を先頭優先で一意に保つ。
# login / interactive の別なく、後続の brew や .zshrc の再追加にも適用する。
# 既存の優先順位は変えず、実体のないパスもここでは削除しない。
typeset -gU PATH path

# =============================================================================
# XDG Base Directory
# =============================================================================
# .zshenv は interactive / 非 interactive (zsh -c など、エージェント経由を含む) を問わず
# 全ての zsh が読むため、XDG はここで設定する (.zshrc だと wrangler 等が別の場所を見る)。
# 毎回の zsh 起動で実行されるので、fork を伴う処理は置かず最小限に保つこと。
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

# =============================================================================
# home-manager の session 変数
# =============================================================================
# このリポジトリは .zshrc を強制リンクして programs.zsh を使わないため、home-manager が
# 生成する hm-session-vars.sh は誰も source しない。home.sessionVariables
# (AGY_CLI_DISABLE_AUTO_UPDATE / SLACK_SKIP_UPDATE / LS_COLORS 等) を効かせるにはここで手動 source する。
# ファイル側が __HM_SESS_VARS_SOURCED で二重 source を防ぐ。source と [[ -r ]] だけで fork しない。
# 1 つ目は nix-darwin / NixOS の module 経由、2 つ目は standalone (WSL)。
for _hm_vars in \
  "/etc/profiles/per-user/${USER:-$LOGNAME}/etc/profile.d/hm-session-vars.sh" \
  "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"; do
  if [[ -r $_hm_vars ]]; then
    source "$_hm_vars"
    break
  fi
done
unset _hm_vars
