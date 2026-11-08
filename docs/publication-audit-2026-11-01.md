# 公開前監査 2026-11-01

公開可能との判定ではない。[公開準備](publication-preparation.md)の gate を実測で補う。基準 main は `fb0e18dc953f3030ea3ac466c3359a5af8a4716d`。専用 clone / `audit/publication-coverage` で調査し、実機設定は適用していない。

## 実測範囲

| 資料 | 確認方法・結果 | 限界 |
|---|---|---|
| 現行 tree | tracked 280 files。公開準備・security の章構成・inventory・SSH・秘密宣言・CI 宣言を確認 | 全文の機密性判定は未完 |
| 到達可能 Git objects | 既存ローカル clone 由来 refs と取得した main から `rev-list --objects --all`、4,589 objects / 628 commitsを列挙し、うち1,825 blobsの内容18,878,274 bytesを下記4形式で検査して一致0。commit messageとtree pathname自体は内容検査していない | remote 全refs取得の証明ではない。unreachable objects、削除refs、PR専用refsは対象外 |
| 運用情報の履歴 | `git log --all -- docs/security.md` は22 commits、実inventoryは2 commits | 現行版の置換だけでは履歴を消せない |
| PR / issues | `gh pr list --state all --limit 200 --json number,body,comments` で119 PR本文・118会話コメント。4形式の一致0。通常issueの全state一覧は0件 | inline review / review本文 / diff / 添付 / 削除済み内容は未検査。PR本文に運用語句候補あり |
| Actions | latest10 run metadata。既知 PCRE2 run `40437718383` の取得ログ67,928 bytesは4形式の一致0 | 全runログ、全attempt、cache bytesは未検査。先行調査の694 runという総数は今回再計測していない |
| PCRE2 artifacts | 同runの `pcre2-build` / `pcre2-verified` をローカル取得。補助ファイルとbottleの通常ファイル241件を各々読み取り検査し4形式の一致0 | archive内コードは実行していない。形式外の秘密、内部情報の意味判定は未完 |
| Releases | release一覧2件。PCRE2の `validated.json` 1,359 bytesとbottle 2,510,246 bytesを取得。JSON top-level fieldsはasset/formula/platform/provenance/reproducibility/verification/version。4形式の一致0 | 追加検査でfzfの2 assetsと両Release本文も検査（下記）。Release編集履歴は未検査 |
| 非公開正本 | 索引例は未記入。指定の `docs/private/` は今回cloneにも既存主checkoutにも見つからない | 他の保管先がないとは言えない。実在backup・hash・再読取・権限・復旧可能性は未確認 |

4形式は private-key PEM/OpenSSH header、GitHub token (`gh[pousr]_` / `github_pat_`)、AWS `AKIA` access ID、Google `AIza` API key。Python標準ライブラリの正規表現で値を出さず件数だけ出力した。新scannerの導入はしていない。形式限定であり、汎用password、OAuth client secret、他provider、分割・符号化済み値の不在は示さない。age ciphertextは復号していない。

PCRE2 bottleのSHA256は build / verified / Release で全て `16b7d45ac5e4604605bae87a2faae5a84271c4c71b8a83bd871838f1c155b19b`。artifact期限切れでもReleaseコピーは残る。ローカルで読み取った通常ファイルと補助資料の合計は build 7,378,539 bytes、verified 7,378,622 bytes、Release 7,362,273 bytes（圧縮bottle自体のサイズとは異なる）。

履歴検査refsは local main / audit branch と `origin/{HEAD,main,chore/public-preparation,feat/mini-ansible,feat/mini-ripgrep-adoption,fix/portable-iterm-hook,fix/xdg-in-zshenv}`。main以外のremote-tracking refsは元cloneのsnapshotであり最新性未確認。tag refsはこのcloneで0件。先行調査で拒否された `/tags?per_page=100` と fzf per-workflow runs endpointは再取得・別routeでの迂回をしていない。

## 公開前に扱う情報の種類と所在

- `docs/security.md` L17の「dotfiles は public」は、現在privateである実状態と矛盾する。公開済みと解釈せず、公開判断・文書一般化の際に修正する。backup確認前の個人運用原文はこの監査では保持する。
- `docs/security.md` はアカウント・鍵の役割、配置、既知の抜け道、復旧・移行計画を含む。値の検出とは別に、個人運用の分離判断が必要。
- `AGENTS.md`、`docs/mini-vm.md`、関連運用docs、`todo.txt` はホスト運用・アクセス境界・復旧のメタデータを含み得る。公開可能な再現手順との一文単位の分類が必要。
- `ansible/mini-macos/inventory.yml`、`nix/modules/home/programs/ssh/default.nix`、`tofu/`、`secrets/secrets.nix` は接続先・利用者・鍵参照・リソース・暗号化受信者の分類対象。
- PR本文の運用語句候補は #34, #35, #36, #38, #64, #81, #93, #99, #105, #106。`FileVault|~/.ssh|Tailscale|復旧|秘密|inventory` の候補抽出であり、それだけで秘密露出とは断定しない。review/patch等も含め公開可否を精査する。

