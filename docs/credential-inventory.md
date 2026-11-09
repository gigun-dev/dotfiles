# 資格情報クラス台帳

この文書は、資格情報を値なしのクラス単位で分類し、継続・権限縮小・更新・削除の判断と未処理作業を追跡する公開用台帳である。秘密値、復旧コード、PIN、秘密鍵、公開鍵、fingerprint、client ID、key ID、account・organization・repository・project・resource・host の実名、IP、exact path、期限日、複製ファイル名は記録しない。

実credentialの現在値は、provider管理面、Keychain、password manager、consumer宣言を権威ある情報源として確認する。exact scope、期限、active key、登録factor、最終利用を別の散文台帳へ複写しない。公開できない機械入力はSOPS等の暗号化structured dataとして管理し、再構成不能な秘密・復旧材料だけ独立backupを確認する。

関連文書:

- [セキュリティの方針](security.md)
- [公開準備](publication-preparation.md)
- [実行環境と認証診断](execution-context.md)

## 状態の読み方

| 状態 | 意味 |
|---|---|
| 継続 | 現在の用途に必要。権限・期限・復旧の定期確認は別に必要 |
| 権限縮小 | 用途は残すが、対象 resource、操作、利用主体、受信者、期限を狭める |
| 更新 | 利用確認、分離、rotate、保管方式変更、復旧確認のいずれかが必要 |
| 削除 | 現在の用途がない。依存先確認と代替受入後、発行元の失効を先に行う |
| 宣言済 | repo の宣言から読める。実機適用や有効性は未確認 |
| live確認済 | 値を取得せず、対象環境で metadata または必要操作を確認済み |
| 過去観測 | 記録時点の事実。現在の状態として使わない |
| 計画のみ | まだ発行・配備・移行していない |

「継続」は安全性の認定ではない。「更新」は、確認結果により継続または削除へ変わる。認証失敗、HTTP 403、sandbox の network deny だけで credential の失効や scope 不足を断定しない。

## 分類

確認基準日は 2026-11-09。この表は資格情報の実体ではなくクラスを表す。live metadataはproviderとconsumer宣言から確認し、値なしの判断、確認日、次操作だけをtodoへ記録する。

| ID | 資格情報クラス | 主な利用主体 | 判断 | 現在の根拠 | 次の操作 |
|---|---|---|---|---|---|
| C01 | 対話用 code-hosting 認証 | 人、同一 UID の対話 agent | 権限縮小 | 対話操作と push・管理操作の境界が未分離 | 無人用と分け、鍵追加・管理・書込権限を用途ごとに確認する |
| C02 | 無人更新用 code-hosting 認証 | 無人更新 service | 更新 | hostに置く長期credentialとproviderがjobごとに発行する短命workflow tokenはlifecycleが異なる。前者の専用化が未完 | 更新提案、PR、CI確認だけで受入し、旧 credential を失効する。workflow tokenをhostへ複製しない |
| C03 | hardware-backed Git identity | 人、同一 UID の Git process | 継続 | 持出不能な署名・push identity を使う方針 | provider 登録と実際の署名・push用途を値なしで再確認する |
| C04 | file-based SSH identity 群 | 人、同一 UID の process | 更新 | 認証、復号、通知など複数用途の兼用が残る | 用途別に分離し、受入側から旧公開鍵を外してから local key を削除する |
| C05 | 無人 host の復号 identity | 無人 host、root service | 権限縮小 | 無人秘密の復号には必要だが、人用秘密の受信者にもなり得る | 人用と無人用の暗号文を分け、不要な recipient を外して rekey する |
| C06 | 人用・復旧用の復号 identity | 人、予備 hardware | 更新 | dummy 復号試験と本番移行・予備復旧試験が分かれている | 本番対象を限定して移行し、予備鍵で復元後に旧 recipient を退役する |
| C07 | IaC control-plane token 群 | 人が実行する IaC process | 権限縮小 | 複数 provider・resource の長期 credential を扱う | resource、action、IP、TTL を限定し、人用 recipient だけにする |
| C08 | state backend credential と暗号化材料 | 人が実行する IaC process | 更新 | state の読み書きと復旧に必要 | read/write、再暗号化、backup、restore を限定成果物で確認する |
| C09 | 無人 cloud service API credential | 無人 service | 権限縮小 | service 継続に必要だが権限・期限の live確認が必要 | service 専用の resource・action・TTL へ絞り、health確認後に旧 token を失効する |
| C10 | tunnel・接続 broker credential | root または専用 service | 継続 | tunnel connectorとoverlay networkのnode identity・再参加credentialはlifecycleが異なる | subtypeごとにprovider control planeとconsumer宣言を突合し、失効・再参加、rotate時の停止範囲を確認する |
| C11 | OAuth application runtime secret | 専用 application service | 継続 | application の認可フローで利用 | provider metadataとconsumer宣言からowner、callback、active key、rotation状態を確認する |
| C12 | ダウンロードされた OAuth secret の複製 | なし、または未確認 | 更新 | repo内consumerは見つからないが、provider上のruntime clientとの同一性は未確認 | client metadataを照合し、不使用なら削除、利用中ならruntime正本を確認してduplicateだけを削除する |
| C13 | ダウンロードされた application private key | なし、または未確認 | 更新 | repo内consumerは見つからないが、provider上のinstallation・active keyは未確認 | installationとconsumerを確認し、不使用なら発行元keyを失効してからlocal copyを削除する |
| C14 | 通知 credential | 人の開発環境、無人 service | 更新 | 複数主体の共有と旧復号鍵依存が残る | 利用主体ごとに分離し、旧 identity への依存を外す |
| C15 | model bridge・API credential | 専用 user service | 継続 | service起動に必要 | service専用権限、課金上限、期限、rotation受入を確認する |
| C16 | observability・管理 service の秘密 | 専用 service、初期管理者 | 更新 | runtime秘密と初期credentialが同じ管理単位に混在する | runtime暗号化材料、初期admin、agent tokenを別credentialとして管理する |
| C17 | CLI の可変 OAuth session | 対話 CLI、同一 UID の service | 継続 | CLI自身がrefreshするため宣言配布しない | provider revoke、service停止、再login、restartの順を確認する |
| C18 | binary cache write credential | 明示送信 process | 更新 | 通常適用からの自動送信は停止済みだが、今後送信しない方針は未決定 | 送信しない案を決めた場合だけ発行元で失効し、local copyを削除する |
| C19 | 開発 project の API key・`.env` | 人が起動する process、子 process | 権限縮小 | projectごとの権限・期限・課金上限・agent露出が未整理 | 1 projectでprovider metadataとconsumerを突合し、必要なstructured secretだけ既存secret managerへ置く |
| C20 | account passkey・security key・recovery credential | 人、予備 hardware | 継続 | 主要accountへの登録記録がある | 2本の登録、recovery経路、紛失時の失効順を値なしで定期確認する |
| C21 | provider-managed log delivery credential | provider-managed service | 更新 | localに秘密を増やさない方針だが、jobの存在・保存先・翌日到着は未受入 | 保存先限定、翌日到着、失効方法を確認してから継続へ移す |
| C22 | build・sign・publish credential | GUI session、署名主体、publisher | 更新 | 工程と利用主体の分離が未完 | identity、artifact hash、承認点、配布先権限を工程別に分ける |
| C23 | password manager・keychain・plugin OAuth の未分類項目 | 人、同一 UID の application | 更新 | 導入済み機能と実際の移行・連携状態が一致していない | provider metadata、item metadata、consumerを突合し、使途不明項目を削除候補にする |

