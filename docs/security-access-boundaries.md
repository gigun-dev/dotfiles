# Pro・mini・mini-vm のアクセス境界

2026-11-01、main `fb0e18d` の宣言と既存の運用記録を整理し、下記の非root metadataと、明示承認を受けた限定sudo一覧・canary検証を追加確認した。実効権限全体の監査は完了していない。
「宣言確認」は checkout 内の設定、「既存観測」は過去の記録、「今回観測」は限定したmetadata、「未確認」は実測していない事項を表す。
process table と live ACL の読み取りは以前拒否されたため再試行していない。秘密値、鍵の内容、credential は採取していない。

## 今回観測したmetadata

Proはsandbox内の通常read-only、mini / VMはProから既存の直接SSH経路（BatchMode / StrictHostKeyChecking）を正規review後に使用した。mini→VMやLima経由へ切り替えていない。Pro→miniはsandbox内DNS失敗、同じ検証のreview済み実行は成功し、認証変更は不要だった。

| 実行元・対象 | 取得した範囲 | 確定できないこと |
|---|---|---|
| Pro | current UID=501。home `0750`、`.ssh` / `Library/Keychains` / `.config/git` は各 `0755`、ownerはcurrent UID。`/etc/nix/nix.conf` の trusted-users はroot/gigun、allowed-usersは `*` | directoryのmodeから中の秘密・keychainの利用可否は分からない。ACLとdaemonの現在のreload状態は未確認。sudoの限定観測は下表を参照 |
| Pro→mini | current UID=501。home `0750`、`.ssh` `0700`、`Library/Keychains` `0755`、ownerはcurrent UID。`/tmp/lima` と `/var/run/docker.sock` は当該pathに存在しなかった | 別socket・別共有・別UIDが無いとは言えない。keychainとNixの現在設定は未確認。sudo一覧は認証要求で停止 |
| Pro→VM | current UID=501、wheel所属、docker非所属。home `0700`、共有Mac home / `/tmp/lima` は `0750`。現在mountは両方virtiofsで `/Users/gigun` がro、`/tmp/lima` がrw。Docker socketは `0660`、owner=root、groupはcurrent groupsに含まれない。Nix trusted-usersはroot/gigun、allowed-usersは `*` | Docker socketへの接続やACLは未検証で、非所属だけで全経路の拒否を保証しない。sudo一覧でrootのNOPASSWD ALL規則を確認したが、root commandは実行していない |

取得は固定pathへのlstat、current groups、VMの `/proc/self/mountinfo` の共有2項目、Nix設定の上記2キーだけに限定した。NixとDockerのsymlink自体のmodeは実体のアクセス権として記載していない。


## 承認済みのsudo・canary検証

2026-11-01 05:51 UTCの明示承認に基づき、正規review済みcontextで実施した。sudoのhelpにはno-updateが広告されなかったため、各hostのインストール済み公式manualで `-N` / `-n` / `-l` の対応を確認した。実行したのはcurrent userの `sudo -n -N -l` のみで、stdinは閉じ、パスワード入力・timestamp更新・実変更commandは行っていない。生のsudo一覧は保存・公開せず、規則の有無だけをメモリ内で分類した。

| host / current user | sudo実効分類 | 未確認 |
|---|---|---|
| Pro / gigun / UID 501 | 一覧取得成功。root ALL規則とNOPASSWD規則の存在を確認 | root NOPASSWD ALLはこの要約で確認していない。認証キャッシュの有効性や個別NOPASSWD規則の対象は採取していない |
| mini / gigun / UID 501 | exit 1、認証が必要なため停止 | 一覧と実効規則は未確認。パスワード入力や別sudo経路への再試行はしていない |
| mini-vm / gigun / UID 501 | 一覧取得成功。root NOPASSWD ALL規則を確認 | 実root command、サービス固有の実行制約は未検証 |

canaryはminiの指定2directoryに各1個、予測困難な32桁random suffix・O_EXCL・O_NOFOLLOW・mode 0600で作成した。内容は固定の非秘密文字列だけで、鍵やkeychain内容を読んでいない。作成した絶対pathをprivate JSONLへ即時記録し、ProからVMへの既存直接SSHでその2ファイルだけを開いた。mini→VMやLimaの拒否経路は使っていない。