## 最小の次の手順

1. 本人管理の既存非公開保管先を特定する。security原文・接続設定・復旧手順について保全対象と責任者を決め、hash、再読取、権限、別backupをread-only確認する。例示索引や旧Git commitを証明にしない。新規外部保存は別承認。
2. 保全確認後、公開側securityを一般原則にし、運用情報を切り分ける。inventory/SSHは既存挙動を維持する別変更とする。
3. 最新全refsと全履歴の範囲を合意する。履歴に残す情報の判断を記録する。rewriteや別repo化が必要なら対象・影響・保全を具体化して別承認を得る。
4. PR review/inline/patch/添付、全runログとcache、Release編集履歴を追加監査する。制約で取得できない対象は未確認のままgateに残す。秘密の有効性テストはしない。
5. 直前mainとの差分と追加run/assetsを再検査し、全gateを本人が判断する。削除・rotation・visibility変更・mergeはこの監査の許可範囲外。

`todo ready` は既存の重複 `id:0116` を報告した。この監査では別タスクを改番していない。


## 追加検査（同日、PR #121 作成後）

- fzf Releaseの `fzf--0.74.5.sequoia.bottle.tar.gz` 2,402,197 bytesと `validated.json` 1,616 bytesを取得。archiveの通常ファイル19件とJSON、計6,011,998 bytesを同じ4形式で読み取り検査し一致0。bottle SHA256は `45957f1abe8b2c450629c09c3ed9afa31feb8bc16935417949b387f53249e689`。tag末尾のkeyとは別の値であり、同一性の根拠として混同しない。JSON top-level fieldsはschema/key/status/checks/files/environment/build_environment/inputs。
- 既知の2 Release本文（PCRE2 931文字、fzf 76文字）も4形式の一致0。#105 / #106 のreview一覧は各0件。全PR review / inline / 添付・Release編集履歴の確認には拡張できない。
- 既存主checkoutと今回cloneの `docs/private/` に加え、既存のdotfiles state / libディレクトリのファイル名をread-only確認した。security/inventory/backup/recoveryに一致する候補は各0件。両ディレクトリのmodeは0755。これは他のprivate保管先やOS backupの不存在を証明しない。新規コピー、外部upload、秘密の読取・復号は行っていない。

### 個人運用情報の残存候補

基準treeのキーワード一致行数を示す。一般説明や参考リンクも数えるため、全行が機密という意味ではない。種類が重なる行は両列に入る。値や本文は転載していない。

| 所在 | 総行数 | アカウント・鍵・復旧候補 | ホスト・アクセス・配置候補 |
|---|---:|---:|---:|
| docs/security.md | 117 | 23 | 9 |
| AGENTS.md | 153 | 0 | 8 |
| docs/mini-vm.md | 316 | 6 | 8 |
| todo.txt（本監査commit時点） | 53 | 6 | 3 |
| nix/modules/home/programs/ssh/default.nix | 116 | 5 | 25 |
| secrets/secrets.nix | 111 | 4 | 5 |

候補抽出は前者 `アカウント|秘密鍵|復旧|紛失|PIN|YubiKey`、後者 `Tailscale|FileVault|自動ログイン|IdentityFile|HostName|~/.ssh|/Users/|/home/|接続先|保管`。実inventoryは10行で、この語句に一致しなくても接続情報の分類対象である。キーワード検査は意味による判定の代用にはならない。

### backupが未特定の間の保全案

本人が管理する既存の非公開・暗号化保管庫を指定し、原文security、実接続設定、復旧手順の保持範囲を決める。指定後に保管物のhash、本人だけのアクセス権、再読取、独立したbackupと復元方法を確認する。参照索引には値を書かず、保管場所自体が機密なら索引も非公開にする。既存保管庫がない場合は本人が方式と保管先を選び、新規保存の承認後に保全する。repo内ignoreディレクトリや旧commitだけでこの条件を満たしたことにはしない。

## 再監査 2026-11-09

PR #137のtree `e55f972` と、その時点のmain `73c86e8` を基準に範囲を更新した。GitHub上はprivateのまま、全10 branch headと全2 tagがlocal remote refsに一致した。全138 PRの本文・137会話comment・47 review・全patchを取得し、pagination欠落、inline thread、添付URL候補、値非表示のgitleaks一致はいずれも0だった。Releaseは2件・4 assets、Actions artifactは10件を非実行で展開して走査した。845 runsのうち575 nonempty logsを走査し、100 empty archives、170取得不能を記録した。一時取得物は削除済みで、監査後に増えた6 runs、14 caches約10.9GB、取得不能logs、Release編集履歴は未確認である。

