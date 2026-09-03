#!/bin/bash
#
# network-watchdog — 常時起動ホスト (mini) の「外に出られない」を証拠ごと残し、
#                    軽い手で自力復帰を試みる番人。
#
# ── なぜ要るか (2026-09-03 の障害) ────────────────────────────────────────
# [実測 2026-09-03 Cloudflare API・mini-vm の journal・mini の統合ログを直接確認]
#   10:02:20 JST に mini (x86_64, macOS 15.7.7) が外部との通信を失い、17:13 に
#   手で再起動するまで 7 時間戻らなかった。分かっているのは「起きなかったこと」の方:
#     - Wi-Fi の切断は起きていない (10:01:30〜10:04:30 に disassoc/deauth/link down が 0 件。
#       09:58 の電波は rssi -47dBm / snr 35 / txRate 1300Mbps / 干渉 0)
#     - スリープしていない (pmset -g custom: sleep 0 / disksleep 0 / autorestart 1)
#     - ルータも回線も生きていた (同じ LAN の別マシンが 7 時間ずっと通信していた)
#     - プロセスも死んでいない (Lima ゲスト mini-vm の cloudflared は 7 時間リトライし続けた。
#       ゲスト側は `lookup ... on 100.100.100.100:53: no such host` と
#       `timeout: no recent network activity`)
#   消去法で残るのは「インタフェースは up・AP との接続も維持したまま、データ経路だけが
#   固まった」。⚠️ ただしこれは直接の証拠を掴めていない説 (統合ログが Bluetooth と AWDL の
#   ノイズに埋もれ、決定的な行が出なかった)。**だからこのスクリプトの 1 番目の仕事は復帰では
#   なく証拠を残すこと。** 復帰は 2 番目。
#
# ── 出力 ────────────────────────────────────────────────────────────────
#   1 行 1 サンプルの JSON Lines ($NET_WATCHDOG_DIR/samples.jsonl)。
#   人が読む散文にしないのは、再発時に「10:02:20 の前後で何が変わったか」を
#   awk/jq で機械的に差分したいため。
#
#   ⭐️⭐️ **`ts` の間隔が StartInterval より空いていたら、その時間は番人が死んでいた。**
#   これは番人が自分の死を残せる唯一の手掛かりで、実際に効いた:
#   [実測 2026-09-03 mini] 19:05:24 の次が 19:08:38 と 3 分空いた。原因は障害ではなく
#   ssh から投げた再起動要求がログインセッションの launchd を壊したことで、
#   最小の試験用ジョブ (15 秒間隔) すら RunAtLoad ごと発火しなくなっていた
#   (= 番人固有ではなく GUI ドメイン全体。手動 kickstart は通った)。再起動で解消。
#   ⛔️ ただし**穴に気づくのは人がこのファイルを見たときだけ**。通知は作っていない
#   (依頼者の裁定: 監視自体が黙って壊れるので、強い推しが無いなら足さない)。
#
# ── 環境変数 (テスト用の縫い目。既定は launchd から使う本番値) ──────────
#   NET_WATCHDOG_DIR         : 出力先ディレクトリ (既定 /var/log/net-watchdog)
#   NET_WATCHDOG_NO_REMEDIATE: 1 なら復帰動作をせず記録だけ (手で 1 回試すとき用)
#
# 注意: macOS 標準の /bin/bash は 3.2。手で叩く場合もそのまま動くよう、
# 連想配列など bash 4 の機能は使わない。

set -euo pipefail

# ── 定数 (発明しない。使うなら根拠を隣に書く) ────────────────────────────

# 出力先。/var/log 配下なのは launchd daemon (root) が書く先として標準だから。
DIR="${NET_WATCHDOG_DIR:-/var/log/net-watchdog}"
LOG="$DIR/samples.jsonl"
STATE="$DIR/state"

# ローテーション上限。1 サンプルの実測長と、launchd の起動間隔から逆算した値。
#   [実測 2026-09-03 mini で 2 サンプル出力して wc -c = 683] 1 行 = 341 バイト (改行込み)。
#   起動間隔 30 秒 (network-watchdog.nix の StartInterval と対) = 2 サンプル/分
#   = 2880 サンプル/日 → 341 B × 2880 = 982 KB/日。
#   16 MiB で 1 世代だけ回すと 16〜32 MiB を保持 = 17〜34 日分。
#   今回の障害が「7 時間」であることを考えると、日単位で数回の再発を跨いで
#   見比べられる長さが要る一方、証拠として遡って意味があるのは月単位まで。
#   ⚠️ 「N 日で消す」という日数を先に決めたのではなく、行サイズ×間隔から MB を
#   計算して 1 か月弱になる上限を選んでいる。行の内容を増やしたらここを計算し直すこと。
MAX_BYTES=16777216 # 16 MiB

