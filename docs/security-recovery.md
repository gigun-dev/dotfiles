# 認証要求と侵害時の復旧

この手順は、sudo の要求元を見分け、Mac・鍵・資格情報の紛失または侵害時に、別端末と予備鍵から復旧するための公開用runbookである。秘密値、復旧コード、鍵ID、account・resourceの実名は書かない。正確な対象と現在の登録状態はprovider管理面、consumer宣言、secret managerから復旧時に確認する。変化する現在値をprivateな散文へ複写せず、再構成不能なrecovery code、復号鍵、Emergency Kit相当だけを独立したbreak-glass材料として保全する。

## sudo要求の現在地

Proの主checkout・mainで `git pull --rebase`、merge、rebase、branch checkoutにより `flake.nix`、`flake.lock`、`nix/` が変わると、git hookは端末や操作者を判定せず `nix run .#switch` を起動する。したがって、現在は人が直接打ったcommand以外からTouch ID / Apple Watchの要求が出る。linked worktree、feature branch、Intel mini、NixOSではこのhookはswitchしない。mini-vmの自動適用は別のCI gateを使う。

認証要求が予期した操作と対応しないときは承認しない。要求を閉じ、直前のgit操作、branch、checkout種別、Nix変更の有無を確認する。失敗してもgit操作自体は成功したままになり得るため、`git status` と現在generationを別々に確認する。

| 方針 | 利点 | 残る問題 | 状態 |
|---|---|---|---|
| 現行: 操作者を問わず自動switch | mainと稼働構成のずれを減らす | 非対話processでも突然認証を要求し、要求元を判断しにくい | 適用中 |
| 提案: 非対話ではswitchせず、必要commandを表示 | sudo要求を人の明示操作へ寄せられる | switch忘れを検知・通知する別経路が必要 | 未決定 |

この選択はgit hookの運用規則を変えるため、合意前に実装しない。どちらを選んでも、sudoはTouch IDを維持し、挿しっぱなしのhardware keyをsudo認証へ使わない。

## 事前に揃えるもの

- 日常端末と独立した復旧端末から、provider管理面、secret manager、break-glass材料へ到達できる
- primaryとbackupのhardware keyを別のfailure domainに置き、各accountへの登録状態を値なしで確認している
- password managerの復旧、端末紛失機能、recovery codeの所在を本人が読める
- 人用、無人service用、build/sign/publish用のcredentialが利用主体とconsumerへ対応付いている
- credential classとprovider公式手順から「代替を先に配備できるか」「即時失効が先か」を判断できる

repo内の暗号文、ignore対象、旧commit、同じ端末のbackupだけを復旧経路にしない。

## 共通の初動

1. 侵害が疑われる端末で新しいcredentialを作らない。可能ならnetworkから隔離し、時刻と観測だけを残す。
2. 独立した復旧端末とbackup keyからprovider管理面とsecret managerへ入り、対象をlive列挙する。sandboxのnetwork denyや単発の認証失敗だけでcredential侵害と断定しない。
3. 影響する主体、provider、resource、consumer、複製先を値なしで列挙する。
4. 攻撃継続を止める必要があるsession・token・鍵を失効する。可用性を先に確保できるruntime credentialは、代替を限定配備してhealth確認後に旧credentialを失効する。
5. 旧credentialが拒否されること、代替経路で必要操作だけが通ること、不要な管理操作が拒否されることを確認する。
6. 信頼できるsourceから端末またはserviceを再構築し、恒久的な設計変更と未解決事項だけをpublic runbookとtodoへ反映する。一時識別情報は保存しない。

## 事象別の順序

### Macの紛失

1. 端末の紛失mode・remote lockまたはwipeを、独立端末から開始する。
2. 端末上の対話session、code-hosting token、SSH authentication key、Access session、password manager sessionを失効する。
3. 端末固有のSecure Enclave keyを受入側から削除する。取り出せない鍵でも、盗難端末上で利用され得るものとして扱う。
4. cloud、IaC、開発API keyのlocal copyが存在したクラスをrotateし、旧credential拒否を確認する。
5. 新端末ではbackup keyからaccountへ入り、鍵とtokenを用途別に再発行する。旧端末のbackupから秘密を一括復元しない。

### Macの侵害疑い

1. networkを隔離し、当該Macで使えたcredentialと同一UIDから読めた秘密を侵害候補にする。
2. 別端末からcode-hostingのtoken・key・session、cloud control-plane、Access、OAuth application key、開発API keyの順に影響を止める。組織や課金へ書けるcredentialを優先する。
3. 無人serviceは新credentialを専用consumerへ限定配備しhealth確認後に旧credentialを失効する。人用credentialを暫定共有しない。
4. source、履歴、Release、Actions、artifact、cache、registryへ不審な書込みがないか確認する。
5. OSを再構築し、信頼できるcommitから宣言を適用する。侵害端末のkeychainや平文 `.env` をそのまま戻さない。

### hardware keyの紛失

1. backup keyまたは独立した既存sessionで各accountへ入れることを先に確認する。ただし盗難・PIN露出の疑いがあれば可用性確認を待たず紛失keyを失効する。
2. 紛失keyのpasskey / security-key登録とPIV recipientを削除する。
3. PIV recipientを含む本番暗号文を残るrecipientへrekeyし、backupや旧ciphertextに紛失key宛てが残る範囲を記録する。
4. replacement keyを登録し、別端末からloginと限定復号を試す。primaryとbackupを同時に持ち歩かない。

### 無人hostまたはservice credentialの侵害

1. serviceを停止またはnetworkから隔離し、対象repository・resource・actionを確認する。
2. 新しい専用credentialを最小scope・期限付きで発行し、限定consumerだけへ配備する。
3. PR作成、CI確認、更新提案など必要操作を受入後、旧credentialをproviderで失効する。
4. local runtime copy、download copy、backup copyを順に削除し、旧credentialの拒否とservice復旧を確認する。

## 復旧試験の完了条件

- 別端末とbackup keyからprovider管理面、secret manager、break-glass材料へ到達できる
- 主要accountへprimary keyなしで入り、登録factorを確認できる
- 限定した非本番credentialまたはfixtureで、代替配備、必要操作、旧credential拒否、rollbackを確認できる
- 失効の証拠にsecret value、復旧コード、内部識別metadataを残していない
- 未確認のprovider、別端末、backup、consumerを明記している

repoの非秘密software-age fixtureは、human暗号文をprimary / backupだけが読めること、host暗号文を両者とhostが読めること、backupからreplacementへrekeyできること、退役recipientが新しい暗号文を読めないことを検査する。また、rekey前の暗号文は退役鍵で読め続けることを固定し、recipient削除だけでは過去copyを失効できないことを示す。このfixtureは実YubiKey、独立端末、実credentialのrotation、provider復旧を証明しない。

実際の紛失・侵害時は、このpublic runbook、credential class、実行時点のprovider公式手順を組み合わせる。provider仕様が変わり得るため、古いprivate手順を正本にしない。
