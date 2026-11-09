# dotfiles 公開前監査

この文書は公開可否のgateを記録する。過去のSHA、run ID、host状態、件数は当時のreceiptであり、現在の公開面を証明しない。最終判断ではpublic直前のSHAとGitHub current stateを再取得する。

## 判定

現在は**NO-GO**。visibilityを変更してはならない。理由は次の未完項目である。

- SOPS移行、recipient分離、旧credential失効、agenix撤去が未完
- 到達可能履歴に現在も有効な可能性があるBark対称鍵が平文で残る
- 非再構成可能なrecovery assetの独立復旧が未確認
- SSHのhost固有入力がpublic moduleに残る
- current tree以外のGitHub公開面に未確認範囲がある
- 最終SHAのrequired CIと必要なmacOS検証が未実行

private文書や専用private repoの不存在はblockerにしない。public化で課金問題を回避することも、監査の代替にしない。

## 情報の分類

| 分類 | 正本 | 公開側の扱い |
|---|---|---|
| public宣言 | Nix、Ansible、OpenTofu template、再現手順、ADR | review可能な設計として維持する |
| 暗号化structured input | SOPS暗号文 | secret名、field名、recipient metadataも公開対象として監査する |
| provider current state | GitHub、Tailscale、Cloudflare、Apple、Keychain等 | live確認し、変化するsnapshotをrepoへ複写しない |
| 一時receipt | 比較中だけ保持する値なし結果 | todoへ結論を反映後に削除する |
| 不要な観測 | consumerがなく復旧にも不要な情報 | privateへ退避せず削除する |
| recovery asset | 再構成不能な復号鍵、recovery code等 | 日常端末・provider accountと独立したfailure domainで限定復旧する |

専用private repo、private散文台帳、包括的restore manifestは作らない。秘密値はSOPS、1Password、Keychainまたはprovider secret store、consumerとの対応はpublic宣言、現在値はproviderを正本とする。

## これまでに確認した範囲

- current tree、追加commit、commit message、pathnameを値非表示のfull-tree gitleaksで検査し、actual credentialとして分類すべき一致は見つかっていない。
- 全refsの履歴scanでは10件を検出した。7件はpublic identifierまたは明示的dummy例だが、3件は同一のBark対称鍵と判断すべき値で、全remote追跡refとtagから到達する。repo内に後続rotationや旧鍵拒否の証拠はない。
- Ansible inventoryは公開alias、user、標準path、fail-closed SSH optionだけに限定し、field allowlist testを追加した。
- Actionsは外部ActionのSHA固定、read-only既定permission、full-tree secret scan、actionlint、zizmor、fail-closed aggregate gateを実装した。
- review済みSHAに対するephemeral self-hosted Linux fallbackで、成功経路、失敗集約、jobごとの登録解除、使用後cleanupを確認した。
- Release、artifact、取得可能なrun log、PR本文・comment・review・patchを値非表示で監査したが、取得不能log、cache bytes、編集履歴等の未確認範囲が残る。
- private proseへcurrent stateを複写する案は撤回し、関連する例・検証器・ignoreを削除した。

この確認は実施時点の対象だけを示す。後続commit、GitHub上の増分、最終公開SHAを証明しない。

## GitHub current stateの確認

2026-11-09にprovider APIから値を表示せず再取得した時点では、repositoryはprivateのままで、次を確認した。

- Actionsの既定権限はread、pull request承認は不可、ActionのSHA固定は必須である。
- repository Actions secret、variable、environment、self-hosted runnerの登録は0件である。
- `main`はstrictなstatus checkとして`check`、`build`、`nix-ci-gate`を要求する。
- 管理者への保護適用、pull request review、署名commit、rulesetは未設定である。
- 利用可能なActionはallowlistではなく全Actionである。
- default branchから削除済みのworkflow 2件が、GitHubのworkflow registryではactiveのまま残る。

最後の4項目は直ちに脆弱性を意味しないが、public化時の書込経路と監査面を変える。保護を変更する場合は項目ごとに合意し、削除済みworkflowは無効化するか残す理由を決める。現在のPRに表示されるgreen checkは以前のremote SHAに対する結果であり、未pushの最終候補SHAの証明には使わない。

## current treeの公開blocker

1. Barkの固定IVを廃止して通知ごとのrandom IVへ移行する。暗号鍵は現行Barkに無人変更経路や複数slotがないため、無人でcandidate生成・SOPS staging・rollback準備まで行い、iPhone側の切替だけ本人承認にする。public前に履歴上の現行鍵を使い続ける場合は、通知内容の暗号化が公開鍵相当になることを明示的に受容する。受容しない場合はone-time cutoverし、新鍵の表示と旧鍵の復号拒否を確認する。
2. [ADR 0016](adr/0016-unify-secret-delivery-with-sops.md)に従い、human、host、通知等のrecipient群を分けてSOPSへ移行する。
3. 共通SSH設定にはprivate includeの受渡し口を追加済み。SOPS生成の0600 includeを配送・受入してから、public moduleのhost固有alias、endpoint、user、key配置を削除する。
4. `docs/mini-vm.md`等からcurrent token scope、account関係、実UID/session、private runner path、完全な内部endpoint、日時付きlive観測を除く。
5. 非再構成可能なrecovery assetをprimary / backup経路から実際に再読取する。
6. Bark鍵のone-time cutoverまたは公開リスク受容を確定後、全remote refとtagを含むhistory rewriteまたは監査済み新履歴を本人が選ぶ。commit messageに残るagent session metadataと旧attributionも同じ判断に含める。

## GitHub公開面の最終監査

最終候補SHAをpushした後、visibility変更前に次を再取得する。

- 全branch / tag / releaseと到達可能履歴
- PR #137の本文、comment、review、inline thread、patch、添付、timeline
- 全増分run / attempt / log / artifactとrequired check
- active workflow、environment、repository variable、secret名、runner登録
- default branchから削除済みだがregistryに残るworkflowの状態
- cache metadataと監査可能範囲
- 最終mainとの差分と公開直前SHA

取得不能なlogや監査できないcache bytesを成功扱いしない。cacheを削除して最終workflowから再生成する場合は、破壊的な外部変更として本人承認を得る。

## CI gate

最終SHAでLinuxの変更判定、secret scan、check、build、portable test、aggregate gateを成功させる。macOS native jobが必要な範囲は対応hostで別に実行する。pending、skipped、cancelled、結果欠落、過去SHAのgreenを最終成功へ読み替えない。

すべてのgateが揃った後に、本人が最終監査結果と残存リスクを読み、visibility変更を明示承認する。public化後は同じSHAのrequired checksと匿名閲覧面を再確認する。