| mini上の作成先（各1個） | owner / mode | VM current userからの結果 | cleanup |
|---|---|---|---|
| `/Users/gigun/.ssh/.dotfiles-access-canary-<random32>` | mini UID 501 / GID 20 / 0600、VMではUID 501 / GID 100 / 0600 | gigun / UID 501で読取成功、固定内容一致 | finallyでdevice/inodeが作成分と一致することを確認して削除し、不在確認 |
| `/Users/gigun/Library/Keychains/.dotfiles-access-canary-<random32>` | mini UID 501 / GID 20 / 0600、VMではUID 501 / GID 100 / 0600 | gigun / UID 501で読取成功、固定内容一致 | 同上。owner processもexit 0 |

絶対pathと各phaseのprivate JSONLは作業workspaceに保持し、SHA-256は `2e9dda15d84a94c429f7a8d4a46e582feae68981f8e4e860ed3186519889b0d4`。実機実行前には一時directoryで作成・読取・finally cleanupを合成検証した。既存ファイル、権限、ACL、keychain設定、サービス状態は変更していない。

## 人とエージェントの権限

現行の開発用エージェントは人と同じ `gigun` で動く構成が中心で、プロンプト上の役割分担は Unix のアクセス境界にならない。
同じ UID から読めるファイルや利用できる socket・署名機能を、人だけの権限として扱わない。

| 対象 | 宣言確認・既存観測 | 未確認と意味 |
|---|---|---|
| Pro の人 / エージェント | [darwin/system.nix](../nix/modules/darwin/system.nix) は主ユーザーを `gigun`、Nix trusted-users を `root` / `gigun` にする。sudo は Touch ID と reattach、Apple Silicon では Watch 認証も宣言する | sudo一覧でroot ALLとNOPASSWD規則の存在を確認。認証キャッシュや個別規則の全体は未確認。trusted な同一 UID のエージェントを低権限の Nix client とみなせない |
| Pro → mini | [Ansible inventory](../ansible/mini-macos/inventory.yml) は `gigun` で SSH、BatchMode と StrictHostKeyChecking を使う。[mini 管理記録](mini-ansible.md) は Pro を controller、mini を対象とする。今回の直接SSHは成功 | 認証鍵の内容・種類は採取していない。Ansible の対象選択や acknowledgement はユーザーの適用承認を代替しない |
| mini の人 / エージェント | [mini 管理記録](mini-ansible.md) は既存 Nix generation 26 を残し、採用済み shell / defaults / CLI だけ Ansible に移す。認証・sudo・trusted-users の変更は移行対象外 | 凍結した Nix 宣言を現在の実効 sudo / Nix 設定と同一視しない。別 UID の build 用ユーザーがあるという宣言は確認できていない |
| mini-vm の人 / 常駐エージェント | [mini-vm.nix](../nix/modules/nixos/mini-vm.nix) は Lima のユーザー作成を許す `mutableUsers=true`、wheel のパスワード不要 sudo、Nix trusted-users=`root` / `gigun` を宣言。今回wheel所属と設定ファイルのtrustを確認。Codex / agy の system service は `User=gigun` | sudo一覧でroot NOPASSWD ALLを確認。常駐エージェントも `gigun` の読み書き範囲を共有する |
| VM の管理サービス | 同モジュールで autoswitch 等は root、Codex / agy 等は `gigun`。サービス単位で実行主体が異なる | system service というだけでは隔離を保証しない。各 unit の writable path、実効 capability、到達可能なサービスは今回未観測 |
| 未導入 Linux CI 案 | [opt-in module](../ci/linux-runner/mini-runner.nix) は専用 `dotfiles-ci`、追加 group なし、ephemeral runner、boot 起動なし。Docker / agenix / Tailscale socket 等を隠す | 未 import・既定無効。ユーザー作成・runner 登録済みとは扱わない。[既存評価](linux-ci-fallback.md) のとおり共有 kernel / network / store の制約は残る |

2026-11-09、realbind は他の個人開発と同じ trust domain として扱い、専用 VM / UID へ分離しないと
決めた。この判断は上表の同一 UID・trusted user・passwordless sudo のリスクを解消するものではなく、
個人開発環境として受容する範囲を定めたものである。checkout を分けることもアクセス境界とは扱わない。

## SSH とネットワーク