repo内のgitleaks候補は、全履歴10件とcurrent tree 4件を値を表示せず個別分類した。10件は削除済みvendored公式文書のplaceholder 6件、公開JWT audience 1件、temporary test fixture 3件で、current 4件も後二者に含まれる。いずれもactual credentialではなく、provider失効、rotation、履歴rewriteは不要と判断した。repository-wide allowlistは使わず、current候補は必要ならdummy生成または理由付きの狭いinline許可へ直す。Actions artifact 2件、取得済みlogのunique 2種類、Release 1件の候補は、削除済み一時資料を再取得していないため未分類のままである。

判定は引き続き**NO-GO**。非公開正本・独立backup・限定restoreの実証、外部成果物の候補分類、実inventory・SSH・運用metadataの公開版への分離、未確認Actions範囲と最終SHAの再監査が済むまでvisibilityを変更しない。repo内候補だけを理由に履歴を書き換えない。

## 未push変更の追跡 2026-11-09

remote branchの `29c1a4c` から内容変更 `f855635` まで13 commitsを検査した。この監査記録自身はその後のcommitに含まれるため、最終SHAの証拠には使わない。追加差分についてprivate-key header、GitHub token、AWS access key ID、Google API key、age recipientの高確度形式を値非表示で検査し、差分・現行tree・commit message・pathnameはいずれも一致0だった。`1b15485..f855635` の3 commitsはpatch 61,263 bytesをfull gitleaks rulesで追加検査して一致0である。current treeのfull-tree gitleaksも既知fixtureを狭く整理した後に一致0である。これは形式外の秘密や運用metadataの公開可否を証明しない。

追加された分類対象は次の5群である。

- agent harness、Apple Seatbelt、network sandbox、standalone agent権限
- realbindを含むtrust domain、Nix trusted user、sudo、root相当性
- SOPS recipient grouping、YubiKey、ciphertext数を含む秘密管理topology
- Cachix writer不在とcredential経路
- PR、対象SHA、self-hosted runnerの受入・撤去状態

これらは実credential値ではないが、従来より具体的な防御・運用metadataである。`docs/agent-harness-boundaries.md`、`docs/execution-context.md`、`docs/security-access-boundaries.md`、`docs/linux-ci-fallback.md`、`docs/credential-inventory.md`を公開境界の判断対象へ追加する。push後はPR #137のpatch、本文、comments、reviews、inline thread、添付、追加Actions run / attempt / log / artifact / cache、required checks、生成merge SHA、Release増分、最終mainとの差分を最終SHAで再走査する。未pushの検査結果をremote公開面の確認に代用しない。

## GitHub公開面の増分確認 2026-11-09

GitHub APIとread-only downloadで、監査後に変化したrefs、PR、Release、Actionsの現在値を再確認した。repositoryはprivateのままで、visibility、refs、PR、Actions、artifact、cacheには変更を加えていない。

- remote branchは11本で、main以外の10本にbranch protectionはない。local監査branchはremote headより13 commits先であり、remoteのgreen checksはlocal最終候補SHAの証拠ではない。
- tagとReleaseは各2件、Release assetは4件である。Release本文、archive member path、展開後の一般的な内部path・host語、全assetのgitleaksを値非表示で検査した。gitleaks候補1件はRelease tagにも使われる公開build keyで、credentialではないと分類した。全remote branch固有のtreeと到達可能履歴は未走査である。
- PR #137はopenで、remote headのchecksは成功、reviewとinline review commentは0、user attachmentは0である。本文・会話comment・current patch・current成功run logのgitleaksは一致0だった。bot comment、force-push timeline、PR patchにはrunner、CI fallback、credential/recovery文書などの運用metadataが残るため、current treeだけを一般化しても公開判断は閉じない。
- GitHub上のactive workflowは8件だが、local最終候補には6件しかない。remote mainに残る旧workflow 2件は、最終SHAを反映してGitHub側のworkflow一覧が収束するまで公開面に残る。
- Actions runは868件で、基準監査から23件増えた。以前の取得不能170件と増分23件を少なくとも未確認として扱う。最新100 runsにもfailure、cancelled、action-requiredがあり、成功runだけの検査では足りない。
- active artifactは10件、約26.7 MBである。既存監査で未分類だった候補2件を含め、非実行展開と再分類が必要である。cacheはmain由来14件、約10.9 GBでbytes未監査である。workflow宣言はNix store以外を保存しない設計だが、現存cacheの内容証明にはならない。

公開直前には、最終SHAの全refs・履歴・PR面・全増分run / attempt / log / artifactを再走査する。取得不能logは未確認のまま明示する。cache bytesを監査できない場合は削除後に最終workflowから再生成する案が最も確実だが、cache削除は破壊的な外部変更なので別承認なしに行わない。
