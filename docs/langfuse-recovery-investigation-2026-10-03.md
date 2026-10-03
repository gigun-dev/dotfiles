# Langfuse の旧版復帰による停止とデータ保持復旧案

2026-10-03 に `ssh gigun@mini` → `limactl shell mini-vm` で読み取り調査した。サービス再作成、upgrade、DB 更新、通知は行っていない。最新 Swift 実機操作の OTel は Langfuse API が応答せず未取得であり、ユーザーの実機良好報告とは別の検証境界である。

## 確認した原因

NixOS のアプリ版復帰が移行済み DB より古いイメージを起動している。ClickHouse の migration 記録、実スキーマ、コンテナ内ファイル、公式ソースが一致した。

| 対象 | 実測 |
| --- | --- |
| 稼働 Web / Worker | 4.38.0、2026-10-03 04:09:53 UTC 作成 |
| Web 状態 | restarting / exit 1、`no migration found for version 50 ... file does not exist` の反復 |
| Web API | 127.0.0.1:3000 接続拒否、observations CLI は fetch failed |
| 4.38 コンテナ内 migration | `/app/packages/shared/clickhouse/migrations/unclustered/` は 0049 まで |
| ClickHouse migration 最新 | version=50, dirty=0, 2026-10-03 04:08:51.438238457 UTC |
| scores の実 index | `idx_project_trace_observation_v2`, bloom_filter, granularity=2 |
| Postgres | `_prisma_migrations` 442 件、未完了 0。4.46 の追加 4 件が 04:08:51 UTC 完了 |
| VM repo | `299ddfb` / PR #28 が Web と Worker を 4.46.0 に更新、HEAD `293aae4` |
| NixOS 世代 | generation 64 は 4.46.0 の Compose、current generation 63 は 4.38.0 |
| autoswitch | 04:02:23–04:20:05 UTC、failed / status 4 |