[Tailscale テンプレート](../tofu/tailscale/policy.hujson.tftpl) はタグ間の IP grants を広く許す一方、SSH のユーザー許可は別に定義する。
admin-device → server は root / ubuntu と nonroot、admin-device → client / storage 等は nonroot が対象である。
storage を起点にした SSH 許可は記述されていない（退避用だった storage → proxmox の root は 2026-11-09 に外した）。今回提供された mini → VM の `TAILNET POLICY DENIED` は実際の拒否の記録として保持し、別経路で迂回しない。
テンプレートから現在の端末タグ・最終 policy・到達性までは確定できない。これらは [ADR 0010](adr/0010-tailscale-policy-as-code.md) の非公開値を含む管理範囲である。

VM の OpenSSH は password / keyboard-interactive 認証を無効にする宣言がある。
[共通 SSH 設定](../nix/modules/home/programs/ssh/default.nix) は Linux の IdentityFile を固定せず、Mac の仮想化ツール用 Include を Mac に限定する。
SSH 認証、Git の HTTPS credential、Git の SSH 署名は別の用途として確認する。署名成功から SSH ログイン可能とは判断しない。

## Docker・Nix・共有ファイル

| 境界 | 宣言から確認した範囲 | 残る確認 |
|---|---|---|
| VM Docker | [Langfuse module](../nix/modules/nixos/services/langfuse.nix) が Docker を有効化。[Beszel module](../nix/modules/nixos/services/beszel.nix) は専用ユーザーに docker / disk group を付ける。今回current UIDのdocker非所属とsocketのowner/modeを確認 | Docker socket を操作できる主体は VM の管理権限に近い。ACL・接続可否・他サービスの実効権限は未確認 |
| Mac の container | [apple-container module](../nix/modules/darwin/apple-container.nix) はユーザー権限へ降りて起動する | Docker socket と同じものとして扱わない。mini の現在の container / Docker 導入・socket 権限は未確認 |
| Nix store / daemon | Pro / VM は上表の trusted-users を宣言。通常 switch / update からの Cachix 自動送信は廃止済み（[方針](security.md)） | store は秘密の保管先にしない。専用 CI の非 trusted client も daemon に build を依頼し store と disk を共有する。公開 cache への送信主体は未決定 |
| mini → VM の共有 | [mini-vm.nix](../nix/modules/nixos/mini-vm.nix) は `/Users/gigun` を virtiofs read-only、`/tmp/lima` を read-write で mount。今回のVM側mount metadataは宣言と一致し、指定2pathの0600 canaryもVMから読めた | read-only は機密性を保証しない。共有 home 内の個別ファイルの読取範囲・ACLは未確認。VM root からの読み取り可能範囲も確定していない |
| checkout / user 設定 | [agent execution](agent-execution.md) と Guard は checkout 衝突を防ぐ運用を定義する。home-manager の out-of-store symlink は repo を参照する | 専用 checkout はファイル競合の対策であり、同じ UID の credential / keychain / home を隔離しない。設定の実機適用は別途判断する |

## Git 署名と復旧

Pro の [Secure Enclave 宣言](../nix/modules/darwin/secure-enclave-key.nix) は鍵をホストごとに保持し、`protection=none`、既定署名有効、GitHub `autoAdd=false` とする。
鍵を取り出せないことと、ログイン中の同一 UID による署名利用を防ぐことは別である。
GitHub 登録と Verified の確認は進行中の署名作業に任せ、この文書では完了扱いにしない。
mini の鍵は保持済みという今回の作業前提を採用し、再生成しない。[Ansible signing_tools](mini-ansible.md) は実行ツールの staging と選択を扱い、Git 設定や鍵登録までの承認ではない。

