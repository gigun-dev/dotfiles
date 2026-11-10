# dotfiles 公開監査

この文書は公開可否のgateを記録する。過去のSHA、run ID、host状態、件数は当時のreceiptであり、現在の公開面を証明しない。最終判断ではpublic直前のSHAとGitHub current stateを再取得する。

## 判定

現在は**GO（public化済み）**。Bark cutover、通常のbranch / tagとPR内部refから
到達可能な履歴の再走査、GitHub公開面の監査、cache削除、最終current stateの
取得を完了した。本人が残存リスクを読んで受容し、visibilityをpublicへ変更した。
匿名APIとraw fileの閲覧、同一監査済みSHAのGitHub-hosted CIも確認した。
残存リスクと受容根拠は次のとおりである。

- 取得不能だった171 attempts（410が169件、404が2件）は内容を監査できていない。
  認証済み所有者APIでも現在本文を配信しないが、取得不能を恒久的な安全の証拠にせず、
  公開前に残存リスクとして本人が受容するか判断する。当時のworkflow定義は全件取得でき、
  repository / environment secret参照、明示write権限、credential出力、環境全dumpはいずれも0件だった。
  run削除はCI証跡を失いcached copy消去も保証しないため行わず、公開直後に匿名表示を確認する。
- GitHub管理の151 PR内部refsから到達する2,463 blobsを追加走査し、旧Bark鍵一致0件を
  確認した。全145 PRの現行本文・comments・reviews・timelineも走査し候補0件、GitHub添付0件、
  危険な構造の外部リンク0件だった。APIで取得できない編集前内容、削除済みcomment、cached viewは、
  retired keyが残り得る範囲として本人が受容するかGitHub Support等での除去を選ぶ。
- visibility変更直前のGitHub current stateと増分を再取得し、本人が最終結果を読んで
  visibility変更を明示承認した。

private文書や専用private repoの不存在はblockerにしない。SOPS全面移行、recipient細分化、
recovery assetの実復旧、P0〜P2の残りも、暗号文とcurrent treeの公開安全性を確認した上で
public後に継続する。public化で課金問題を回避することは監査の代替にしないが、必須gateを
閉じた後はhosted CIを使って残作業を進めてよい。

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
- 書換え前の全refs履歴scanでは10件を検出した。7件はpublic identifierまたは明示的dummy例、
  3件は同一のBark対称鍵と判断すべき値で、当時の全remote追跡refとtagから到達していた。
- Ansible inventoryは公開alias、user、標準path、fail-closed SSH optionだけに限定し、field allowlist testを追加した。
- Actionsは外部ActionのSHA固定、read-only既定permission、full-tree secret scan、actionlint、zizmor、fail-closed aggregate gateを実装した。
- review済みSHAに対するephemeral self-hosted Linux fallbackで、成功経路、失敗集約、jobごとの登録解除、使用後cleanupを確認した。
- Release、artifact、取得可能なrun log、PR本文・comment・review・patchを値非表示で監査したが、取得不能log、cache bytes、編集履歴等の未確認範囲が残る。
- private proseへcurrent stateを複写する案は撤回し、関連する例・検証器・ignoreを削除した。

この確認は実施時点の対象だけを示す。後続commit、GitHub上の増分、最終公開SHAを証明しない。

## GitHub current stateの確認

2026-11-09にprovider APIから値を表示せず再取得した時点では、repositoryはprivateのままで、次を確認した。

- Actionsの既定権限はread、pull request承認は不可、ActionのSHA固定は必須である。
- repository Actions secret、variable、environment、self-hosted runnerの登録は0件であった。
  これは当時のsnapshotであり、その後Updater用Environmentとsecretを作成したため現況ではない。
- `main`はstrictなstatus checkとして`check`、`build`、`nix-ci-gate`を要求する。
- 管理者への保護適用、pull request review、署名commit、rulesetは未設定である。
- 利用可能なActionはallowlistではなく全Actionである。
- default branchから削除済みのworkflow 2件が、GitHubのworkflow registryではactiveのまま残る。

最後の4項目は直ちに脆弱性を意味しないが、public化時の書込経路と監査面を変える。保護を変更する場合は項目ごとに合意し、削除済みworkflowは無効化するか残す理由を決める。現在のPRに表示されるgreen checkは以前のremote SHAに対する結果であり、未pushの最終候補SHAの証明には使わない。

2026-11-10の再取得では、repositoryはprivate、Actions既定権限はread、PR承認不可、
repository secret / variableは0件、Environmentは1件、active workflowは10件、
self-hosted runnerとcacheは0件、artifactは5件であった。mainはstrictな`check`、`build`、
`nix-ci-gate`を要求し、force-pushとbranch deletionは禁止、管理者への保護適用とreview必須化は
無効のままである。このsnapshotもvisibility直前に再取得する。

公開判断直前の再取得でも、repositoryはprivate、remote mainは監査済みSHAから
変更なし、最新runは同一SHAでsuccessだった。cache / self-hosted runner /
repository secret / variableは0件、artifact 5件、Environment 1件、active workflow 10件である。
mainはstrictな3 checksを要求し、force-pushとbranch deletionは禁止されている。

## 完了したcurrent treeの公開blocker

1. Barkの固定IVを廃止して通知ごとのrandom IV化を行い、one-time cutover後にProと
   mini-vmのHTTP受付とiPhone上の復号表示を確認した。一般rotation helperと恒久的な
   secret store分担はpublic後に扱う。
