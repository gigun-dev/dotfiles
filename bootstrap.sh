#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# 0. 引数
# ---------------------------------------------------------------------------
# --net-watchdog: network-watchdog (番人) を launchd user agent として導入する。
#   2026-09-03 に mini が 7 時間外部と通信できなくなった障害への手当て
#   (経緯は nix/modules/darwin/network-watchdog.sh の冒頭)。
#
# なぜ自動判定ではなくフラグか (2026-09-03 の設計判断):
#   番人を入れるべきかは「常時起動の拠点か」という**役割**で決まる。役割は機械の
#   属性からは検出できず、人が決めて宣言するもの — flake.nix の mkDarwinSystem が
#   `alwaysOn` を引数で受け取るのと同じ形を、nix の届かない側でも取る。
#   Why not ホスト名/arch 分岐: mini が Intel なのは買った時期の偶然で、常時起動で
#   ある事実とは無関係 (flake.nix の mkDarwinSystem のコメント参照)。ホスト名も
#   同じ罠 — 機械を入れ替えた日に黙って番人が消える/現れる。
#   Why not `nix eval` による能力検出: 「darwin 構成が評価できるか」は検出できても
#   「番人が要るか」(役割) は分からない。しかも flake の全入力 fetch + モジュール
#   全評価が要り、ネットワークが怪しい機械でこそ走らせたいスクリプトには重すぎる上、
#   単にオフラインなだけの MacBook でも eval が失敗して「凍結ホスト」と誤判定する。
WITH_NET_WATCHDOG=0
for arg in "$@"; do
  case "$arg" in
  --net-watchdog) WITH_NET_WATCHDOG=1 ;;
  *)
    echo "usage: $0 [--net-watchdog]" >&2
    exit 2
    ;;
  esac
done

# ---------------------------------------------------------------------------
# If nix is available, recommend nix run .#switch instead
# ---------------------------------------------------------------------------
# ⚠️ 「nix がある = nix で全部管理できる」ではない。mini (Intel) は Lima ゲスト
# (mini-vm) の管理のため nix 自体は入っているが、darwin 構成は評価できない
# ([実測 2026-09-03 mini] nixpkgs 26.11 の x86_64-darwin drop により
# `gigun-x86_64-darwin` は nix eval すら通らない。CLAUDE.md の凍結の節を参照)。
# そういう機械では --net-watchdog が「この機械には手で当てる」という宣言を兼ねる
# ので、フラグ付きのときはこの早期 exit を素通りして下の手当てを全部実行する
# (各節は冪等なので、nix 管理下の状態と二重に当たっても壊れない —
# 「bootstrap.sh と dotfiles.nix は同じことをする」設計原則)。
if command -v nix &>/dev/null && [ "$WITH_NET_WATCHDOG" != "1" ]; then
  echo "nix is installed. Run 'git add . && nix run .#switch'"
  echo "(nix はあるが darwin 構成が評価できない凍結ホスト — mini — では"
  echo " './bootstrap.sh --net-watchdog' で番人ごと手当てする)"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Xcode Command Line Tools
# ---------------------------------------------------------------------------
if ! /usr/bin/xcrun -f clang >/dev/null 2>&1; then
  echo "Installing Xcode Command Line Tools..."
  touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  PROD=$(/usr/sbin/softwareupdate -l | grep "\*.*Command Line" | tail -n 1 | sed 's/^[^C]* //')
  /usr/sbin/softwareupdate -i "$PROD" --verbose
  echo "Xcode CLT installed."
else
  echo "Xcode CLT already installed."
fi

