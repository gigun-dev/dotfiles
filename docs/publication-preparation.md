# 公開準備

現在は準備段階であり、公開可能との判定でも visibility 変更の承認でもない。

## 優先して分離する範囲

| 対象 | 分類 | 非破壊で進める方法 |
|---|---|---|
| docs/security.md | 個人アカウント・鍵の役割・保管と復旧の運用情報 | 公開可能な原則と再現手順だけ残し、不要な個人観測は別repoへ退避せず削除する |
| ansible/mini-macos/inventory.yml | 公開alias・ユーザー・標準path・fail-closed SSH option | 実addressやcredentialを含まない公開宣言として維持し、field allowlistとnegative fixtureで情報流入を防ぐ |
| nix/modules/home/programs/ssh/default.nix | ホスト固有の宛先・ユーザー・鍵参照 | 公開共通設定と暗号化structured inputから生成するprivate includeへ分け、Host/Include 順序、IdentityFile の累積、Darwin/Linux 差を維持する |
| docs/mini-vm.md、関連運用 docs、todo.txt | 内部構成・手順・運用メタデータ | 一文ずつ機密性と再現性を分類する。すべての内部名を機械的に削除しない |
| docs/agent-harness-boundaries.md、docs/execution-context.md | harness、sandbox、network、repo 外アクセスの境界 | 防御の実装詳細と再現に必要な一般説明を分け、現在の host / tool 固有状態を公開してよいか判断する |
| docs/security-access-boundaries.md、docs/linux-ci-fallback.md | trusted user、sudo、self-hosted runner の信頼境界 | 実秘密ではないが攻撃面を説明する運用 metadata として、公開可否を明示的に判断する |
| docs/credential-inventory.md | credential class、consumer、複製先、失効順 | 値なしでも service 対応と運用 topology を示すため、公開版と非公開詳細台帳の境界を確認する |
| tofu/ と secrets/ の宣言 | リソース情報・暗号化秘密の受信者 | 実秘密を出力せず、公開してよいメタデータと不要な権限を分ける |

## 検証と保持

- 各情報を `public宣言 / 暗号化structured input / provider current state / 一時receipt / 削除` のいずれかへ分類する。privateな散文を包括的な正本として新設しない。
- 再構成不能な秘密とbreak-glass材料だけ、日常端末・provider accountと独立したfailure domainから限定復旧できることを確認する。runtime平文やignore対象は正本・backupとして扱わない。
- provider metadataはproviderを正本としてlive確認し、exact IDを恒久的な監査文書へ複写しない。必要なreceiptは値なし・期限付きとし、恒久的な判断と未処理項目だけをtodoへ残す。
- 例示 inventory はproduction identity guardを通らないnegative fixtureで、既定 inventory として設定しない。Ansible はディレクトリ指定で複数ファイルを読み得るため、`-i` にはディレクトリではなく使用する inventory ファイルを明示する。
- inventory や SSH の挙動変更を文書改善に混ぜない。既存入力を使う場合の生成結果と fixture tests を確認する。
- ignore 設定は既存 tracked ファイルや履歴を消さない。`git check-ignore` の正例・負例を確認する。
- 公開対象の履歴、branch/tag、PR/issue、Actions 出力・artifact、Release 資産の確認は別の公開前 gate。現行 tree だけの検査で閉じず、旧監査後の追加 commit・artifact・Release も含める。
- agent harness の権限制御、trust domain、SOPS recipient grouping、CI fallback の撤去状態は秘密値ではない。しかし防御構成と復旧経路を組み合わせて示すため、値の scanner が一致0でも自動的に公開可とは扱わない。

## 今ここでは行わない

visibility 変更、別 repo 作成、履歴 rewrite / force-push、秘密の使用テスト、鍵 rotation、SSH / VPN / sandbox 権限変更、実機 apply。これらは必要な時点で具体的な対象・影響を示す。
