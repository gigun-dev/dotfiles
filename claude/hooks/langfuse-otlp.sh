#!/usr/bin/env bash
# Claude Code のセッションを Langfuse へ OTLP トレースとして送るフック。
#
# 設計意図(2026-08-05):
#   - **Ingestion API ではなく OTLP を使う。** 参考記事(tubone 方式)は Langfuse の
#     Ingestion API を直接叩くが、これは公式に deprecated で Cloud v4 で削除される。
#     公式は「今すぐ OpenTelemetry エンドポイントへ移行せよ」と勧告しており、
#     こちらなら Lane A(組み込み OTel メトリクス)と計装の考え方が統一される。
#   - **ID は決定論的に導出する。** hook 入力の prompt_id(ターンごとに安定な UUID)と
#     tool_use_id から md5 で trace/span ID を作るので、ID を持ち回る状態ファイルが要らない
#     (参考記事が「泥臭い」と呼んだファイルベース状態管理の大部分を消せる)。
#     残る状態は開始時刻だけ。
#   - **絶対にセッションを止めない。** 何が起きても exit 0。送信は背景プロセスで投げっぱなし。
#
# データモデル: Session=Claude Code セッション / Trace=1ターン(prompt_id) /
#              root span=ターン / 子 span=ツール実行・サブエージェント。
set -uo pipefail

ENV_FILE="${HOME}/.config/claude-code/langfuse.env"
[ -r "$ENV_FILE" ] || exit 0
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
[ -n "${LANGFUSE_PUBLIC_KEY:-}" ] && [ -n "${LANGFUSE_SECRET_KEY:-}" ] || exit 0

BASE_URL="${LANGFUSE_BASE_URL:-https://cloud.langfuse.com}"
STATE_DIR="${HOME}/.cache/claude-langfuse"
MAX_CHARS=10000  # 巨大なツール出力でペイロードが膨れるのを防ぐ(先頭のみ保持)

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

now_nanos() {
  # macOS の date は %N を持たないので python3 を優先。無ければ秒精度へフォールバック
  # (ツール実行は 1 秒未満が多く、秒精度だと duration が 0 に潰れる)。
  python3 -c 'import time;print(time.time_ns())' 2>/dev/null || echo "$(date +%s)000000000"
}

# md5 から 16進 N 文字を取り出して trace/span ID にする(OTLP は trace=32桁, span=16桁)。
hex_id() { printf '%s' "$1" | md5 -q 2>/dev/null | cut -c1-"$2"; }

get() { jq -r "$1 // empty" <<<"$input" 2>/dev/null; }

event=$(get '.hook_event_name')
session_id=$(get '.session_id')
prompt_id=$(get '.prompt_id')
[ -n "$session_id" ] || exit 0
# prompt_id が無い(最初のユーザー入力より前)イベントは、ターンに紐付かないので送らない。
[ -n "$prompt_id" ] || exit 0

trace_id=$(hex_id "$prompt_id" 32)
root_span_id=$(hex_id "root-$prompt_id" 16)
agent_id=$(get '.agent_id')
# サブエージェント内のツールは、ターンの root ではなくそのエージェントの span にぶら下げる。
if [ -n "$agent_id" ]; then parent_span_id=$(hex_id "agent-$agent_id" 16); else parent_span_id="$root_span_id"; fi

mkdir -p "$STATE_DIR/$session_id" 2>/dev/null || exit 0

# 開始時刻の記録/取り出し。キーが無ければ現在時刻を返す(duration 0 で送るよりマシ)。
mark_start() { now_nanos > "$STATE_DIR/$session_id/$1" 2>/dev/null; }
read_start() {
  local f="$STATE_DIR/$session_id/$1"
  if [ -r "$f" ]; then cat "$f"; rm -f "$f" 2>/dev/null; else now_nanos; fi
}