# 外への疎通先。DNS 非依存(IP 直打ち)と DNS 依存の両方を、**同じサービス**に対して
# 撃つ。今回の障害ではゲスト側で名前解決も落ちていたので、
# 「経路が死んだ」のか「DNS だけ死んだ」のかを 1 行の中で切り分けられる必要がある。
# 別サービスを 2 つ使うと、片方の障害と自分の障害が混ざって読めなくなる。
EXT_IP="1.1.1.1"
EXT_NAME="one.one.one.one"

# 各プローブの上限時間。[実測 2026-09-03 mini] 到達しない宛先 (198.51.100.1) に対して
#   ping -c 1 -W 1000 -t 2 → 2.1 秒で rc=2
#   nc  -z -G 2 -w 2       → 2.0 秒で rc=1
#   dig +time=2 +tries=1   → 2.2 秒で rc=9
# の 4 本で、最悪 1 サンプル ≒ 8 秒。起動間隔 30 秒はこれより十分大きいので
# サンプル同士が重ならない (launchd の StartInterval は前回の終了を待たない)。

# ── ヘルパ ──────────────────────────────────────────────────────────────

# JSON の文字列値に入る可能性のある値を最低限エスケープする。
# 取り込む値はコマンド出力 (インタフェース名・IP・status 文字列) なので
# " と \ さえ潰せば十分。jq を使わないのは、経路が死んでいる状況で動く前提の
# スクリプトに nix store の依存を増やしたくないため (bash と macOS 標準だけで完結させる)。
jstr() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# ping を 1 発撃って "ok rtt_ms" を返す。失敗時は "0 null"。
# rtt を採るのは、凍る直前に遅延が伸びていたかを後から見たいから
# (今回はサンプルが無く、それすら分からなかった)。
ping_once() {
  out=$(ping -c 1 -W 1000 -t 2 "$1" 2>/dev/null) || {
    printf '0 null'
    return 0
  }
  rtt=$(printf '%s' "$out" | awk -F'/' '/round-trip/ {print $5}')
  [ -n "$rtt" ] || rtt=null
  printf '1 %s' "$rtt"
}

# ── 観測 ────────────────────────────────────────────────────────────────

mkdir -p "$DIR"

TS=$(date +%Y-%m-%dT%H:%M:%S%z)

# 既定経路。⛔️ 192.168.11.1 を焼き込まない: ルータを替えた日に黙って
# 「ゲートウェイに届かない」と誤検知し、Wi-Fi を無意味に落とし続ける番人になる。
route_out=$(route -n get default 2>/dev/null || true)
GW=$(printf '%s' "$route_out" | awk '/gateway:/ {print $2}')
GW_IF=$(printf '%s' "$route_out" | awk '/interface:/ {print $2}')

# Wi-Fi のデバイス名も引く。en1 と決め打ちしないのは同じ理由 (Thunderbolt Ethernet を
# 挿すと番号がずれる)。networksetup の出力は "Hardware Port: Wi-Fi" の次行が Device。
WIFI_IF=$(networksetup -listallhardwareports 2>/dev/null |
  awk '/^Hardware Port: Wi-Fi$/ {getline; print $2}')
[ -n "$WIFI_IF" ] || WIFI_IF="$GW_IF" # Wi-Fi が列挙できない機械では既定経路の口で代用

# リンク状態と IPv4。今回の障害の条件「up で IP も持っているのに届かない」を
# 判定するのに要る 2 つ。
ifc=$(ifconfig "$WIFI_IF" 2>/dev/null || true)
LINK=$(printf '%s' "$ifc" | awk '/status:/ {print $2}')
[ -n "$LINK" ] || LINK="unknown"
IP=$(printf '%s' "$ifc" | awk '/inet /{print $2; exit}')