4.46.0 の公式 [migration 0050](https://github.com/langfuse/langfuse/blob/v4.46.0/packages/shared/clickhouse/migrations/canonical/0050_scores_trace_index_granularity.up.sql) は scores の v2 index を granularity=2 で作り、旧 index を落とす。実スキーマがこれと一致する。4.38.0 の [migration ディレクトリ](https://github.com/langfuse/langfuse/tree/v4.38.0/packages/shared/clickhouse/migrations/canonical)には 0050 が無い。

Postgres に追加されたのは `20260921150000_add_decision_model_eval_template_type`、`20260921191000_add_evaluator_version_questions`、`20260923120000_in_app_agent_conversation_retention_index`、`20260924174440_skill_management`。すべて [4.46.0 ソース](https://github.com/langfuse/langfuse/tree/v4.46.0/packages/shared/prisma/migrations)に存在する。

保存済み 4.46.0 image の OCI version は 4.46.0、source revision は両方 `d968c7e076a3ba70c37c133a2bf2bfb0c16bbd5c`。以下は PR #28 / generation 64 と一致する exact digest である。

```text
Web: docker.langfuse.com/langfuse/langfuse:4.46.0@sha256:755b821ba8f73a20d43d90e68f2b75d2f597dd164c55890f67a05f5a8d0f0e24
Worker: docker.langfuse.com/langfuse/langfuse-worker:4.46.0@sha256:3568d2d1eb5dd570f4087b37972ddffa3f6ae4f872553e0b0e2eedf4896a29e9
```

4.38 の Web digest は `47ef2f121e2959c8458c209d118949ade25778017e3f5b75b1e45f72276811c3`、Worker は `8631cf429efc4a2981d4e6ced4c005b9f6f620a4e34625baf60152301ec6d006`。

## 更新経路と未確定部分

ADR 0007 は版と digest を固定し、非 major を 7 日経過後に PR で更新する決定である。公式の [upgrade 手順](https://langfuse.com/self-hosting/upgrade)も同一 major の起動時 migration 自動適用を説明している。今回は 4.38 → 4.46 の同一 major 更新が DB に完了したあと、現在の NixOS が旧イメージを宣言している。

`nix/modules/nixos/mini-vm.nix` の autoswitch は healthGate 失敗時に OS profile を前世代へ戻すが、永続 DB を戻す処理はない。generation 64 の Compose と current 63、移行時刻とコンテナ再作成時刻はこの経路と一致する。失敗当時の journal は残っておらず、`journalctl --list-boots` の最古は同日 05:08:43 UTC。最初に healthGate を失敗させた項目や actor はログから確定できない。

現行および VM 最新 repo の healthGate は Netdata の `127.0.0.1:19999/api/v1/info` を無条件で必須にする。一方、実 Netdata unit は inactive / ConditionResult=no / Result=success。これは gate 失敗候補だが、失敗当時の原因と断定しない。

## データと backup 境界

5 named volumes は残存する。稼働 DB の migration 状態は読み取りで整合を確認したが、予定本文や trace 内容を DB から出力していない。

| volume | 調査時 byte 数 |
| --- | ---: |
| langfuse_langfuse_postgres_data | 63997954 |
| langfuse_langfuse_clickhouse_data | 3002688524 |
| langfuse_langfuse_clickhouse_logs | 356663197 |
| langfuse_langfuse_minio_data | 1366804801 |
| langfuse_langfuse_redis_data | 709674 |

`/var/lib/docker` の空きは 229 GiB。既存 backup の時刻・復元検証は未特定。`/var/backups`、`/var/lib/langfuse-backup`、`/var/lib/backups`、`/home/gigun/backups` は存在せず、NixOS の unit と Langfuse 宣言に backup job は見つからなかった。これを全ディスク上の backup 不在とは扱わない。

## 最小復旧案（まだ未適用）

最初に更新 timer が再適用しない保守窓を確保し、実行中 autoswitch が無いことを確認する。失敗中の `langfuse.service` を止めるだけでは全 DB コンテナ停止を保証しないので、Compose `stop` も明示する。以下は VM 内 root shell での適用案であり、この調査では実行していない。

```sh
systemctl stop dotfiles-autoswitch.timer langfuse-update-propose.timer
systemctl is-active dotfiles-autoswitch.service
systemctl stop langfuse.service
docker-compose --env-file /run/agenix/langfuse-env -p langfuse -f /etc/langfuse/compose.yaml stop
docker ps --filter label=com.docker.compose.project=langfuse
```

全 Langfuse container が停止してから、root 専用の新規 backup directory に 5 volume を一括 cold backup する。通常の tar は live DB に対して使わない。数 GiB の容量と inode/ownership、ACL、xattr を保持する。`docker volume rm`、`compose down -v`、migration table の削除・番号書換えは禁止する。

```sh
umask 077
recovery_dir="/var/lib/langfuse-recovery/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$recovery_dir"
chmod 700 "$recovery_dir"
tar --numeric-owner --acls --xattrs -cpf "$recovery_dir/volumes.tar" \
  -C /var/lib/docker/volumes \
  langfuse_langfuse_postgres_data langfuse_langfuse_clickhouse_data \
  langfuse_langfuse_clickhouse_logs langfuse_langfuse_minio_data \
  langfuse_langfuse_redis_data
sha256sum "$recovery_dir/volumes.tar" > "$recovery_dir/volumes.sha256"
sha256sum -c "$recovery_dir/volumes.sha256"
tar -tf "$recovery_dir/volumes.tar" > "$recovery_dir/volume-members.txt"
```

backup manifest に image digest、volume 名、停止時刻、migration/version を残す。暗号化済み `secrets/langfuse-env.age` と Compose も保持し、平文 `/run/agenix/langfuse-env` は docs・ログ・共有 backup に出さない。checksum と一覧だけで復元成功とはしない。適用前に archive を隔離先へ展開できることを確認し、重要データを失わない復元境界を親が確認する。

復旧は generation 64 の既存 Compose を root 専用 recovery dir にコピーし、変更が Web / Worker の 4.46.0 image だけであることを差分で確認してから同じ project 名・同じ volumes へ `up -d` する。新しい最新版へ進めず、すでに DB が通過した exact 4.46.0 に揃える。依存サービスは元イメージ・元 volume を保つ。

```sh
cp /nix/var/nix/profiles/system-64-link/etc/langfuse/compose.yaml "$recovery_dir/compose.yaml"
diff -u /etc/langfuse/compose.yaml "$recovery_dir/compose.yaml"
docker-compose --env-file /run/agenix/langfuse-env -p langfuse -f "$recovery_dir/compose.yaml" config --quiet
docker-compose --env-file /run/agenix/langfuse-env -p langfuse -f "$recovery_dir/compose.yaml" up -d
```

この一時復旧だけでは `/etc/langfuse/compose.yaml` と NixOS 宣言の逆戻りが残る。更新 timer は再発抑止を宣言へ反映・検証するまで再開しない。旧 OS 全体への blind rollback を避けるため、新規 migration が適用されたサービスは旧イメージへ戻さない fence を autoswitch に加えるか、stateful サービスの版適用と OS health rollback を別レーンにする。Netdata gate は現在の正式監視構成と ConditionResult の扱いを揃える。どちらも今は提案であり、実装は未実施。

復旧失敗時も 4.38.0 への切替は rollback 手段にしない。停止を維持して 4.46.0 と backup の復元可能性を調べる。cold backup は停止直前の migration50状態なので、復元後も 4.46.0 の対を使う。volume を上書きする restore は隔離環境で検証し、適用判断を別に行う。

## 復旧後の検証手順

1. Web / Worker exact digest と restart count 安定、全依存 health を確認する。
2. `http://127.0.0.1:3000/api/public/ready` と公開 OTLP hostname の readiness が 200 になることを確認する。
3. ClickHouse version50 dirty0、Postgres 未完了0と、既存 volume 名保持を再確認する。
4. Langfuse CLI の `observations list --fields core,basic,time,io,usage,metrics,trace_context --from-start-time ... --json` で最新実 trace を取得する。API key はプロセス環境内のみで扱い、出力本文・認証値を専門 docs に残さない。
5. 最新「今日の予定 / todo」を時刻・trace IDで特定し、tool 引数、反復、turn duration、LLM/tool ERROR、最終回答、実件数を確認する。特定できなければ未特定とする。復旧後に既存対象が届いていなければ、Swift側の送信時刻・HTTP結果・retry/flush境界を調べ、新しい実操作が必要な境界を親へ返す。
6. autoswitch に新 schema 後の旧版復帰が起きないこと、正式監視 gate が成立することを確認してから timer を再開する。

この調査で認証情報、予定本文は保存していない。最新 OTel が未取得であるため、Swift の送信側も含む end-to-end 成功とは報告しない。
