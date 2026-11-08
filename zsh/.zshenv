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
# 二重 source 防止の __HM_SESS_VARS_SOURCED は source 直前に解除する: 残すと、switch 後に既存シェルから
# 起動した子シェル (agent・新しい tmux pane) が再ログインなしでは新しい値を拾えない。
# 中身は単なる export で、PATH は先頭の typeset -gU で一意に保たれるので再 source しても安全。
# source と [[ -r ]] だけで fork しない。
# 1 つ目は nix-darwin / NixOS module 経由、2 つ目は standalone home-manager (WSL / mini-vm) で、
# nix profile 越しではなく現行 generation を直接指す gcroots (ryoppippi/dotfiles と同じ)。
for _hm_vars in \
  "/etc/profiles/per-user/${USER:-$LOGNAME}/etc/profile.d/hm-session-vars.sh" \
  "$HOME/.local/state/home-manager/gcroots/current-home/home-path/etc/profile.d/hm-session-vars.sh"; do
  if [[ -r $_hm_vars ]]; then
    unset __HM_SESS_VARS_SOURCED
    source "$_hm_vars"
    break
  fi
done
unset _hm_vars
