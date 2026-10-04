# 3定期ジョブの受付資格情報候補を準備する

`prepare-job-heartbeat-registration.py` は既存の `prepare-host-heartbeat-registration.py` の `prepare()` と検証を再利用する薄いローカルwrapper。発行、暗号化、アップロード、Worker配備、通知送信は行わない。

対象は `mini-vm-autoswitch` / `mini-vm-lock-fast` / `mini-vm-lock-slow` の3 sourceのみ。既存登録の `mini-vm` が一意で、owner `homelab` / destination `bark` と一致することを確認してroutingを継承する。新規entryに `monitorControl` は付けない。既存の他entryは値・順序・追加fieldを保持する。同じjob sourceが既にあれば、token・owner・destination・field集合まで完全一致する場合だけそのまま残す。不一致や重複sourceは上書きせず拒否する。

## ローカル準備

承認済みのMac上で、既存age recipientと既存秘密管理手順を使う。対応する暗号化ファイルは `job-heartbeat-autoswitch.age` / `job-heartbeat-fast.age` / `job-heartbeat-slow.age`。新規発行・復号はこのwrapperの責務に含めない。

1. 0700の一時staging directoryを用意する
2. 既存受付登録JSON arrayと3source→tokenだけのJSON objectを、staging内の0600 regular fileへ用意する。秘密値はコマンド引数、stdout、ログ、チャット、Gitへ出さない
3. 候補を新しいパスへ書く

```sh
python3 scripts/prepare-job-heartbeat-registration.py \
  --credentials-file "$staging/existing.json" \
  --tokens-file "$staging/job-tokens.json" \
  --output "$staging/candidate.json"
```

成功時は無出力でexit 0、失敗時は秘密を含まない固定診断で非ゼロ。入力のsymlink、FIFO、実行ユーザー以外の所有、0600以外、128KiB超、重複JSON key、出力先directoryのsymlink・実行ユーザー以外の所有・0700以外、既存outputを拒否する。検証済みdirectoryのfile descriptorを保持し、相対操作で0600 temporary fileへ書き、fsync後にhard linkで原子的に公開する。途中でdirectoryのパスが置換されても別directoryへ書かない。競合時も既存outputを置換しない。入力は変更しない。

既存4entryがあり3jobが未登録なら候補は7entry。candidateそのものは秘密なので、レビューにはsource名・routing・entry数と検証結果だけを用い、内容を表示しない。承認済み適用担当が既存の暗号化・OpenTofu手順へ渡す。適用/rollbackが終わるまで旧暗号化入力を保持し、不要になったstaging平文は既存運用に従って除去する。ジョブの有効化・初期heartbeat・正常終了確認は別の受入段階。

## 公開fixture試験

```sh
python3 scripts/tests/job-heartbeat-registration.py
```

公開文字列だけで、既存保持、3件追加、partial/idempotent、一致しない登録の拒否、token重複/形式、routing、容量、private file、symlink/FIFO、上書き拒否、固定診断を検証する。