# パケットカウンタ。「送っているのに返って来ない」のか「送ってすらいない」のかは
# ping の成否だけでは分からない。⛔️ 電波の質 (RSSI/SNR) はここでは採らない:
#   [実測 2026-09-03 mini] system_profiler SPAirPortDataType は 6.8 秒かかり、
#   周囲の AP をスキャンする (= 測定対象の Wi-Fi を自分で乱す) 上に macOS 15 では
#   SSID が <redacted>。wdutil info は root 専用で、非 root では usage を吐くだけ。
#   30 秒ごとに走らせるプローブが観測対象を壊すのは本末転倒なので、
#   スキャンを伴わない netstat のカウンタで代替する。
#   (root で動く launchd daemon なら wdutil info で RSSI が採れる可能性はあるが未検証。
#    採るなら「スキャンを起こさないか」を先に実測すること。)
# 位置パラメータへ流し込んで 6 列を一度に分解する (bash 3.2 なので配列に頼らない)。
counters=$(netstat -I "$WIFI_IF" -b 2>/dev/null | awk '/<Link#/ {print $5, $6, $7, $8, $9, $10; exit}')
# shellcheck disable=SC2086  # 分割させるのが目的
set -- $counters
IPKTS="${1:-null}"
IERRS="${2:-null}"
IBYTES="${3:-null}"
OPKTS="${4:-null}"
OERRS="${5:-null}"
OBYTES="${6:-null}"

# ゲートウェイ = LAN の中は生きているか。
if [ -n "$GW" ]; then
  # shellcheck disable=SC2046  # "ok rtt" の 2 語に分割させるのが目的
  set -- $(ping_once "$GW")
  GW_OK="$1"
  GW_MS="$2"
else
  GW_OK=0
  GW_MS=null # 既定経路そのものが無い = ルーティングテーブルが壊れている
fi

# 外 (DNS 非依存)。ICMP と TCP の両方を撃つ。ICMP だけが落ちる経路もあり、
# 実際に困るのは TCP (cloudflared) の方なので、片方だけでは証拠にならない。
# shellcheck disable=SC2046  # 同上
set -- $(ping_once "$EXT_IP")
EXT_ICMP_OK="$1"
EXT_ICMP_MS="$2"
if nc -z -G 2 -w 2 "$EXT_IP" 443 >/dev/null 2>&1; then EXT_TCP_OK=1; else EXT_TCP_OK=0; fi

# 外 (DNS 依存)。今回はゲスト側で `no such host` も出ていたので、
# 経路の生死と名前解決の生死を別々の列に持つ。@ を指定せず**システムの resolver** を
# 使うのが要点 (mini が実際に使う経路を測る。@8.8.8.8 と書くと DHCP から配られた
# ルータの DNS が死んでいても気づけない)。
# 終了コードではなく**答えが返ったか**を見る: [実測 2026-09-03 mini] dig は NXDOMAIN でも
# rc=0 を返す (存在しない .invalid で確認済み)。A レコードが 1 行も出ないなら失敗とする。
if [ -n "$(dig +time=2 +tries=1 +short "$EXT_NAME" A 2>/dev/null)" ]; then DNS_OK=1; else DNS_OK=0; fi

# ── 判定 ────────────────────────────────────────────────────────────────
#
# ⛔️ 時間の閾値 (N 分落ちたら…) は使わない。使うのは今回の障害の**状態そのもの**:
#   「Wi-Fi は up で IP も持っているのに、ゲートウェイにも外にも届かない」。
# これなら「何分待つのが正解か」という、誰も答えを持っていない数を決めずに済む。
BAD=0
if [ "$LINK" = "active" ] && [ -n "$IP" ] && [ "$GW_OK" = "0" ] &&
  [ "$EXT_ICMP_OK" = "0" ] && [ "$EXT_TCP_OK" = "0" ]; then
  BAD=1
fi
# 注: ルータ自体が落ちた場合もこの条件に入る (LAN も外も届かないので区別できない)。
# その場合 Wi-Fi の入り切りは空振りするが、害は無く、記録には gw_ok=0 が残るので
# 後から読めば区別できる。区別のためにプローブを増やすのは今の目的 (証拠を残す) の外。

# 状態ファイル: "連続 bad 回数 復帰済みフラグ 復帰時刻(epoch)"。
# ⛔️ ここ以外にチューニング用の定数を作らないこと。デバウンスは
# 「連続 2 サンプル」だけ = 単発のパケットロスで暴発しないための最小限。
BADN=0
FIRED=0
FIRED_AT=0
if [ -f "$STATE" ]; then
  # shellcheck disable=SC2046  # 3 語に分割させるのが目的
  set -- $(cat "$STATE")
  BADN="${1:-0}"
  FIRED="${2:-0}"
  FIRED_AT="${3:-0}"
fi

if [ "$BAD" = "1" ]; then
  BADN=$((BADN + 1))
else
  BADN=0
fi

# ── 記録 (先に書く) ─────────────────────────────────────────────────────
# 復帰動作より先にサンプルを書き出す。Wi-Fi を落とした瞬間にこのスクリプトが
# 何かで死んでも、「落とす直前に何が見えていたか」だけは必ず残る。
emit() {
  # ローテーション。上限は先頭の MAX_BYTES のコメント参照。1 世代だけ持つ。
  if [ -f "$LOG" ]; then
    size=$(stat -f%z "$LOG" 2>/dev/null || echo 0)
    if [ "$size" -ge "$MAX_BYTES" ]; then
      mv -f "$LOG" "$LOG.1"
    fi
  fi
  printf '%s\n' "$1" >>"$LOG"
}

