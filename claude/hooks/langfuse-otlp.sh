#!/usr/bin/env bash
# Claude Code のセッションを Langfuse へ OTLP トレースとして送るフック。
#
# 設計意図(2026-08-05 初版 / 2026-08-08 全面改訂 / 2026-09-26 属性名を中立化):
#   - **Ingestion API ではなく OTLP を使う。** 参考記事(tubone 方式)は Langfuse の
#     Ingestion API を直接叩くが、これは公式に deprecated で Cloud v4 で削除される。
#   - **ID は決定論的に導出する。** prompt_id / tool_use_id / message.id から md5 で
#     trace/span ID を作るので、ID を持ち回る状態ファイルが要らない。
#   - **絶対にセッションを止めない。** 何が起きても exit 0。送信は背景プロセスで投げっぱなし。
#   - **属性名はベンダ固有(`langfuse.*`)ではなく OTel の中立名(`gen_ai.*` / `session.id` /
#     `deployment.environment`)を使う。** このフックが吐くのは OTLP であって Langfuse は
#     現在の送信先にすぎない(`5168106` で Grafana → Langfuse に送信先を差し替えた実績が
#     ある)。ベンダ名で属性を書くと、次に送信先を替えるときに全属性の書き直しが要る。
#     2026-09-26 に実機で確認した対応表は下の「2026-09-26」節を見ること。
#
# データモデル: Session=Claude Code セッション / Trace=1ターン(prompt_id) /
#   root span=ターン / generation=LLM 応答1回 / tool=ツール実行 / agent=サブエージェント。
#
# ---------------------------------------------------------------------------
# 2026-08-08 の実測で確定した事実(推測で書き換えると壊れるので根拠を残す)
# ---------------------------------------------------------------------------
# [Langfuse 側]
#   - ヘッダ `x-langfuse-ingestion-version: 4` は**即時反映のために付ける**。
#     (当初「無いと永久に取り込まれない」と結論したが、これは誤り。実際には遅れて
#      取り込まれる。数十秒後に見たら届いていた。「送った直後に API で確認できない」
#      だけなので、検証時にこれで判断を誤らないこと。)
#   - 一覧 API は trace 自体を `id=t-<traceId>` という疑似 observation として1件返す。
#     span の数を数えるときはこれを除くこと(重複が入ったと誤読しやすい)。
#   - 確認は**単体取得** `/api/public/observations/{id}` を使うこと(2026-09-25 訂正:
#     この単体取得はその後 Langfuse v4 events_only モードで 404 になった。現在の正しい
#     確認手順・落とし穴は telemetry プラグインの `skills/review/scripts/query.sh` 冒頭
#     コメントが正典。あちらは別 repo なのでここでは重複させない)。
#
# ---------------------------------------------------------------------------
# 2026-09-26 の実機検証で確定した事実(`langfuse.*` → 中立名への移行時に全て実測。
# self-host Langfuse v4、environment=`probe-otel-migration` で検証。本番データには
# 一切送っていない — OTLP は再送しても重複するだけで上書きも削除もできないため)
# ---------------------------------------------------------------------------
#   - **observation の種別は `gen_ai.operation.name` の値だけで決まる。**
#     `langfuse.observation.type` 属性は不要(付けても意味を持たない)。
#     実機確認した対応: `chat`(+`gen_ai.request.model`)→ GENERATION /
#     `execute_tool` → TOOL / `invoke_agent` → AGENT / 属性そのものが無い → SPAN。
#     ObservationType の enum 全体(AGENT/TOOL/CHAIN/RETRIEVER/EVALUATOR/EMBEDDING/
#     GUARDRAIL 等)は self-host の `/generated/api/openapi.yml` が正典。
#   - **level / statusMessage は OTel の span `status` から推論される。**
#     `status.code=2`(ERROR)→ level ERROR、`status.code=1`(OK)や `status` 省略 → DEFAULT。
#     `langfuse.observation.level` 属性は不要。成功時は `status` を送らなくてよい
#     (省略しても DEFAULT になることを確認済み。わざわざ code=1 を送るのは無駄)。
#   - **usage は `gen_ai.usage.*` を個別の数値属性として送る。** JSON 文字列にまとめる
#     必要はない(旧 `langfuse.observation.usage_details` はこれだった)。
#     `gen_ai.usage.input_tokens` / `output_tokens` / `cache_read_input_tokens` /
#     `cache_creation_input_tokens` を実機確認。コスト自動計算も同様に効く。
#   - **`session.id` と `user.id` は span 属性でしか拾われない。** resource 属性に置くと
#     Langfuse 側の sessionId/userId が空になることを実機確認した(deployment.environment
#     など他の属性は resource に置いても効くので、これは session/user 固有の制約)。
#     このフックは Stop 時に span を配列へ溜めて一括 POST するバッチ送信なので、公式 SDK の
#     `propagate_attributes()` 相当は要らない — 送信直前の `flush_spans()` で全 span に
#     `session.id` を後付けする 1 箇所で足りる。
#   - **`langfuse.*` 以外の自前属性(例 `claude_code.*`)は resource / span どちらに置いても
#     `metadata` に入り、`filter` の `column=metadata` + `key` で絞り込める。** ただし
#     **key には `attributes.` / `resourceAttributes.` の prefix が必須**(付けないと 1件も
#     ヒットしない。実機で確認するまで自明ではなかった)。
#
# [Claude Code 側 — hook 入力]
#   - PostToolUse は **duration_ms** をくれる。だから開始時刻を PreToolUse で記録して
#     持ち回る必要がない → PreToolUse フックは廃止した(1ツールあたり ~45ms の削減)。
#   - **ツールが失敗すると PostToolUse は発火しない。** 代わりに PostToolUseFailure が飛ぶ。
#     旧実装はこれを購読しておらず、かつ tool_response を "rror" で文字列一致して
#     ERROR 判定していたため、「本物の失敗は 1 件も記録されず、出力に error の語を含む
#     成功だけが ERROR として 489 件」という完全に嘘のデータになっていた(cclens の実測
#     では同期間の実エラーは Bash 60 / Edit 5 件)。→ 失敗はイベントで判定する。
#   - tool_response は**文字列ではなくオブジェクト**({stdout, stderr, interrupted, ...})。
#   - 全イベントが transcript_path をくれる。
#
# [Claude Code 側 — transcript JSONL]
#   - **1回の LLM 応答が複数行に分割される。** thinking ブロックと text ブロックが別行に
#     なり、usage は両方に同じ値が入る。行ごとに generation を作るとトークンを二重計上
#     するので、**message.id で group_by してから 1 generation にまとめる**
#     (実測: assistant 133 行 = 61 応答)。
#   - サブエージェントは別ファイル: <dir>/<session_id>/subagents/agent-<agent_id>.jsonl
#   - stop_reason はメインでは tool_use / end_turn、サブエージェントでは null も出る。
set -uo pipefail

