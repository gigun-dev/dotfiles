# 通知の現行運用

所有境界は [ADR 0004](adr/0004-send-notifications-through-hub-instead-of-a-dotfiles-worker.md)。
配信・監視履歴・再試行はhub、通知元と資格情報はdotfilesが持つ。

mini-vmの失敗通知とClaude hookは `secrets/bark-env.age` の `BARK_PUSH_URL` にある
hub H0へ送り、既存のAES暗号化を維持する。[mini-vm運用](mini-vm.md)を参照。
HTTP成功とJSONの受付成功、APNs受付、本人端末での表示は別の検証である。

Mac/VMの生存報告と公開Codex・Langfuseの検査、停止・復旧履歴と通知は配備済み。
通信形式とsender運用は [host-heartbeat.md](host-heartbeat.md)、監視・配送の現在地は
[hubの運用記録](../../hub/docs/uptime-current-operation-2026-10-03.md)を参照。

`dotfiles-autoswitch`・`dotfiles-lock-propose@fast`・`@slow` のジョブ成功heartbeatは
未配備で、`todo.txt` の0005に残る。ホストの生存報告だけではtimerの不発を検知できない。
正常終了（差分なしを含む）・途絶・復旧・計画停止・二重配信防止の確認が必要である。


## ジョブ成功 heartbeat の準備（todo0005、既定OFF）

`scripts/job-heartbeat.py` はhub H1b用の3系統共通sender。開始時にUTC予定枠とrunIdを固定し、
同じreceiptを成功時の再試行にも使う。現在のNix呼出しは `--enabled`・送信先・token fileを
渡さないため、送信時に秘密を読まずHTTP通信もしない。環境変数で有効化する口はない。
既存の失敗通知、H0/Bark経路、timerの時刻は変更していない。

有効化前のtransport互換性を揃えるため、3ジョブ共通senderはhub CI callerと同じ標準curlを使う。
同じhubドメインのCI送信でurllibが拒否された事例を踏まえた準備であり、ジョブ用 `/heartbeat`
が本番で拒否されたと確認したものではない。生存heartbeat senderはこの変更の対象外。
Nix wrapperは選択世代のcurl絶対パスとCA bundleを固定し、旧coordinatorのPATHに依存しない。
curl 8.4以上、curlrc無効、HTTPS限定・証明書検証・redirect/proxy不使用とし、UAは偽装しない。
Bearerと本文はstdinだけに渡し、接続/全転送10秒・子process15秒・最大3回・応答4KiBで制限する。
202とJSON受付成功の両方を確認し、403やTLS検証失敗に別transportで再挑戦しない。
OFF時はtoken読取だけでなくcurlのversion照会・起動も行わない。

- autoswitchは固定revisionのsystem・home・health gateと最終世代照合の後だけ送信候補になる。
  coordinatorの同一invocationから新世代helperへ開始receiptを渡す。rollback後のgate成功は
  更新成功として扱わず、旧coordinatorからの移行でreceiptが無い実行も送らない
- lock-fast/slowは差分なし、または両build・push・PR更新・auto-merge設定の成功で送信候補になる。
  GitHub CI/merge完了やsystemへの適用完了は意味しない
- sender失敗はjournalに秘密を含まない固定文を残す。正常な適用をrollbackしたり、
  既存OnFailure経路で重ねて通知したりせず、将来有効化するhub側の欠測判定に任せる

有効化前に必要な判断と受入:

1. 3 source専用credentialの既存有無を値を表示せず照合する。生存用mac/mini-vm tokenは
   流用しない。未存在なら発行・hub登録・agenix配置を承認後に行う。通常senderに
   monitorControlを付けず、計画停止は別管理credentialで扱う
2. OnCalendarは現在TZ明記なし。公開宣言から実機managerのUTC設定を確証できないため、
   この準備では周期を変えない。有効化前にUTCを照合し、hubの候補（毎日04:00/01:00、
   日曜02:00、猶予105/135/135分）と一致させる
3. hubのUPTIME_JOB_SCHEDULESは別途承認して登録し、最初の対象枠より前にD1初期化を確認する。
   本senderは開始時点の直近UTC枠を選ぶ。Persistent追いつき実行と手動実行の扱いも照合する
4. 既存の即時失敗通知を残すか、受入後にH1bへ一本化するかを決める。旧通知との相関を
   決めないまま両方を有効にして二重配信防止済みとは扱わない
5. 正常/差分なし/途絶/復旧、pause/resume/期限自動再開、再送重複防止を確認する。
   hub受付・H0/APNs受付・本人iPhone表示は分けて記録し、実機強制停止を試験に使わない

合成試験は `scripts/tests/job-heartbeat.py`、`lock-propose-heartbeat.py` と既存
`dotfiles-autoswitch.py`。外部HTTPはfake transportのみ。Nixの共通checkにも登録する。
合成試験は実systemd activation、Nix評価/ビルド、自然timer、実通知の受入を代替しない。
