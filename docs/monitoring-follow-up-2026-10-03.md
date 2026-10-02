# 障害監視の改善と所有境界（2026-10-03）

## 確認済みの障害

日本時間9/28 22:05の外形監視ではCodex/Langfuseとも200、22:10にともに530、22:15に2回連続失敗としてBarkへPOSTし200で受理。実端末での表示は未確認。Macは10/3 00:14:04起動、VM/Kumaは00:15頃再開。外形監視はCodex00:20、Langfuse00:25にupへ遷移。Macの正確な停止原因は未確定。

KumaはVM内SQLiteをbind mountし保持180日、Beszelもディスク保存。再起動前の記録は残るが同居監視は停止中の記録が欠損し、Kuma画面は100%に見える。外部Workerは5分間隔・2回失敗通知、KVは最新状態のみ上書き。Workers Observabilityから過去のfetch HTTPコードとBark受理を読めた。

## 担当境界

- hub: 外部でのheartbeat/外形観測の受付・判定、永続的な停止/復旧履歴、通知・再通知・監視自体の失敗検知。既存H1/H1bを読んで重複実装を避ける。
- dotfiles: MacとVMの観測元、boot ID/起動時刻/最終成功の送信、設定と秘密管理。hubのWorker/D1をここに再定義しない。
- caldav: Workers Issuesの導入準備、MCP toolの引数/エラー契約。calendar/task serverのRFC/同期課題は既存todoとして別管理。
- swift-mcp-app: UIの論理エラー表示、反復上限span、LLMへ戻す結果と会話ループ。bridge固有の変換はdotfiles側と連携して切り分ける。

## 方針と受け入れ

Mac/VM/公開経路/service health/機能試験の観測を区別。相関できる証拠が不足した原因はunknownとする。構成を増やしすぎず最小実装を先に検証。Mac停止、VMだけ停止、Tunnelだけ障害、serviceだけ障害、health正常だが機能失敗、監視Cron自体の失敗で期待判定と履歴を検証。強制停止はローカルfixtureで先行し、実ホスト停止や本番cutoverは具体的手順を準備してユーザーの承認後。push/main変更はdeployを起動し得るため未承認で行わない。

Workers Issues公式 https://developers.cloudflare.com/workers/observability/issues/ 。Worker例外/失敗/5xx/エラーログを集約する。HTTP200のMCP isErrorは自動検知前提にしない。SDK大量追加やprivate tool引数のログ化は避ける。

Swiftの実端末trace d7a55ab2b23e2df0e3a015f74fb93e91でlist-events-expanded6件がrange=todayと空timeMin/timeMaxを併記し拒否され、最後は-1005。ChatGPT同サーバー比較は予定取得とカード表示成功。短いstreamはloopback/公開URL/Swift URLSession各3件完了、長時間/実端末切断原因は未確定。Swiftには2 known issuesを検出する新規テストがあり、既存dirtyを保護すること。