# OTLP/JSON を組んで背景で POST する。ヘッダの x-langfuse-ingestion-version:4 は
# v4 データモデルで即時反映させるために必須。
send_span() {
  local span_id="$1" parent="$2" name="$3" start="$4" end="$5" obs_type="$6" in_txt="$7" out_txt="$8" level="$9"
  local auth payload
  auth=$(printf '%s:%s' "$LANGFUSE_PUBLIC_KEY" "$LANGFUSE_SECRET_KEY" | base64 | tr -d '\n')

  payload=$(jq -n \
    --arg tid "$trace_id" --arg sid "$span_id" --arg pid "$parent" --arg name "$name" \
    --arg start "$start" --arg end "$end" --arg otype "$obs_type" \
    --arg in "$in_txt" --arg out "$out_txt" --arg sess "$session_id" --arg lvl "$level" \
    --arg agent "${agent_id:-}" '
    def attr(k; v): {key: k, value: {stringValue: v}};
    {resourceSpans: [{
      resource: {attributes: [attr("service.name"; "claude-code")]},
      scopeSpans: [{
        scope: {name: "claude-code-hooks"},
        spans: [{
          traceId: $tid, spanId: $sid,
          parentSpanId: (if $pid == "" then null else $pid end),
          name: $name, kind: 1,
          startTimeUnixNano: $start, endTimeUnixNano: $end,
          attributes: ([
            attr("langfuse.session.id"; $sess),
            attr("langfuse.observation.type"; $otype),
            attr("langfuse.observation.level"; $lvl)
          ]
          + (if $in  != "" then [attr("langfuse.observation.input"; $in)]  else [] end)
          + (if $out != "" then [attr("langfuse.observation.output"; $out)] else [] end)
          + (if $agent != "" then [attr("langfuse.observation.metadata.agent_type"; $agent)] else [] end))
        } | with_entries(select(.value != null))]
      }]
    }]}')

  # 投げっぱなし。応答も失敗も見ない(セッションを1msでも待たせない)。
  curl -s -o /dev/null --max-time 5 -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Basic ${auth}" \
    -H "x-langfuse-ingestion-version: 4" \
    --data-binary "$payload" \
    "${BASE_URL}/api/public/otel/v1/traces" >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

trunc() { jq -r --argjson n "$MAX_CHARS" 'tostring | if length > $n then .[0:$n] + "…(truncated)" else . end' <<<"$1" 2>/dev/null; }

case "$event" in
  UserPromptSubmit)
    mark_start "turn-$prompt_id"
    ;;
  PreToolUse)
    tool_use_id=$(get '.tool_use_id')
    [ -n "$tool_use_id" ] && mark_start "tool-$tool_use_id"
    # サブエージェントの開始時刻は SubagentStart 相当のフックが無いため、そのエージェントが
    # 最初にツールを使った時刻で代用する(これが無いと SubagentStop 側で開始時刻を拾えず、
    # duration 0 の span になる — 実際に Langfuse で「subagent: 0.0s」として現れた)。
    if [ -n "$agent_id" ] && [ ! -e "$STATE_DIR/$session_id/agent-$agent_id" ]; then
      mark_start "agent-$agent_id"
    fi
    ;;
  PostToolUse)
    tool_use_id=$(get '.tool_use_id')
    [ -n "$tool_use_id" ] || exit 0
    start=$(read_start "tool-$tool_use_id")
    tool_name=$(get '.tool_name')
    tool_in=$(jq -c '.tool_input // {}' <<<"$input" 2>/dev/null)
    tool_out=$(get '.tool_response')
    # ツール失敗は Langfuse 側で ERROR として色分けさせる(後で失敗率を集計するため)。
    lvl="DEFAULT"; case "$tool_out" in *"rror"*) lvl="ERROR";; esac
    send_span "$(hex_id "$tool_use_id" 16)" "$parent_span_id" "${tool_name:-tool}" \
      "$start" "$(now_nanos)" "span" "$(trunc "$tool_in")" "$(trunc "$tool_out")" "$lvl"
    ;;
  SubagentStop)
    [ -n "$agent_id" ] || exit 0
    start=$(read_start "agent-$agent_id")
    # agent_type は空で来ることがある(Langfuse 上で "subagent:" とだけ表示され、どの
    # エージェントか分からなくなった)。空なら agent_id の先頭を使って識別可能にする。
    agent_label=$(get '.agent_type')
    [ -n "$agent_label" ] || agent_label=$(printf '%s' "$agent_id" | cut -c1-8)
    send_span "$(hex_id "agent-$agent_id" 16)" "$root_span_id" "subagent:$agent_label" \
      "$start" "$(now_nanos)" "span" "" "$(trunc "$(get '.last_assistant_message')")" "DEFAULT"
    ;;
  Stop)
    start=$(read_start "turn-$prompt_id")
    send_span "$root_span_id" "" "claude-code turn" \
      "$start" "$(now_nanos)" "span" "" "$(trunc "$(get '.last_assistant_message')")" "DEFAULT"
    ;;
esac

exit 0