[既存 iOS 署名記録](mini-vm.md#mini本体でのiosビルド署名) には mini の GUI ログイン session で archive / Ad Hoc export が成功し、SSH では identity が見えない場合があると記載されている。
これは現在の keychain 状態の確認ではない。SSH の失敗を鍵の消失と判断し、再作成・自動ロック無効化・パスワード保存へ進まない。

復旧では、対象を限定した [Ansible の rollback](mini-ansible.md#管理境界と復旧) と [VM の更新・健全性確認](mini-vm.md) を使い分ける。
Nix 世代の rollback は DB データを巻き戻さない。Langfuse の DB 復旧は既存の cold backup 手順と別承認を要する。
端末紛失・侵害・YubiKey 紛失は [security.md の未決事項](security.md) に残っており、アカウント・GitHub 鍵/トークン・Access session・クラウド credential の失効順を検証済みとは扱わない。

## build / sign / publish の最小分離案（未適用）

Pro は管理・レビュー、mini は対応 SDK の Mac build と署名、VM は Linux 常駐サービスとする。
専用フレームワークを足さず、標準 asc の工程を分ける。2026-11-01 に Pro の `asc version` は 5.9.2、下記の `--help` を read-only で確認した。
mini の 5.17.1 導入記録は [mini 管理記録](mini-ansible.md) にあり、実行 host ごとの版と help を承認時に再確認する。

| 工程 | 使用する標準機能・受け渡すもの | 与える権限と受入条件 |
|---|---|---|
| build | `asc xcode archive` の workspace/project・scheme・archive-path と追加 xcodebuild flag。Simulator test / 署名なし build から始め、commit SHA・SDK・tool version・artifact hash を記録 | build 主体には配布 identity・ASC / R2 の書込 credential を渡さない。署名なし archive が成立するかはプロジェクトごとの検証が必要で、export 可能とは未確認 |
| sign / export | `asc signing run` は temporary keychain に identity を import し、child の間だけ利用、redacted receipt を保存できる。child に `asc xcode export --signing-style manual --method release-testing --ipa-path ...` を渡す案 | 人が承認した archive hash と profile / identity の組を入力する。既存のホスト固有・非 exportable identity を P12 とみなさない。temporary keychain も同一 UID / root からの完全な隔離ではない。別 Unix 主体への移行は別承認 |
| publish | 署名済み IPA と hash を受け取り、`asc publish appstore --ipa ... --dry-run` で plan を確認する。`--submit` と `--confirm` は独立した公開承認後にだけ指定 | publisher だけに必要な ASC / 配布先の権限を付ける。build mode の publish を選ぶと工程が再結合するため、この案では prebuilt IPA を渡す。upload / metadata 更新も外部変更として別承認 |

`asc xcode export` は既定が automatic signing / app-store-connect で、ExportOptions の `destination=upload` なら直接アップロードする。
ローカル export では method、manual signing、ローカル IPA の出力先と ExportOptions をレビューする。`-allowProvisioningUpdates` を通常 build に無条件で加えない。
`asc signing sync` は標準の暗号化共有機能だが、秘密 identity の配布先を増やすため、この最小案の前提にしない。
App Store 用 signing run の対応 purpose は今回の help では `release-testing` のみであり、App Store export へ一般化しない。

build を同じ `gigun` のまま分ける第一段階では、誤操作を減らすことまでが効果となる。
強い隔離を必要とする場合は、専用 Unix ユーザーまたは別 VM を選び、credential を持つ既存 GUI runner の扱いを先にレビューする。
未導入 Linux CI 案を mini の署名 runner と同一視せず、runner 登録や現行サービスの変更はこの PR で実行しない。

## 限定検証後に残る境界

VMのcurrent userにはroot NOPASSWD ALL規則があり、共有homeの指定2pathに置いたowner-only canaryも同じUIDから読めた。したがってread-only共有と0600だけでは、この経路での機密性や人・エージェント間の隔離を保証できない。これはcanaryの結果であり、実際の鍵・秘密の読取、keychainのunlockや署名利用可否を検証したものではない。

miniのsudo一覧は認証要求で未確認のまま。必要なら本人が一覧を確認して最小の権限分類を返す手順を別途決める。認証要求を回避したり、root・sudoers・ACL照会に広げたりしない。以前拒否されたprocess-table / live ACLは再試行していない。

実運用前には、共有homeを必要なartifact領域に絞る案と専用UID/VMの案を比較し、credentialを持つ既存GUI sessionとの受渡しを設計する。共有・ユーザー・権限・サービス変更、署名テスト、upload / submissionは引き続き別承認で、この検証では実施していない。署名はアプリ・archive hash・profile・identity・出力先を固定した個別テスト、publishは対象とcredentialを固定したdry-run reviewが必要となる。

工程の分離は提案段階なので新ADRは作らない。既存の管理所有者を変更する決定にはしていない。