SAMPLE=$(printf '{"ts":"%s","ev":"sample","gw":"%s","gw_if":"%s","wifi_if":"%s","link":"%s","ip":"%s",' \
  "$(jstr "$TS")" "$(jstr "$GW")" "$(jstr "$GW_IF")" "$(jstr "$WIFI_IF")" "$(jstr "$LINK")" "$(jstr "$IP")")
SAMPLE="$SAMPLE$(printf '"gw_ok":%s,"gw_ms":%s,"ext_icmp_ok":%s,"ext_icmp_ms":%s,"ext_tcp_ok":%s,"dns_ok":%s,' \
  "$GW_OK" "$GW_MS" "$EXT_ICMP_OK" "$EXT_ICMP_MS" "$EXT_TCP_OK" "$DNS_OK")"
SAMPLE="$SAMPLE$(printf '"ipkts":%s,"ierrs":%s,"ibytes":%s,"opkts":%s,"oerrs":%s,"obytes":%s,' \
  "$IPKTS" "$IERRS" "$IBYTES" "$OPKTS" "$OERRS" "$OBYTES")"
SAMPLE="$SAMPLE$(printf '"bad":%s,"bad_n":%s,"remediated":%s}' "$BAD" "$BADN" "$FIRED")"
emit "$SAMPLE"

# ── 復帰 ────────────────────────────────────────────────────────────────
#
# 発火条件は「連続 2 サンプル bad」かつ「まだ撃っていない」。
# ⛔️ クールダウン秒数のような定数は作らない。代わりに**状態**で 1 回に絞る:
# 一度撃ったら FIRED=1 を立て、健全なサンプルを 1 回でも見るまで再発火しない。
# こうすると「効かなかった場合に 30 秒ごとに Wi-Fi を叩き続ける」を、
# 時間の定数を発明せずに防げる。
#
# ⚠️⚠️ この戻し方 (Wi-Fi の電源 off/on) が実際に効くかは**未検証**。
# 2026-09-03 は再起動で戻したので、これより軽い手で足りるかは分かっていない。
# ⛔️ 再起動はしない (走っている作業を殺す方が高くつく)。
# だからこそ下で「撃った事実」と「撃った後に戻ったか」を必ず記録に残す。
# 次の再発で、効いた/効かなかったを実測で言えるようにするのがこのブロックの目的。
if [ "$BAD" = "1" ] && [ "$BADN" -ge 2 ] && [ "$FIRED" = "0" ] &&
  [ "${NET_WATCHDOG_NO_REMEDIATE:-0}" != "1" ]; then
  rc_off=0
  networksetup -setairportpower "$WIFI_IF" off >/dev/null 2>&1 || rc_off=$?
  # off の直後に on を投げるとドライバが落ち切っていない可能性があるので 1 拍置く。
  # ⛔️ これは復帰までの待ち時間ではない (復帰したかの判定は次のサンプルが行う)。
  sleep 2
  rc_on=0
  networksetup -setairportpower "$WIFI_IF" on >/dev/null 2>&1 || rc_on=$?
  FIRED=1
  FIRED_AT=$(date +%s)
  emit "$(printf '{"ts":"%s","ev":"remediate","action":"wifi_power_cycle","wifi_if":"%s","rc_off":%s,"rc_on":%s,"bad_n":%s}' \
    "$(jstr "$(date +%Y-%m-%dT%H:%M:%S%z)")" "$(jstr "$WIFI_IF")" "$rc_off" "$rc_on" "$BADN")"
fi

# 撃った後に本当に戻ったか。ここが唯一の「効いたか」の実測データになる。
# 戻らなければこの行は永遠に出ない = それ自体が「効かなかった」の証拠。
if [ "$BAD" = "0" ] && [ "$FIRED" = "1" ]; then
  emit "$(printf '{"ts":"%s","ev":"recovered","after_remediation_sec":%s,"gw_ok":%s,"ext_tcp_ok":%s,"dns_ok":%s}' \
    "$(jstr "$TS")" "$(($(date +%s) - FIRED_AT))" "$GW_OK" "$EXT_TCP_OK" "$DNS_OK")"
  FIRED=0
  FIRED_AT=0
fi

printf '%s %s %s\n' "$BADN" "$FIRED" "$FIRED_AT" >"$STATE"