2. 本人がhistory rewriteを選び、通常のremote branch / tagから到達可能な全履歴で旧鍵を
   置換した。GitHub管理の151 PR内部refsから到達する2,463 blobsも追加走査して旧鍵一致0件を
  確認した。全145 PRの現行公開面に候補と添付はなかったが、編集前内容、削除済みcomment、
  cached viewからの完全除去は主張しない。
3. 書換え後mainについてcurrent treeと取得可能なGitHub公開面を再監査し、workflow dispatchの
   required CIを成功させた。visibility変更後の匿名閲覧とGitHub-hosted CIは未実施である。

Bark cutoverの実施順は、候補生成・作業ツリー適用、review・CI・merge、green mainの
Pro / mini-vm適用、iPhone設定変更、両senderの受付と表示確認、clipboard clear、履歴処理、
finalizeであった。これは完了済みの記録であり、未実施手順ではない。

SOPS全面移行、private SSH includeの実配送、host固有metadataの追加一般化、recovery assetの
独立復旧はhardeningとしてpublic後に継続する。これらからactual secretまたは公開不能な個人情報が
最終scanで見つかった場合だけ、その項目を公開blockerへ戻す。

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

書換え後mainではLinuxの変更判定、secret scan、check、build、aggregate gateが成功した。
同じSHAのmini Ansible workflowはprivate課金制限によりportable jobがstep開始前にfailure、
native jobがskippedだった。public化直後に同一SHAをGitHub-hosted runnerで再実行し、
Nixのchanges・secret-scan・check・build・aggregate gate、Ansible portable、macOS nativeが
すべて成功した。pending、skipped、cancelled、結果欠落、過去SHAのgreenは
最終成功へ読み替えていない。

すべてのgateが揃った後に、本人が最終監査結果と残存リスクを読み、visibility変更を明示承認する。public化後は同じSHAのrequired checksと匿名閲覧面を再確認する。

## 2026-11-10 更新

- Bark新鍵をPro・mini-vmへ適用し、両senderの通知を本人がiPhoneで復号表示した。
- filter-repoで旧鍵だけを置換し、11 branches・2 tagsをlease付きatomic pushした。
  隔離mirrorの6,501 objectsで旧鍵一致0件、164 refsの先端treeは元と一致した。
  GitHub管理のPR内部refsは直接更新していないが、追加取得した151 refs / 2,463 blobsで
  旧鍵一致0件を確認した。cached view、編集履歴、添付からの完全除去は主張しない。
- mainのforce-push禁止、strict required checksを復元し、Pro・mini-vmを再同期した。
- 書換え後main `bccb272cde2337965b80845f2cca806b81c2caf1` のworkflow dispatchで
  changes・secret-scan・check・build・nix-ci-gateがすべて成功した。
  rewrite push自体は旧before SHAを追加fetchできず失敗しており、その結果は成功へ読み替えない。
- 全145 PRの現行本文145、issue comments 144、reviews 47、timeline本文191を走査し候補0件、
  GitHub添付0件、危険な構造の外部リンク0件を確認した。編集済みcurrent objectは108件あり、
  編集前内容はAPIから取得できない。公開準備以降の完了済みActionsログ17 runsも走査した。
- 本人承認で既存Actions cacheを全削除し、providerの残存件数0を確認した。
- 最終CIの短命runnerは登録・selector・token・state・work・logを撤去した。
- 本人が残存リスクを受容し、repositoryをpublicへ変更した。認証なしAPIと
  raw `flake.nix`の閲覧を確認し、同一SHAのGitHub-hosted Nix CIとAnsible portable /
  macOS nativeをすべて成功させた。

残る未確認範囲は、取得不能だった171 run attempts、PRの編集前内容・削除済みcomment・
cached viewである。これらの低リスクな不確実性は本人が明示受容した。現存artifact / release assetは
全件を機械走査したが、任意バイナリの意味論的安全性までは保証しない。旧鍵は現行通知には
使っていないが、過去の暗号化payloadへの影響は消えない。

### 追加監査

- 現存Actions artifact 5件とRelease asset 4件を取得し、内包bottleも展開して走査した。
  検出候補はビルド入力のSHA-256識別子と分類した。バイナリ内の全情報の安全性は保証しない。
- Actionsの1,014 completed attemptsを調査し、828は走査一致なし、171は取得不可
  （410が169件、404が2件）、15 attemptsに17件の候補があった。候補のうち7件（4種類）は
  build field上の64桁checksum、残り10件（2種類、10 attempts）は`Detect fzf update`が
  公開されたfzf更新入力を正規化してSHA-256化した`source_key`だった。credentialやApp鍵を
  入力にせず、field名の`key`にgitleaksが反応した誤検出である。全17件を非秘密の
  build/cache識別子と分類したため、監査・CI証跡であるログとrunは削除しない。
  取得不可171件はNix check 169件とbuild系2件だった。当時のworkflow定義全件で
  repository / environment secret参照、明示write権限、credential出力、環境全dumpは0件であり、
  低リスクと評価する。ログ本文と公開後の匿名表示は未確認である。
- 全145 PRの現行本文・issue comments・reviews・timelineを取得エラー0で走査した。
  secret候補とGitHub添付は0件、外部リンク139種類にもcredential名付きquery / userinfoや
  private / loopback / internal風hostはなかった。編集済みPR本文41件・issue comment 67件の
  編集前内容、削除済みcomment、GitHub cached viewは取得できず未確認である。
