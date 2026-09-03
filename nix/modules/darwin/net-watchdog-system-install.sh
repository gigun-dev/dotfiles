#!/bin/bash
#
# net-watchdog-system-install — 番人 (network-watchdog) を user agent から
# system daemon へ昇格させる。凍結ホスト (mini) で **sudo を 1 回**打つ用:
#
#   sudo bash nix/modules/darwin/net-watchdog-system-install.sh
#
# ── なぜこのスクリプトが要るか ──────────────────────────────────────────
# bootstrap.sh --net-watchdog は sudo 無しで届く user agent として番人を入れる。
# その弱点は「OS 起動から自動ログインまでの数秒は走らない」こと
# ([実測 2026-09-03 mini] autoLoginUser=gigun / FileVault Off。自動ログイン後に
# agent が上がるはず(未検証))。この窓を消すには root の launchd daemon が要り、
# 設置には sudo が要る。エージェント経由の手当てではパスワードを扱えないため、
# ここだけ人が打つ 1 コマンドに切り出してある。
#
# nix 管理下の機械 (mini を M チップに替えた日) では network-watchdog.nix が
# 同じ内容の daemon (label は org.nixos.network-watchdog) を作るので、これは不要。
# ⚠️ その日が来たら、この手当て分 (dev.gigun.net-watchdog) は label が違うので
# darwin-rebuild では消えない。手で bootout + rm すること (番人 2 匹は Wi-Fi の
# 電源 off/on を二重に撃つ)。
#
# ── user agent からの変更点 ────────────────────────────────────────────
#   - 出力先: ~/Library/Logs/net-watchdog → /var/log/net-watchdog
#     (network-watchdog.sh の既定。root が書く先として標準の /var/log に戻す)。
#     ⚠️ 過去の samples.jsonl は ~/Library/Logs 側に残したまま**消さない**
#     (障害の証拠。読むときは両方の置き場を見ること)。
#   - スクリプトのコピー先: ~/Library/Application Support → /Library/Application Support
#     (user が書ける場所に root の daemon の実体を置くと、sudo 無しで daemon の
#     中身を差し替えられてしまう。root 所有の場所へ移すのは権限の一貫性のため)
#   - user agent は bootout して plist も消す (二重発火の防止。上の ⚠️ と同じ理由)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "root が要る。sudo bash $0 で実行すること" >&2
  exit 1
fi

# sudo 経由なら SUDO_USER に元のユーザーが入る。user agent の掃除に使う。
# 直接 root ログインで走らせた場合 (SUDO_USER 無し) は agent の掃除だけスキップ。
SUDO_USER="${SUDO_USER:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${SCRIPT_DIR}/network-watchdog.sh"
LABEL="dev.gigun.net-watchdog"
APP_DIR="/Library/Application Support/net-watchdog"
LOG_DIR="/var/log/net-watchdog"
DAEMON_PLIST="/Library/LaunchDaemons/${LABEL}.plist"

[[ -f "$SRC" ]] || {
  echo "$SRC が無い。dotfiles の checkout から実行すること" >&2
  exit 1
}

# LOG_DIR は launchd が StandardErrorPath を open する**前**に要る
# (network-watchdog.nix の activation コメントと同じ理由)。
mkdir -p "$APP_DIR" "$LOG_DIR"
install -m 755 -o root -g wheel "$SRC" "${APP_DIR}/network-watchdog.sh"

# plist の中身は bootstrap.sh の user agent 版と対。違いは上の「変更点」のとおり
# NET_WATCHDOG_DIR を渡さない (スクリプト既定の /var/log/net-watchdog を使う) ことと
# StandardErrorPath だけ。StartInterval=30 / PATH の根拠は network-watchdog.nix 参照。
cat >"$DAEMON_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${APP_DIR}/network-watchdog.sh</string>
  </array>
  <key>StartInterval</key><integer>30</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardErrorPath</key><string>${LOG_DIR}/daemon.err</string>
</dict>
</plist>
EOF
# LaunchDaemons の plist は root:wheel / 644 でないと launchd が拒否する
chown root:wheel "$DAEMON_PLIST"
chmod 644 "$DAEMON_PLIST"

# ── user agent を降ろす ──
# daemon を bootstrap する**前**に降ろす: 一瞬でも 2 匹並走させない
# (両方が同じ障害を観測すると Wi-Fi の電源 off/on を二重に撃ち合う)。
# 監視の空白は最大 StartInterval の 30 秒だけで、7 時間級の障害を相手にする
# 番人にとっては無視できる。agent の plist とスクリプトのコピーも消すのは、
# bootstrap.sh の「daemon_plist があれば agent は入れない」ガードと突き合わせて
# 「daemon が正・agent の残骸なし」という 1 つの状態に収束させるため。
if [[ -n "$SUDO_USER" ]]; then
  uid=$(id -u "$SUDO_USER")
  user_home=$(dscl . -read "/Users/${SUDO_USER}" NFSHomeDirectory | awk '{print $2}')
  if launchctl print "gui/${uid}/${LABEL}" >/dev/null 2>&1; then
    launchctl bootout "gui/${uid}/${LABEL}"
    echo "user agent (gui/${uid}) を降ろした"
  fi
  rm -f "${user_home}/Library/LaunchAgents/${LABEL}.plist"
  rm -rf "${user_home}/Library/Application Support/net-watchdog"
  # ⚠️ ~/Library/Logs/net-watchdog は消さない (過去の証拠)
fi

# 再実行にも耐える: 既にロード済みなら一度降ろしてから入れ直す
# (launchctl bootstrap は既ロードの label に EALREADY で失敗するため)
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "system/${LABEL}"
fi
launchctl bootstrap system "$DAEMON_PLIST"

echo "system daemon loaded: system/${LABEL}"
echo "log: ${LOG_DIR}/samples.jsonl (旧ログは ~/Library/Logs/net-watchdog に残置)"
