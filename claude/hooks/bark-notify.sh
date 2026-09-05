#!/bin/bash
# Claude Code の Notification フックから Bark (iOS) へプッシュを飛ばす。
#
# 秘密は agenix (secrets/bark-env.age) にあり、ここで実行時に復号する。NixOS と違い
# macOS には agenix モジュールを入れていないため、tofu ラッパ (flake.nix) と同じ
# 「その場で復号して変数へ入れ、ファイルに落とさない」方式を採る。
#
# 2026-09-05 に macOS Keychain から移した。Keychain 版は設定手順がどこにも記録されて
# おらず、M4 Pro を失うと復旧できなかった。
#
# 前提が欠けていたら黙って exit 0 する。通知は補助機能なので、鍵が無い環境や
# 復号できない状況で Claude Code の動作を妨げない。
set -u

SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")
REPO=$(cd "$(dirname "$SELF")/../.." 2>/dev/null && pwd) || exit 0
SECRET="$REPO/secrets/bark-env.age"
IDENTITY="$HOME/.ssh/id_ed25519"

[ -r "$SECRET" ] || exit 0
[ -r "$IDENTITY" ] || exit 0
command -v age >/dev/null 2>&1 || exit 0

# コマンド置換で受ける。`< <(age ...)` だと復号失敗でも空を読んで素通りするため。
ENV_CONTENT=$(age -d -i "$IDENTITY" "$SECRET" 2>/dev/null) || exit 0

BARK_KEY=""
ENCRYPT_KEY=""
ENCRYPT_IV=""
while IFS='=' read -r k v; do
  case "$k" in
    BARK_DEVICE_KEY) BARK_KEY=$v ;;
    BARK_ENCRYPT_KEY) ENCRYPT_KEY=$v ;;
    BARK_ENCRYPT_IV) ENCRYPT_IV=$v ;;
  esac
done <<< "$ENV_CONTENT"

[ -n "$BARK_KEY" ] && [ -n "$ENCRYPT_KEY" ] && [ -n "$ENCRYPT_IV" ] || exit 0

INPUT=$(cat)

{
  read -r TITLE
  read -r MESSAGE
  read -r CWD
  read -r TRANSCRIPT
} < <(jq -r '(.title // "Claude Code"), (.message // "Waiting for input"), (.cwd // ""), (.transcript_path // "")' <<< "$INPUT")

PROJECT=$(basename "$CWD")

# セッション URL が取れないものは通知しない (タップしても戻る先が無いため)
BARK_URL=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  BARK_URL=$(jq -r 'select(.url) | .url | select(test("claude\\.ai/code/session_"))' "$TRANSCRIPT" 2>/dev/null | tail -1)
fi
[ -z "$BARK_URL" ] && exit 0

PAYLOAD=$(jq -n \
  --arg title "${TITLE} [${PROJECT}]" \
  --arg body "$MESSAGE" \
  --arg url "$BARK_URL" \
  --arg group "$PROJECT" \
  --arg level "timeSensitive" \
  '{title: $title, body: $body, url: $url, group: $group, level: $level}')

KEY_HEX=$(printf '%s' "$ENCRYPT_KEY" | xxd -ps -c 200)
IV_HEX=$(printf '%s' "$ENCRYPT_IV" | xxd -ps -c 200)

CIPHERTEXT=$(printf '%s' "$PAYLOAD" | openssl enc -aes-256-cbc -K "$KEY_HEX" -iv "$IV_HEX" -base64 -A)

curl -s \
  --data-urlencode "ciphertext=${CIPHERTEXT}" \
  --data-urlencode "iv=${ENCRYPT_IV}" \
  "https://api.day.app/${BARK_KEY}" &
