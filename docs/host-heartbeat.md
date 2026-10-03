# Mac / VM heartbeat の運用

host は boot とローカルの証拠を採取し、hub が停止範囲の判定・D1 履歴・通知を所有する。
入口は `https://hub-monitor.097969.xyz/uptime/heartbeat`。Mac=`mac`、VM=`mini-vm` は別 Bearer。
詳細本文は `source/observedAt/bootId/bootedAt/lastSuccessAt/tunnel/service/functional` の8項目だけ。
H1b ジョブ成功用 `/heartbeat` とは別の契約である。

VM の root system service は起動後15秒、以降60秒ごと。宣言は `services.host-heartbeat`、
秘密は root:0400 の `/run/agenix/host-heartbeat-vm`、snapshot は root:0600 の
`/var/lib/host-heartbeat/latest.json`。現在の配備・受付根拠は
[`host-heartbeat-acceptance.json`](host-heartbeat-acceptance.json)。
Mac は凍結 Intel mini の System LaunchDaemon を使い、user agent へ置き換えない。

## 観測と受付

Linux `/proc`、macOS `sysctl` で boot ID と起動時刻を採取する。`lastSuccessAt` はローカル
採取完了を表し、hub 受付や会話機能の成功を意味しない。Mac のローカル check は `unknown`。
VM は cloudflared の unit と固定 loopback `127.0.0.1:20241/ready` を読む。
unit active だけでは成功にしない。ready HTTP200 と JSON `readyConnections > 0` で `tunnel=ok`、
接続0・HTTP503 は `failed`、収集エラー・不正な応答は `unknown`。
[稼働版の実装](https://github.com/cloudflare/cloudflared/blob/2026.9.3/metrics/readiness.go)に従い、
公式の [`TUNNEL_METRICS`](https://developers.cloudflare.com/tunnel/reference/run-parameters/#metrics)で
loopback を固定する。origin の動作をこの接続数から推定しない。

Codex localhost `18080/healthz` HTTP200 と、Langfuse localhost
`3000/api/public/health?failIfDatabaseUnavailable=true` JSON `status=OK` の両方で `service=ok`。
片側の失敗は `failed`、不明な証拠は `unknown`。推論・会話を試していない `functional` は
`unknown` を保つ。詳細 `localChecks` は private snapshot だけに置く。

送信は専用 User-Agent、TLS、redirect 禁止、10秒 timeout・最大3回。
HTTP202 と JSON `status=accepted` の両方でだけローカル `lastAcceptedAt` を更新する。
新規観測ごとに時刻を作り、通信再送は同じ本文・時刻を使う。失敗でも最新観測を atomic replace し、
前回の受付時刻を保持する。HTTP200/HTML、サービス終了0、boot 採取だけを受付成功にしない。
202 は保存の受付であり、Bark/API 配送や端末表示とは別の証拠である。

## Mac の配置と確認

`scripts/host-heartbeat-launchd.py` は frozen host 用 plist を生成する。
`scripts/install-host-heartbeat-mac.sh` は同じ private staging にある `host-heartbeat.py`、
`daemon.plist`、`token` を一度の sudo で配置する。staging は0700、token は0400。
既存 managed install があれば root 専用 backup を残す。source を
`/usr/local/lib/dotfiles-heartbeat/scripts/`、token を `/var/lib/host-heartbeat/token`、plist を
`/Library/LaunchDaemons/dev.gigun.host-heartbeat.plist` へ配置する。
RunAtLoad の新しい受付を最大60秒確認し、成功後 staging token を削除する。
秘密の本文や値を引数・ログへ出さず、本人には OS 認証だけを依頼する。

配置後は `sudo launchctl print system/dev.gigun.host-heartbeat` と root 専用 snapshot を読み、
60秒の自然実行で `observedAt/lastAcceptedAt` が更新されることを確認する。
VM は `systemctl status host-heartbeat.service host-heartbeat.timer` と同じ snapshot を使う。
error log は Mac の `/var/lib/host-heartbeat/error.log`、VM は journal。例外の秘密や応答本文は出さない。

## 秘密と復旧

`secrets/host-heartbeat-mac.age` / `host-heartbeat-vm.age` は独立した source token。
互いの host key を受信者に含めず、管理・backup 受信者だけを共有する。平文は runtime private file に
置き、Nix store・Git・環境変数・コマンド引数へ入れない。hub 登録更新は
`scripts/prepare-host-heartbeat-registration.py` で既存 owner・配送先を引き継ぎ、他 source と管理権限を
保持する。送信 source に monitorControl を付与しない。rotate は hub 登録と各 runtime file を揃える。

送信だけを止める場合、VM は timer を停止して宣言を `enable=false` に戻す。
Mac は `sudo launchctl bootout system/dev.gigun.host-heartbeat` と追加 plist の退避。
旧 H1b へ8項目を送らず、D1・履歴を削除しない。OS 世代を戻す際は Langfuse の DB と image の
整合を先に守り、[mini-vm の運用](mini-vm.md)に従う。
計画停止の通知抑制は hub の現行契約で確認し、H1b control を流用しない。
本番 Mac/VM の強制停止を受け入れ試験に使わない。

## SSH 経路の補助観測

M4 の `dev.gigun.ssh-path-observe` LaunchAgent がログイン中に60秒ごとに採取する。
実行ファイルは `~/.local/lib/dotfiles/ssh-path-observe.py`、private 状態は
`~/.local/state/dotfiles/ssh-path/` の `latest.json` と `events.jsonl`（0600）。
履歴は直近1440件に制限し、UTC の採取開始・完了時刻、経路別結果、所要時間、exit code、
boot ID のみを保存する。stdout/stderr・鍵・例外本文は保存しない。

直接 mini-vm を最大25秒、失敗・不明時だけ mini→Lima を最大25秒で読む。
接続拒否は `connection_refused`、SSH の接続 timeout と全体 deadline は `timeout` と区別する。
正常時は直接接続1回で終了する。M4 の sleep/logout 中は採取が止まるため、Mac/VM の
system heartbeat と併せて見る。hub の VM boot ID・観測時刻・履歴へ照合できるが、
両 SSH 経路の失敗だけで VM 停止や過去の障害原因を確定しない。

配備時は `--snapshot` と `--history` の絶対パスを指定した `--render-launchd` の出力を
`~/Library/LaunchAgents/dev.gigun.ssh-path-observe.plist` に置き、`launchctl bootstrap gui/$(id -u)`
で読み込む。補助採取だけを止める場合は
`launchctl bootout gui/$(id -u)/dev.gigun.ssh-path-observe` を使う。

隔離検証は `scripts/tests/host-heartbeat.py`、`host-heartbeat-registration.py`、`ssh-path-observe.py` と
`scripts/tests/host-heartbeat-hub.mjs`。共通 `scripts/verify.sh` で Nix fixture build と fmt を確認する。
