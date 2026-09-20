Superseded by 0009-protect-monitoring-uis

# mini-vmの可観測性はBeszelと外形監視に分ける

Date: 2026-09-20

mini-vm内の資源・コンテナ履歴と、mini-vm自体が落ちた場合にも必要な死活検知は障害領域が異なる。ホストとLangfuseコンテナのCPU・RAM・ディスク・ネットワーク・温度・履歴・閾値アラートはloopback限定のBeszelで確認し、LangfuseとCodex Proxyの外形監視はmini-vm外のCloudflare Worker Cronから行う。公開ステータスページは通知運用で必要性が確認できるまで作らず、Netdata UIの別配信やR2公開バケットも採用しない。

Rejected: Netdataは今回必要な確認に対してUI配布とライセンス境界が重く、R2へダッシュボードを置くと監視のためだけの公開ストレージ運用が増える。

Rejected: mini-vm内だけの監視は、VM・ホスト・Tunnel停止時に監視自体も止まって異常を通知できない。