ENV_FILE="${HOME}/.config/claude-code/langfuse.env"
ENDPOINTS_FILE="${HOME}/.config/claude-code/langfuse-endpoints.env"
[ -r "$ENV_FILE" ] || exit 0
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; [ ! -r "$ENDPOINTS_FILE" ] || . "$ENDPOINTS_FILE"; set +a
[ -n "${LANGFUSE_PUBLIC_KEY:-}" ] && [ -n "${LANGFUSE_SECRET_KEY:-}" ] || exit 0
[ -n "${LANGFUSE_OTLP_ENDPOINT:-}" ] || exit 0

STATE_DIR="${HOME}/.cache/claude-langfuse"
MAX_CHARS=10000  # 巨大なツール出力でペイロードが膨れるのを防ぐ(先頭のみ保持)

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

now_nanos() {
  # bash 5 の EPOCHREALTIME(秒.マイクロ秒)を使う。プロセス起動が無いのでほぼ 0ms。
  # macOS の date は %N を持たないので、無い場合だけ python3 → 秒精度と落ちていく
  # (ツール実行は 1 秒未満が多く、秒精度だと duration が 0 に潰れる)。
  # LC_NUMERIC を C に固定するのは、ロケールによって小数点が "," になるため。
  local t
  t=$(LC_NUMERIC=C; echo "${EPOCHREALTIME:-}")
  case "$t" in
    *.*) printf '%s%s000\n' "${t%%.*}" "$(printf '%-6s' "${t#*.}" | tr ' ' '0')" ;;
    *)   python3 -c 'import time;print(time.time_ns())' 2>/dev/null || echo "$(date +%s)000000000" ;;
  esac
}

