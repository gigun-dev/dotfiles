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