## 未処理todoとの対応

公開台帳のクラスは実credentialと1対1ではない。同じクラスに複数のconsumerやcredentialがある場合、
providerとconsumer宣言上の実体をconsumerごとに確認し、次の既存todoへ結ぶ。

| クラス | 主なtodo | 残る境界 |
|---|---|---|
| C01, C03, C04 | 0176, 0174, 0098 | 対話認証、hardware-backed identity、旧file keyの役割分解 |
| C02 | 0002, 0164, 0070 | 無人更新identity、Actions移行、green/red/pending判定 |
| C05, C06, C14 | 0174, 0109, 0098 | host / human / recovery / 通知recipientとcredentialの分離 |
| C07, C08 | 0096, 0101, 0174 | IaC権限・recipientとstateの限定backup / restore。restore受入は実credential分解時に独立した次操作へする |
| C09, C11, C15, C16, C17, C23 | 0101, 0108, 0099, 0082, 0086, 0089, 0159 | umbrella classのまま完了扱いにせず、provider / config突合時にconsumer単位の次操作へ分ける |
| C10 | 0171, 0101 | tunnel connectorとoverlay nodeの期限・失効・再参加を分ける |
| C12, C13 | 0108 | provider metadata照合後にだけ継続または削除へ確定する |
| C18 | 0100 | binary cacheへ送信するかを先に決める |
| C19 | 0099, 0109 | 1 projectで保護方式、権限、期限、課金上限を受入する |
| C20 | 0096, 0102 | 予備鍵、別端末、紛失・侵害時の失効順を確認する |
| C21 | 0094 | provider-managed deliveryと翌日到着を確認する |
| C22 | 0122 | build / sign / publishの主体とcredentialを分ける |

## 情報源と永続化の境界

public repoには、安定したクラスID、一般化した用途、利用主体の種類、判断、確認状態、確認基準日、consumer宣言、方針文書、todo IDだけを記録する。

provider管理面とconsumer宣言を、exact ID、scope、role、resource selector、期限、active key、最終利用、複製先の現在値として都度突合する。変化するmetadataをprivateな散文へ複写しない。監査時に必要なreceiptは値なし・期限付きで生成し、恒久的に必要な判断と未処理項目だけをtodoへ反映する。

実行に必要な非公開structured inputとsecret valueはSOPS、1Password、Keychainまたはprovider secret storeへ置く。runtime生成file、ignore対象、旧commitは正本やbackupにしない。不要になった観測やreceiptは別repoへ退避せず削除する。

## 更新規則

1. 新しい credential を発行する前にクラスと利用主体を決める。
2. provider metadataとconsumer宣言を突合し、公開台帳には値なしのクラス判断だけを反映する。
3. 実機確認には日付と `宣言済 / live確認済 / 過去観測 / 計画のみ` を付ける。
4. 古い観測を現在値で上書きせず、supersededとして残す。
5. 失効は、consumer確認、代替発行、限定受入、切替、provider revoke、local copy削除、旧credential拒否確認の順で行う。
6. private keyはlocal fileより先に受入側の公開鍵を外す。
7. recipient変更は暗号文をrekeyし、旧ciphertextが履歴・backup・公開copyに残ることを記録する。
8. 実行可能な次操作はこの文書に増やさず、todo IDへ置く。

## 完了条件

資格情報棚卸しは、次をすべて満たした時だけ完了とする。

- provider / config上の実credentialが用途、consumer、scope、期限、複製先と突合されている
- 全実体が継続・権限縮小・更新・削除のいずれかに分類されている
- live未確認と過去観測が現在値から分離されている
- 削除項目にconsumer確認と発行元失効の順序がある
- 再構成不能な秘密・復旧材料だけがTask 0166の独立backup対象になっている
- exact IDや秘密値を恒久的な監査文書へ複写していない
- 公開台帳に実名、識別子、exact path、秘密値が含まれていない
- 未処理項目がtodoへ対応している