# ---------------------------------------------------------------------------
# 2. Homebrew
# ---------------------------------------------------------------------------
if ! command -v brew &>/dev/null; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Set up brew in current session
  if [[ "$(uname -m)" == "arm64" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  echo "Homebrew installed."
else
  echo "Homebrew already installed."
fi

# ---------------------------------------------------------------------------
# 3. Symlinks (same targets as dotfiles.nix)
# ---------------------------------------------------------------------------
echo "Creating symlinks..."

mkdir -p "${HOME}/.config/sheldon" \
  "${HOME}/.config/zeno" \
  "${HOME}/.config/zsh"

link() {
  local src="$1" dst="$2"
  # 古い clone には無いファイルがありうる ([実測 2026-09-03] mini の clone は
  # npm/ bun/ を持たない rev だった)。無い src を張ると宙吊りリンクになり、
  # npm 等が読みに行って壊れるので、ensure_installed パターンと同じく静かに
  # スキップする。git pull で追いつけば次回の実行で張られる。
  if [[ ! -e "$src" ]]; then
    echo "  skip (missing in repo): $src"
    return 0
  fi
  if [[ -L "$dst" ]]; then
    rm "$dst"
  elif [[ -e "$dst" ]]; then
    mv "$dst" "${dst}.backup"
    echo "  Backed up existing $dst → ${dst}.backup"
  fi
  ln -sf "$src" "$dst"
  echo "  $dst → $src"
}

link "${DOTFILES_DIR}/zsh/.zshrc" "${HOME}/.zshrc"
link "${DOTFILES_DIR}/sheldon" "${HOME}/.config/sheldon"
link "${DOTFILES_DIR}/zeno" "${HOME}/.config/zeno"
link "${DOTFILES_DIR}/zsh/functions" "${HOME}/.config/zsh/functions"

# Takumi Guard (匿名モード、詳細は npm/npmrc のコメント参照)
link "${DOTFILES_DIR}/npm/npmrc" "${HOME}/.npmrc"
link "${DOTFILES_DIR}/bun/bunfig.toml" "${HOME}/.bunfig.toml"

# zsh/functions の permission を 755 に固定 (compinit insecure 対策)
# 777 だと compinit が全補完スキップする
chmod -R go-w "${DOTFILES_DIR}/zsh/functions" 2>/dev/null || true

# git hooks を有効化 (pre-commit で nix fmt を自動適用し CI fmt 失敗を防ぐ)
# 古い clone には git/hooks が無いので、あるときだけ (link() の存在ガードと同じ理由)
if [[ -d "${DOTFILES_DIR}/git/hooks" ]]; then
  git -C "${DOTFILES_DIR}" config --local core.hooksPath git/hooks
  chmod +x "${DOTFILES_DIR}/git/hooks/"* 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 4. Sheldon
# ---------------------------------------------------------------------------
if ! command -v sheldon &>/dev/null; then
  echo "Installing sheldon..."
  curl --proto '=https' -fLsS https://rossmacarthur.github.io/install/crate.sh |
    bash -s -- --repo rossmacarthur/sheldon --to "${HOME}/.local/bin"
  echo "sheldon installed to ~/.local/bin"
else
  echo "sheldon already installed."
fi

# ---------------------------------------------------------------------------
# 5. network-watchdog (番人) — --net-watchdog のときだけ
# ---------------------------------------------------------------------------
# nix 管理下の機械では nix/modules/darwin/network-watchdog.nix (system daemon,
# ログは /var/log/net-watchdog) が正で、ここは通らない。ここは nix の届かない
# 凍結ホスト (mini) 用に、**同じスクリプト**を launchd user agent として据える。
#
# なぜ system daemon ではなく user agent か: daemon の設置には sudo が要る。
# エージェント経由の手当てではパスワードを扱えないため、まず sudo 無しで届く
# user agent として入れる。弱点は「OS 起動から自動ログインまでの数秒は走らない」
# こと ([実測 2026-09-03 mini] autoLoginUser=gigun / FileVault Off なので自動
# ログイン後に上がるはず(未検証))。この窓を消したければ、依頼者が sudo を 1 回
# 打って system daemon へ昇格する:
#   sudo bash nix/modules/darwin/net-watchdog-system-install.sh
# (昇格すると出力先は ~/Library/Logs/net-watchdog → /var/log/net-watchdog に変わる)
install_net_watchdog() {
  local label="dev.gigun.net-watchdog"
  local src="${DOTFILES_DIR}/nix/modules/darwin/network-watchdog.sh"
  local app_dir="${HOME}/Library/Application Support/net-watchdog"
  local log_dir="${HOME}/Library/Logs/net-watchdog"
  local agent_plist="${HOME}/Library/LaunchAgents/${label}.plist"
  local daemon_plist="/Library/LaunchDaemons/${label}.plist"
  local uid
  uid=$(id -u)

  if [[ ! -f "$src" ]]; then
    echo "net-watchdog: $src が無い (clone が古い?)。git pull してから再実行" >&2
    return 1
  fi

  # system daemon 化済みならこちらは入れない。番人が 2 匹いると、障害時に
  # Wi-Fi の電源 off/on を二重に撃ち、互いの復帰を潰し合う。
  if [[ -f "$daemon_plist" ]]; then
    echo "net-watchdog: system daemon ($daemon_plist) が既に居るので user agent は入れない"
    return 0
  fi

  # log_dir は launchd が StandardErrorPath を open する**前**に要る (無いと
  # ジョブごと spawn 失敗する。network-watchdog.nix の activation コメント参照)。
  mkdir -p "$app_dir" "$log_dir" "${HOME}/Library/LaunchAgents"

  # スクリプト本体は repo への symlink ではなく**コピー**で据える。
  # 番人は dotfiles の作業状態 (rebase 中・checkout 中・clone の移動) から独立に
  # 動き続ける必要があるため。更新は bootstrap.sh の再実行で追従する
  # (plist は毎回このコピーを /bin/bash で起動するので、コピーの差し替えだけで
  # 次の起動から新しい中身が走る。launchctl の入れ直しは不要)。
  if ! cmp -s "$src" "${app_dir}/network-watchdog.sh"; then
    install -m 755 "$src" "${app_dir}/network-watchdog.sh"
    echo "net-watchdog: script updated → ${app_dir}/network-watchdog.sh"
  fi

  # plist は一時ファイルへ生成 → 既設と比較。同一なら触らない (冪等の要)。
  # 値は network-watchdog.nix の launchd.daemons と対にしてある:
  #   StartInterval=30 / RunAtLoad / PATH は同じ (理由・根拠は .nix 側のコメント。
  #   30 を変えるなら .nix と network-watchdog.sh の MAX_BYTES も一緒に直すこと)。
  #   違いは NET_WATCHDOG_DIR と StandardErrorPath だけ — user agent は
  #   /var/log に書けないので ~/Library/Logs 配下へ向ける。
  local tmp
  tmp=$(mktemp)
  cat >"$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${app_dir}/network-watchdog.sh</string>
  </array>
  <key>StartInterval</key><integer>30</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>NET_WATCHDOG_DIR</key><string>${log_dir}</string>
  </dict>
  <key>StandardErrorPath</key><string>${log_dir}/daemon.err</string>
</dict>
</plist>
EOF

  if cmp -s "$tmp" "$agent_plist"; then
    rm -f "$tmp"
    # plist は同一。ロード済みなら何もしない — 動いている番人には触らない。
    if launchctl print "gui/${uid}/${label}" >/dev/null 2>&1; then
      echo "net-watchdog: already installed and loaded (gui/${uid})"
      return 0
    fi
    # plist はあるが未ロード (手で bootout した後など) → ロードだけやり直す
  else
    # plist が変わった (または初回)。launchctl bootstrap は既ロードの label には
    # EALREADY で失敗するので、⛔️ エラーを握り潰すのではなく、変更があったこの
    # 分岐でだけ bootout → bootstrap の入れ直しをする (無変更時は上で return 済み)。
    if launchctl print "gui/${uid}/${label}" >/dev/null 2>&1; then
      launchctl bootout "gui/${uid}/${label}"
      echo "net-watchdog: plist changed; reloading"
    fi
    mv "$tmp" "$agent_plist"
  fi

  launchctl bootstrap "gui/${uid}" "$agent_plist"
  echo "net-watchdog: user agent loaded (gui/${uid}, log: ${log_dir}/samples.jsonl)"
}

if [[ "$WITH_NET_WATCHDOG" == "1" ]]; then
  install_net_watchdog
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "Bootstrap complete!"
echo ""
echo "Next steps:"
echo "  1. Restart your shell (exec zsh)"
echo "  2. To enable full nix management:"
echo "     curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh"
echo "     nix run .#switch"