# md5 から 16進 N 文字を取り出して trace/span ID にする(OTLP は trace=32桁, span=16桁)。
hex_id() { printf '%s' "$1" | md5 -q 2>/dev/null | cut -c1-"$2"; }

get() { jq -r "$1 // empty" <<<"$input" 2>/dev/null; }

# 小さいフィールドは**1回の jq でまとめて**取り出す。フィールドごとに get() を呼ぶと
# jq の起動 20〜30ms が積み上がり、それだけで Stop の所要の半分近くを食っていた。
# @sh でクォートさせているので eval しても安全(値に空白や引用符が入っても壊れない)。
event=""; session_id=""; prompt_id=""; transcript=""; agent_id=""
hf_agent_type=""; hf_tool_use_id=""; hf_tool_name=""; hf_duration_ms=""
eval "$(jq -r '
  def q: (. // "") | tostring | @sh;
  "event=\(.hook_event_name | q) session_id=\(.session_id | q) prompt_id=\(.prompt_id | q) " +
  "transcript=\(.transcript_path | q) agent_id=\(.agent_id | q) hf_agent_type=\(.agent_type | q) " +
  "hf_tool_use_id=\(.tool_use_id | q) hf_tool_name=\(.tool_name | q) hf_duration_ms=\(.duration_ms | q)"
' <<<"$input" 2>/dev/null)"
[ -n "$session_id" ] || exit 0
# prompt_id が無い(最初のユーザー入力より前)イベントは、ターンに紐付かないので送らない。
[ -n "$prompt_id" ] || exit 0

trace_id=$(hex_id "$prompt_id" 32)
root_span_id=$(hex_id "root-$prompt_id" 16)
# サブエージェント内の観測は、ターンの root ではなくそのエージェントの span にぶら下げる。
if [ -n "$agent_id" ]; then parent_span_id=$(hex_id "agent-$agent_id" 16); else parent_span_id="$root_span_id"; fi

mkdir -p "$STATE_DIR/$session_id" 2>/dev/null || exit 0

mark_start() { now_nanos > "$STATE_DIR/$session_id/$1" 2>/dev/null; }
read_start() {
  local f="$STATE_DIR/$session_id/$1"
  if [ -r "$f" ]; then cat "$f"; rm -f "$f" 2>/dev/null; else now_nanos; fi
}

trunc() { jq -r --argjson n "$MAX_CHARS" 'tostring | if length > $n then .[0:$n] + "…(truncated)" else . end' <<<"$1" 2>/dev/null; }

# --- 共通コンテキスト(1 プロセス = 1 イベント分。このプロセス内で作る全 span に対して
#     不変なので、個々の span ではなく flush_spans() の1箇所でまとめて注入する) ----------
#
# environment: 送信先を汚さないための最重要スイッチ。**OTLP は再送しても重複するだけで
# 上書きも削除もできない**ので、検証時は必ず langfuse.env 等で LANGFUSE_ENVIRONMENT を
# 本番と混ざらない値(例 "probe" や "dev")に変えてから試すこと。既定値 "default" は
# 「今まで deployment.environment を送っていなかった」状態と同じ扱いになるよう選んだ
# (2026-09-26 実機確認: 属性を送らないと Langfuse は environment="default" を割り当てる。
# 既存の本番データも全部これに入っている)。つまり既定のままなら**新旧のデータは混ざる**
# — 意図的な選択で、属性名を中立化しただけで環境を分けたいわけではないため。分けたいなら
# 環境変数で上書きする。
environment="${LANGFUSE_ENVIRONMENT:-default}"

# user.id: 2026-09-27 追加。後から足すと「追加した日より前のデータにだけ無い」という
# 非対称が生まれるので、決めるなら早いほうがいい、という利用者の判断で追加した。
# 値は Unix アカウント名(id -un)を既定にする — 個人利用なので「誰が」より「そのアカウント
# は普段どのマシンか」の目印で十分、というだけの弱い意味しか持たせていない。会社アカウント等
# 別名で識別したくなったら LANGFUSE_USER_ID で上書きする。
# session.id と同じく **span 属性でしか拾われない**(2026-09-26 実機確認)ので、
# flush_spans() で session.id と一緒に注入する。
user_id="${LANGFUSE_USER_ID:-$(id -un 2>/dev/null)}"

# host.name: 実行マシンの識別(MacBook / mini-vm / Windows WSL を区別する)。OTel の
# 標準リソース属性名だが、2026-09-26 実機確認で「session.id/user.id 以外の属性は resource に
# 置いても span に置いても同じ metadata に入る」ことを確認済みなので、1回で全 span に効く
# resource 属性として置く(deployment.environment と同じ扱い)。既定はホスト名
# (hostname -s)、環境変数で上書き可能。
host_name="${LANGFUSE_HOST_NAME:-$(hostname -s 2>/dev/null)}"

# cwd は hook 入力の直下にある(transcript を読まなくて良い、全イベント共通)。
cwd=$(get '.cwd')
project=""
[ -n "$cwd" ] && project=$(basename -- "$cwd")

# isSidechain は transcript にもフィールドがあるが、そのために transcript を読むコストを
# 払う必要はない。agent_id の有無がそのまま同じ意味(hook 入力がサブエージェント文脈かどうか)
# であり、既に parent_span_id の分岐に使っている値の使い回しなので追加コストゼロ。
is_sidechain="false"
[ -n "$agent_id" ] && is_sidechain="true"

# gitBranch / version(Claude Code 自体のバージョン)は hook 入力には無く、transcript の
# 行にしか乗っていない(2026-09-26 に実機の transcript で確認: cwd/gitBranch/isSidechain/
# version/uuid/parentUuid は system・assistant 等ほぼ全行に、hook 入力 $input には無い)。
# 最新行だけで十分(この値は1セッション中ほぼ変わらない上、変わっても直近を見るのが正しい)。
git_branch=""; cc_version=""
if [ -n "$transcript" ] && [ -r "$transcript" ]; then
  eval "$(tail -n 1 "$transcript" 2>/dev/null | jq -r '
    def q: (. // "") | tostring | @sh;
    "git_branch=\(.gitBranch | q) cc_version=\(.version | q)"
  ' 2>/dev/null)"
fi

# ターン番号: $STATE_DIR/$session_id にセッション単位の状態を既に持っているので、ここに
# 単調増加カウンタを1個置くだけで済む。**採番する場所は UserPromptSubmit だけ**にする
# (ターンの開始点はここしかない)。他のイベント(PostToolUse 等、同じ prompt_id を持つ)は
# 採番済みの値を読むだけ。
#
# 限界: このカウンタが存在しない状態で prompt_id 付きイベントが来た場合
# (= このフックがまだ無かった頃に始まったセッションを再開した、またはフックが一時的に
# 無効化されていた間に UserPromptSubmit を取りこぼした)は、**推測で番号を振らず空にする**。
# 推測すると欠番や重複が起きて「ターン番号」という前提そのものが信用できなくなるため、
# 「わからない」を空文字列で正直に表すほうが安全という判断。
turn_number=""
if [ "$event" = "UserPromptSubmit" ]; then
  counter_file="$STATE_DIR/$session_id/turn-counter"
  n=0
  [ -r "$counter_file" ] && n=$(cat "$counter_file" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  printf '%s' "$n" > "$counter_file" 2>/dev/null
  printf '%s' "$n" > "$STATE_DIR/$session_id/turn-number-$prompt_id" 2>/dev/null
  turn_number="$n"
elif [ -r "$STATE_DIR/$session_id/turn-number-$prompt_id" ]; then
  turn_number=$(cat "$STATE_DIR/$session_id/turn-number-$prompt_id" 2>/dev/null)
fi

# --- span バッファ -----------------------------------------------------------
# Stop 時は generation が数十件まとまって出るので、1件ずつ POST すると curl を数十回
# 起動することになる。OTLP は spans 配列に複数詰められるので、貯めて 1 リクエストで送る。
SPANS=()

# add_span <span_id> <parent> <name> <start_nanos> <end_nanos> <type> <input> <output> <level>
#
# session.id・deployment.environment・claude_code.* のような「この呼び出しの中では常に
# 同じ値」の属性はここでは付けない。flush_spans() の1箇所でまとめて全 span に注入する
# (二重管理を避けるため。詳細は flush_spans() のコメント)。
add_span() {
  local span_id="$1" parent="$2" name="$3" start="$4" end="$5" otype="$6"
  local in_txt="$7" out_txt="$8" level="$9"
  # observation の種別は gen_ai.operation.name の値だけで決まる(2026-09-26 実機確認、
  # ファイル冒頭の事実一覧を参照)。"span"(ターンの root span)は operation.name を
  # 付けない = SPAN 型になる。
  local op_name=""
  case "$otype" in
    tool)  op_name="execute_tool" ;;
    agent) op_name="invoke_agent" ;;
  esac
  SPANS+=("$(jq -nc \
    --arg tid "$trace_id" --arg sid "$span_id" --arg pid "$parent" --arg name "$name" \
    --arg start "$start" --arg end "$end" --arg otype "$otype" --arg op "$op_name" \
    --arg in "$in_txt" --arg out "$out_txt" --arg lvl "$level" '
    def attr(k; v): {key: k, value: {stringValue: v}};
    {
      traceId: $tid, spanId: $sid,
      parentSpanId: (if $pid == "" then null else $pid end),
      name: $name, kind: 1,
      startTimeUnixNano: $start, endTimeUnixNano: $end,
      attributes: (
        (if $op != "" then [attr("gen_ai.operation.name"; $op)] else [] end)
        # ツールの名前は semconv 的には gen_ai.tool.name の役目($name は既に span の
        # name にも入っているが、name はどの otype でも自由文字列なので別に持たせる)。
        + (if $otype == "tool" then [attr("gen_ai.tool.name"; $name)] else [] end)
        + (if $in  != "" then [attr("gen_ai.prompt"; $in)]      else [] end)
        + (if $out != "" then [attr("gen_ai.completion"; $out)] else [] end)
      ),
      # level/statusMessage は OTel span の status から推論される(2026-09-26 実機確認)。
      # 成功時は status 自体を送らない(未設定でも DEFAULT になることを確認済み)。
      status: (if $lvl == "ERROR" then {code: 2, message: ($name + " failed")} else null end)
    } | with_entries(select(.value != null))')")
}

flush_spans() {
  [ ${#SPANS[@]} -gt 0 ] || return 0
  local auth payload
  auth=$(printf '%s:%s' "$LANGFUSE_PUBLIC_KEY" "$LANGFUSE_SECRET_KEY" | base64 | tr -d '\n')
  # 共通属性の注入はここ1箇所だけ(add_span / emit_generations には一切書かない)。
  # - session.id・user.id は span 属性でしか拾われない(2026-09-26 実機確認)ので、
  #   ここで全 span に後付けする。公式 SDK の propagate_attributes() 相当をここで代替している。
  # - deployment.environment・host.name・claude_code.* は resource 属性に1回置けば
  #   全 span に効く(同じく実機確認)。resource は今回 flush する分(1イベント分)でしか
  #   作らないので、ターンをまたいで値が変わっても混ざらない。
  payload=$(printf '%s\n' "${SPANS[@]}" | jq -sc \
    --arg sess "$session_id" --arg user "$user_id" --arg env "$environment" \
    --arg host "$host_name" \
    --arg cwd "$cwd" --arg project "$project" --arg branch "$git_branch" \
    --arg ccver "$cc_version" --arg side "$is_sidechain" --arg agent "${hf_agent_type:-}" \
    --arg turn "$turn_number" '
    def attr(k; v): {key: k, value: {stringValue: v}};
    def resource_attrs:
      [attr("service.name"; "claude-code"), attr("deployment.environment"; $env),
       attr("claude_code.is_sidechain"; $side)]
      + (if $host    != "" then [attr("host.name"; $host)] else [] end)
      + (if $cwd     != "" then [attr("claude_code.cwd"; $cwd)] else [] end)
      + (if $project != "" then [attr("claude_code.project"; $project)] else [] end)
      + (if $branch  != "" then [attr("claude_code.git_branch"; $branch)] else [] end)
      + (if $ccver   != "" then [attr("claude_code.version"; $ccver)] else [] end)
      + (if $agent   != "" then [attr("claude_code.agent_type"; $agent)] else [] end)
      + (if $turn    != "" then [attr("claude_code.turn_number"; $turn)] else [] end);
    def span_common:
      [attr("session.id"; $sess)] + (if $user != "" then [attr("user.id"; $user)] else [] end);
    {
      resourceSpans: [{
        resource: {attributes: resource_attrs},
        scopeSpans: [{
          scope: {name: "claude-code-hooks"},
          spans: (map(.attributes += span_common))
        }]
      }]
    }' 2>/dev/null)
  [ -n "$payload" ] || return 0
  # 投げっぱなし。応答も失敗も見ない(セッションを1msでも待たせない)。
  # ヘッダ x-langfuse-ingestion-version:4 は v4 データモデルで即時反映させるため。
  curl -s -o /dev/null --max-time 10 -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Basic ${auth}" \
    -H "x-langfuse-ingestion-version: 4" \
    --data-binary "$payload" \
    "$LANGFUSE_OTLP_ENDPOINT" >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# --- transcript → generation -------------------------------------------------
# ここがこのフックの本体。hook イベントだけでは LLM が生成したテキスト・モデル名・
# トークン数が一切取れない(hook は「ツールの前後」しか知らない)ので、transcript の
# JSONL を読んで assistant 応答を generation として復元する。これが無いと Langfuse 上で
# コスト・出力・思考の連鎖がすべて空欄になる。
#
# emit_generations <jsonl パス> <offset キー> <親 span_id> <ターン開始 nanos>
emit_generations() {
  local file="$1" offset_key="$2" parent="$3" fallback_start="$4"
  [ -r "$file" ] || return 0

  local offset_file="$STATE_DIR/$session_id/$offset_key"
  local offset=0
  [ -r "$offset_file" ] && offset=$(cat "$offset_file" 2>/dev/null)
  case "$offset" in ''|*[!0-9]*) offset=0;; esac

  local total
  total=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
  case "$total" in ''|*[!0-9]*) return 0;; esac
  # transcript が短くなった(別セッションの再利用など)ら位置を戻す。
  [ "$offset" -gt "$total" ] && offset=0
  [ "$total" -gt "$offset" ] || return 0

  # 新しく増えた行だけを渡す。前回位置以降 = このターンの応答。
  #
  # ここは jq を**1回だけ**呼んで OTLP span オブジェクトまで完成させる。
  # 初版は generation ごとに jq を6回起動していて、61 応答のターンで Stop に 1.95 秒
  # かかっていた(ターン末にユーザーを待たせる場所なので致命的)。
  local gens
  gens=$(tail -n "+$((offset + 1))" "$file" 2>/dev/null | jq -sc \
    --argjson maxc "$MAX_CHARS" --arg fallback "$fallback_start" \
    --arg tid "$trace_id" --arg pid "$parent" '
    # ISO8601(ミリ秒付き) → UnixNano。jq には ms を含む変換が無いので秒と小数を分けて組む。
    def iso2nanos:
      . as $t
      | (($t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) * 1000000000)
        + ((try ($t | capture("\\.(?<f>[0-9]+)Z$").f) catch "0") + "000000000" | .[0:9] | tonumber);
    def clip: if (. | length) > $maxc then .[0:$maxc] + "…(truncated)" else . end;
    # span ID は 16進16桁。md5 は jq に無いので message.id の末尾8文字を hex 化して作る
    # (先頭は "msg_011Cdo…" と共通なので必ず末尾を使う — 先頭だと全部衝突する)。
    def span_id:
      ("________" + .)[-8:] | explode
      | map(("0123456789abcdef"[(. / 16 | floor) % 16 : (. / 16 | floor) % 16 + 1])
          + ("0123456789abcdef"[. % 16 : . % 16 + 1]))
      | join("") | .[0:16];
    def attr(k; v): {key: k, value: {stringValue: v}};
    # OTLP の int 属性は protobuf int64 の JSON マッピングに合わせて文字列化した値を渡す
    # (2026-09-26 実機確認: 数値そのままでも文字列でも Langfuse 側は同じに解釈するが、
    # 仕様に沿っているのは文字列)。
    def attrInt(k; v): {key: k, value: {intValue: (v | tostring)}};
    def attrArr(k; vs): {key: k, value: {arrayValue: {values: (vs | map({stringValue: .}))}}};

    . as $all
    # generation の開始時刻は「直前に timestamp を持つ行の時刻」= ツール結果が返って
    # きて LLM が考え始めた時刻。ai-title / bridge-session のようなメタ行は timestamp を
    # 持たないので、単純に1つ前の行を見ると時刻が取れず span が潰れる(latency 0 になった)。
    | [range(0; ($all | length)) as $i | $all[$i] + {_i: $i}]
    # model が "<synthetic>" の行は Claude Code が内部生成した疑似メッセージで、
    # 実際の LLM 呼び出しではない。generation として送ると集計に幽霊が出る。
    | map(select(.type == "assistant" and (.message.id // "") != ""
                 and (.message.model // "") != "<synthetic>"))
    | group_by(.message.id)          # ← 1応答が thinking 行と text 行に割れるので束ねる
    | map(
        (map(._i) | min) as $first
        | {
            mid:   .[0].message.id,
            model: (.[0].message.model // ""),
            usage: (.[0].message.usage // {}),   # 分割された行の usage は同値なので 1 つだけ採る
            sr:    ((.[-1].message.stop_reason // "null") | tostring),
            start: ([$all[0:$first][] | select(.timestamp != null) | .timestamp] | last // ""),
            end:   (map(.timestamp) | max),
            out:   ([.[] | .message.content[]? |
                      if   .type == "thinking" then "[thinking] " + (.thinking // "")
                      elif .type == "text"     then (.text // "")
                      elif .type == "tool_use" then "[tool_use] " + (.name // "?") + " " + ((.input // {}) | tostring)
                      else empty end] | join("\n\n"))
          })
      | sort_by(.end)
      | map(
          (.end | iso2nanos) as $en
          | (if .start != "" then (.start | iso2nanos) else ($fallback | tonumber) end) as $st0
          # 開始が終了を追い越していたら潰れた span になるので、終了に寄せる。
          | (if $st0 > $en then $en else $st0 end) as $st
          | {
              traceId: $tid, spanId: (.mid | span_id),
              parentSpanId: (if $pid == "" then null else $pid end),
              name: ("assistant (" + .sr + ")"), kind: 1,
              startTimeUnixNano: ($st | tostring), endTimeUnixNano: ($en | tostring),
              # gen_ai.operation.name=chat + gen_ai.request.model の組で Langfuse は
              # observation type を GENERATION と判定する(2026-09-26 実機確認)。
              # session.id / deployment.environment / claude_code.* はここでは付けない
              # (flush_spans() の1箇所で全 span に後付けする)。
              attributes: (
                [attr("gen_ai.operation.name"; "chat")]
                + [attr("gen_ai.completion"; (.out | clip))]
                + [attrArr("gen_ai.response.finish_reasons"; [.sr])]
                + (if .model != "" then [attr("gen_ai.request.model"; .model)] else [] end)
                # usage は個別の数値属性で渡す(旧実装は JSON 文字列にまとめていたが、
                # gen_ai.usage.* を素の数値で渡すだけで同じくコスト自動計算まで効くことを
                # 2026-09-26 に実機確認した)。キャッシュ系は 0 なら送らない
                # (0 のキーがあると価格表に無いキーとして無駄に costDetails へ出る、旧実装から
                # 引き継いだ理由)。
                + [attrInt("gen_ai.usage.input_tokens"; (.usage.input_tokens // 0))]
                + [attrInt("gen_ai.usage.output_tokens"; (.usage.output_tokens // 0))]
                + (if (.usage.cache_read_input_tokens // 0) > 0
                   then [attrInt("gen_ai.usage.cache_read_input_tokens"; .usage.cache_read_input_tokens)]
                   else [] end)
                + (if (.usage.cache_creation_input_tokens // 0) > 0
                   then [attrInt("gen_ai.usage.cache_creation_input_tokens"; .usage.cache_creation_input_tokens)]
                   else [] end)
              )
            })
      | .[]' 2>/dev/null)

  # jq が完成品の span を1行1件で吐くので、バッファに積むだけ。
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    SPANS+=("$line")
  done <<<"$gens"

  printf '%s' "$total" > "$offset_file" 2>/dev/null
}

# ツール span を組む。PostToolUse(成功) と PostToolUseFailure(失敗) の唯一の違いは level。
emit_tool_span() {
  local level="$1"
  local tool_in tool_out dur end start
  [ -n "$hf_tool_use_id" ] || return 0
  # 入出力は大きいので一括取得には混ぜず、ここで 1 回の jq にまとめて切り出す
  # (失敗イベントでは tool_response が無いことがあるので error / message も拾う)。
  tool_in=$(jq -c '.tool_input // {}' <<<"$input" 2>/dev/null)
  tool_out=$(jq -c '.tool_response // .error // .message // {}' <<<"$input" 2>/dev/null)
  # duration_ms は Claude Code がくれる。これがあるので PreToolUse で開始時刻を
  # 記録する必要がない(旧実装はそのために 1 ツールあたり 45ms 余計に払っていた)。
  dur="$hf_duration_ms"
  case "$dur" in ''|*[!0-9]*) dur=0;; esac
  end=$(now_nanos)
  start=$((end - dur * 1000000))
  add_span "$(hex_id "$hf_tool_use_id" 16)" "$parent_span_id" "${hf_tool_name:-tool}" \
    "$start" "$end" "tool" "$(trunc "$tool_in")" "$(trunc "$tool_out")" "$level"
}

case "$event" in
  UserPromptSubmit)
    mark_start "turn-$prompt_id"
    # ターンの root span に載せるユーザー入力。Stop 時には hook 入力から取れないので保存する。
    get '.prompt' > "$STATE_DIR/$session_id/prompt-$prompt_id" 2>/dev/null
    ;;

  PostToolUse)
    emit_tool_span "DEFAULT"
    ;;

  PostToolUseFailure)
    # 旧実装が購読しておらず、本物の失敗がまるごと欠落していた経路。
    emit_tool_span "ERROR"
    ;;

  SubagentStop)
    [ -n "$agent_id" ] || exit 0
    # サブエージェントの transcript は本体とは別ファイル。開始時刻もそこから取れるので、
    # 旧実装のように PreToolUse で開始を記録しておく必要がない
    # (あの方式は SubagentStop が来なかった回の状態ファイルが残留し、次の回で何十時間も
    #  前の開始時刻を拾って duration が 33 時間になる、という壊れ方をしていた)。
    sub_file=""
    if [ -n "$transcript" ]; then
      sub_file="$(dirname "$transcript")/$session_id/subagents/agent-$agent_id.jsonl"
    fi
    start=""
    if [ -r "$sub_file" ]; then
      start=$(head -n 1 "$sub_file" 2>/dev/null | jq -r '
        if (.timestamp // "") != "" then
          ((.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) * 1000000000)
          + ((try (.timestamp | capture("\\.(?<f>[0-9]+)Z$").f) catch "0") + "000000000" | .[0:9] | tonumber)
        else empty end' 2>/dev/null)
    fi
    [ -n "$start" ] || start=$(read_start "agent-$agent_id")
    end=$(now_nanos)

    agent_label="$hf_agent_type"
    [ -n "$agent_label" ] || agent_label="${agent_id:0:8}"
    add_span "$(hex_id "agent-$agent_id" 16)" "$root_span_id" "subagent:$agent_label" \
      "$start" "$end" "agent" "" "$(trunc "$(get '.last_assistant_message')")" "DEFAULT"

    # サブエージェント内の LLM 応答も generation として復元し、agent span にぶら下げる。
    emit_generations "$sub_file" "gen-offset-agent-$agent_id" \
      "$(hex_id "agent-$agent_id" 16)" "$start"
    ;;

  Stop)
    start=$(read_start "turn-$prompt_id")
    end=$(now_nanos)
    prompt_file="$STATE_DIR/$session_id/prompt-$prompt_id"
    user_prompt=""
    [ -r "$prompt_file" ] && { user_prompt=$(cat "$prompt_file" 2>/dev/null); rm -f "$prompt_file" 2>/dev/null; }
    add_span "$root_span_id" "" "claude-code turn" \
      "$start" "$end" "span" "$(trunc "$user_prompt")" "$(trunc "$(get '.last_assistant_message')")" "DEFAULT"

    emit_generations "$transcript" "gen-offset" "$root_span_id" "$start"

    # 古い状態ファイルの掃除。ターンが Stop を迎えずに終わる(中断・クラッシュ・
    # セッション放棄)と turn-*/prompt-* が消えずに残る。実際 ~/.cache に数日分の
    # 残骸が溜まっていた。Stop は 1 ターンに 1 回しか来ないので、ここでやるのが安い。
    # ただし gen-offset* は消さない。消すと transcript の読み込み位置が 0 に戻り、
    # 1日以上あけて再開したセッションで過去の応答を丸ごと再送してしまう
    # (span_id は決定論的なので重複はしないが、古い応答が新しいターンの trace に混ざる)。
    # turn-counter も同じ理由で除外する。消すとターン番号が 1 から振り直され、
    # 同じセッション内で番号が重複する(1日以上黙っていたセッションの再開で起きる)。
    find "$STATE_DIR" -type f -mtime +1 ! -name 'gen-offset*' ! -name 'turn-counter' -delete 2>/dev/null
    find "$STATE_DIR" -type d -empty -delete 2>/dev/null
    ;;
esac

flush_spans
exit 0
