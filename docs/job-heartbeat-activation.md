# ジョブ heartbeat 有効化候補の配備前提

この候補は承認済みの3暗号文を含む。mini-vmの宣言はONへ変わるため、
下記のbackend前提が揃うまでmerge・switchしない。既存の即時失敗通知とtimerの周期は変更しない。

1. 承認済みMac担当が既存recipient `all` で3つの暗号文を作成し、同じ候補へ追加した。
   token平文はGitに含めない
   - `secrets/job-heartbeat-autoswitch.age`
   - `secrets/job-heartbeat-fast.age`
   - `secrets/job-heartbeat-slow.age`
2. hubに各sourceの専用credentialを登録し、既存登録を維持したまま
   owner=homelab、destination=bark、monitorControlなしを確認する
3. hubの3 scheduleを登録し、最初の対象枠より前の初期化を確認する。
   UTC daily04:00/daily01:00/Sun02:00、猶予105/135/135分をVMのtimerと再照合する。
   受付登録だけでsenderを先にONにしない
4. 完成した同一commitでNix評価・fmt・build・全fixtureとrequired CIを通す。
   欠けた暗号文のplaceholderや別source tokenで検証を済ませない
5. switch後、標準 `/run/agenix/` のregular-file leafと所有者・0400を値なしで確認する。
   autoswitchはroot:root、fast/slowはgigun:users。新しいtoken本文をログやチャットへ出さない
6. 旧OFF invocationから新ON helperへ切り替えた回は送信しない仕様を維持する。
   正常/差分なし/途絶/復旧・重複防止の受入は次の対象実行で別途記録する。
   hub受付、APNs受付、本人iPhone表示は区別し、既存失敗通知を残す

moduleの既定値はOFFのまま。`nix/tests/job-heartbeat-config.nix` はmodule単体の既定値と、
明示的なpriority overrideによるOFF/ON/不正設定を分けて検証する。
実機設定がONでも、テスト中の欠けた項目が実機設定から補われないようにする。
