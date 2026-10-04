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
