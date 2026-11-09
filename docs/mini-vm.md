# mini-vm の運用

旧 `docs/next-directions.md`(2026-09-10 に廃止)から降ろした mini-vm 関連の調査メモ。
決着済みの経緯と、未解決のまま残っている調査項目をまとめる。

## 運用ダッシュボード

host内のresource監視と、host外からのliveness監視を分ける。host内dashboardが見えることを、
host自体の生存証明にしない。Web UIはloopbackまたはprivate networkで待ち受け、外部入口は
Cloudflare Access等の認証境界を通す。SDK用の非対話入口はpathとproject credentialを限定する。

service、port、tunnel、monitoring scheduleの正本はNixとOpenTofu宣言であり、完全URLや現在の
provider resource対応をこの文書へ複写しない。障害時はlocal health、tunnel、Access、外部probeを
別々に確認する。

## Claude の設定

`~/.claude/settings.json` は Mac (Darwin) では `claude/settings.json` を正本として home-manager が
deep merge する (`nix/modules/home/dotfiles.nix` の `configureClaudeSettings`)。mini-vm など Linux の
home 層では merge せず、`claude/settings.json` は設定例として参照できるが、端末固有のパスなどを
確認せずコピーしない。hooks のスクリプトや commands、agents は従来どおり配布する。
新規環境は Claude の既定設定から始めることもできる。

既存の symlink はこの変更だけでは通常ファイルにならない。移行は別途、Claude や他の書き手が
設定を更新しない時間に、実ファイルの内容と mode をバックアップして検証し、同じ内容の通常ファイルへ
置換する。作業前後に byte と mode を確認し、バックアップを保持する。通常ファイルの場合は上書きしない。
移行と checkout 同期の順序を確認し、旧 Home Manager の activation が symlink を再作成できる間は
checkout を clean にして autoswitch を再開させない。新設定を含む main の適用と移行は別途判断する。

## mini-vm の自動更新 (2026-09-06 実装)

**動機**: 無人機なので手で `pull && switch` を打つ機会が無く、push 済みの変更が届かないまま
気づけない(cloudflare-os で実際に 106 コミット遅れた)。

timer の時刻(autoswitch 04:00 など)はすべて JST。mini-vm のシステム timezone は 2026-10-16 から
`Asia/Tokyo`(それ以前は未設定の UTC で、timer が JST の +9 時間後に発火していた)。

**設計の要点**(実装は `nix/modules/nixos/mini-vm.nix`):

- **lock 更新の提案と適用を分ける。** `dotfiles-lock-propose@fast`(毎日) / `@slow`(日曜)が
  lock 更新 → 実機ビルド → PR・auto-merge 設定まで行い、required CI の成功で merge する。
  人の lock 差分レビューは前提にしない。`dotfiles-autoswitch` 自体は lock を更新せず、
  merge 済みの変更を fetch → CI ゲート → ff → switch → 健全性確認する。失敗時の復帰先は今回の
  開始時に稼働していた構成だけとし、Langfuse の image pair が変わる場合は戻さない。
- **proposalのGit状態を稼働用から分ける。** fast / slow / Langfuseは上流mainから
  StateDirectory内の一意な専用directoryへ独立cloneする。worktreeやlocal cloneの共有objectを
  使わず、稼働checkoutのfetch・refs・worktree登録を触らない。Langfuseの比較元も取得した
  mainのComposeとする。候補をcommitしてからVMでbuildし、その同じHEADを提案する流れは維持する。
  成功時は自分のcloneだけを削除し、失敗時はcloneと既存logを調査用に残す。失敗候補は手動で
  確認・整理する必要があり、取得量と一時disk使用量もworktreeより増える。過去のworktree領域と
  登録情報はこの変更では削除しない。既存のcheckout存在条件、認証・Git identity、schedule、
  PR/auto-merge経路とautoswitchのCI/health/DB保護は変更しない。専用cloneは同じHOMEのglobal
  Git設定とcredential helperを使うが、稼働checkoutのlocal設定は引き継がない。実機固有の
  identity/認証overrideと上流への実認証は適用前に確認する。秘密や設定のコピーは行わない。
  Actions移行や新しい排他は前提にしない。
  localのhooksPathはbootstrapとHMが稼働checkoutに設定する。追跡済みpre-commitはstage済み
  `.nix`の整形だけで、proposalがstageするlock/YAMLは対象外である。適用hookはNixOSと
  linked worktreeでは既に停止する。独立cloneへの非継承でこのproposalの安全検査は落ちず、
  既存CIのformat/buildと適用後healthは維持する。実機に追加・変更されたhookがあれば別確認する。
  失敗通知時は既存Beszelのdisk使用率と各StateDirectoryの保持候補数・容量を確認する。
  自動削除や保存期限は追加しない。job静止と候補の所有者・対象pathを確認し、必要な候補とlogを
  保全してから不要な専用cloneだけを人が整理する。容量不足なら再試行前に整理し、稼働checkoutや
  旧worktree登録を一括削除しない。レーン共通の既存logは次回実行で更新され得るため先に保全する。
- **CI green の commit だけを適用する**(2026-10-15、`docs/adr/0011-push-without-a-local-gate-and-apply-only-green-commits.md`)。
  手元の pre-push 関門を外したので、main には CI 前の commit が直接入る。autoswitch は fetch した
  `@{upstream}` の commit について `gh api repos/gigun-dev/dotfiles/commits/<sha>/check-runs` を
  gigun の gh 認証で読み、GitHub Actions の check run が全て success / skipped / neutral で終わり、
  required の `nix-ci-gate` が success なら green としてその commit へ `merge --ff-only` する。
  paths-filter で nix 以外の commit の check/build が skipped でも、常時実行する gate が整合性を検証する。
  gate 自体は success 以外を green にせず、未出現・実行中は pending、skipped / neutral / failure 等は red にする。
  他jobの red(失敗・cancelled 等)も即座に、pending(未完了)は
  60 秒ごとに fetch し直して最大 30 分待ち、それでも終わらなければ**見送り**: unit は成功で終わり、理由を `dotfiles-autoswitch-notify-skip` が Bark へ送り、
  成功 heartbeat も送る。翌日の timer が判定し直す。API が引けない(認証切れ等)は見送りではなく
  失敗として既存の失敗通知へ流す。作業コピーが upstream より先行していても止める。
- **`system.autoUpgrade` は使わない。** home 層が視野の外(`nixos-rebuild` しか叩かない)で、
  unit の pre/post 拡張は可能だが、共有 standalone home と Langfuse の世代比較を同じ
  coordinator で扱う既存構成を保つ。更新器の `restartIfChanged = false` と
  `X-StopOnRemoval = false` は NixOS 標準の自動更新に揃える。
- **`--flake github:...` の直接参照も却下。** 手動 switch(作業コピー)と自動更新(github:)で
  真実が二重になり、「いま動いている rev」を作業コピーから読めなくなる。ローカル pull なら
  食い違いが dirty ガードで鳴る。
- **dirty ガードは検知器**。作業コピーが汚れている = 誰かが VM 上でいじって放置した、なので
  踏み潰さず止めて通知する。
- **更新器自身を途中で再起動しない。** 2026-10-04 の system switch が更新器を SIGTERM し、
  再起動した更新器が実行中の activation unit と衝突した。coordinator は pull 後の commit を
  固定して system を一度だけ switch し、選んだ世代と実稼働先の一致を確認して同じ invocation の
  まま新世代の helper へ `exec` する。helper の PATH、home-manager、健全性ゲートは新版固定。
  checkout が後から変わっても home は同じ immutable flake snapshot を読む。
- **復帰先のゲートで再確認する。** image-pair guard と開始時の世代だけへの復帰を保ち、
  rollback 後は復帰先の公開 gate を使う。修正前の世代に公開 gate がない場合は未検証として失敗を
  報告する。初回修正は updater が実行中でないことを確認し、独立した SSH runner から適用する。

Langfuse の DB migration は OS 世代の切替では戻らない。image の変更後に gate が失敗したら、
移行先の世代と対応 image を維持し、既存 Bark へ失敗通知を送る。同じ候補を再試行しても
履歴上の旧世代へ遡らず、翌日の timer は修正版または同じ候補を再確認する。image が不変の
OS 更新だけは今回の開始時の構成へ戻せる。build が失敗して適用されていなければ現在のサービスを維持する。

通知は暗号化処理が失敗したら送信を止め、HTTP と JSON `code=200` の receipt まで確認する。
端末表示はこの receipt とは別に確認する。
失敗時は `journalctl -u dotfiles-autoswitch -u dotfiles-autoswitch-notify-failure` と Langfuse readiness を
読み、移行済み DB に対応する image の対を保った修正版を main へ出す。DB の migration 番号変更や
旧 image だけへの復帰は行わない。

DB を伴う手動復旧前は Compose を停止し、Postgres / ClickHouse / MinIO / Redis と ClickHouse logs の
5 named volumes を root 専用ディレクトリへ cold backup する。checksum と隔離展開後の byte / metadata
比較を確認し、backup を削除せず維持する。現在の受け入れ根拠は
[`langfuse-recovery-result-2026-10-03.json`](langfuse-recovery-result-2026-10-03.json)。
- **uvx で取るものはこの経路に乗らない**。`codex-openai-bridge` が動かす
  `openai-api-server-via-codex` は nixpkgs に無く実行時に PyPI から取るため、lock にも
  required CI にも現れない。`codex-openai-bridge-refresh`(日次)が別レーンとして追従する。
  autoswitch と意図的に分離してある。uvx の不具合で Nix の健全な generation を rollback しても
  uvx の版は戻らず失敗を繰り返し得るため、refresh の成否を健全性ゲートに含めない。

**実績** (2026-09-08 時点): PR #1〜#5 が全て merged、CI も直近 8 run 全て success。
設計は当初「手元でレビューしてから merge」だったが、lock 差分は人に判定できないと結論し、
2026-09-06 に lock 提案 + required CI ゲートによる自動 merge・適用へ切り替えた。

**残っている穴**: 失敗は鳴るが**沈黙は検出できない**。自動再起動は導入していない。
ホスト再起動後の復帰検証(「mini-vm 再起動後に codex-remote-control が復帰し、スマホから
繋がるか確認する」)は完了済みで、自動再起動の導入とは区別する。
もう 1 つ、**required CI は admin 権限の直 push でバイパスできる**(下記「未解決の調査メモ」)。
mini-vm への適用は上記の CI ゲートで塞いだが、main 自体には CI 前の commit が入る。

## codex-bridge の版検出失敗時

`codex-openai-bridge-refresh` は稼働版が空/欠落/`unknown` のとき、再起動せず
実プロセスから版を再検出する。それでも不明ならその回の更新を止める。
連続2回の検出失敗で既存の `OnFailure` → Bark 通知を一度だけ発火し、
以降も日次の再検出を続ける。状態は `/var/lib/codex-bridge-refresh/` に残すため、
ホスト再起動でも通知済みを忘れない。版が読めた回で連続失敗/通知済みを消し、
通常の版比較へ戻る。停止中の bridge は起動しない。

通知の発火記録は通知配送の成功を保証しない。実通知と端末表示は別途受け入れる。
失敗を確認するには `journalctl -u codex-openai-bridge-refresh.service` と
`cat /run/codex-bridge/version` を見る。unknown は uv のキャッシュレイアウト依存の
検出が壊れた可能性を表し、bridge 本体の障害とは限らない。

現行の配備・隔離検証・通知受付の根拠は
[`codex-bridge-update-acceptance.json`](codex-bridge-update-acceptance.json)。
通常日次を待った実績と、時刻を一時変更した timer 経由の受け入れは区別する。

## GitHub認証の分離

人の対話用credentialと、lock更新等の無人処理用credentialを共有しない。無人用は対象repository、
Contents / Pull requests、check読取等の必要操作だけに限定し、Administration、workflow変更、key管理を
与えない。current scope、期限、owner、最終利用はGitHub providerで確認し、この文書へ複写しない。

public化後にlock提案をActionsへ移す場合は、host専用credentialを残さない。短命installation tokenを
使うGitHub Appまたは移行用selected-repository credentialを候補とし、PR作成、CI状態判定、auto-merge、
拒否すべき管理操作を受入してから旧credentialを失効する。

個人開発checkoutは同じtrust domainとして扱う。別checkoutはcredentialやhomeの隔離ではない。

## 宣言管理から外れているもの

ホストhome共有の削減は[依存表と未適用案](mini-vm-mount-dependencies.md)を参照する。Lima exportとguest fstabの対になる変更・計画停止・復旧は別承認で、この案は実機へ適用していない。

- **mini の macOS**: generation 26 で凍結。設定変更は手で当てる。アンインストールはしていない
- **Lima 本体**: brew で導入 (macOS 側が nix 管理外のため)。`limactl autostart enable mini-vm` で
  LaunchAgent 登録済み。**macOS の自動ログインが前提** — 無いと再起動後に VM が上がらない。
  FileVault を有効にすると自動ログインが使えなくなり 24/365 運用が崩れる。
  インスタンス名は当初 `nixos` (テンプレート名のまま) だったが、`limactl stop` →
  `~/.lima/` 配下のディレクトリを rename → `limactl start` で改名できた
  (公式サポートされた操作ではないが動く。autostart は名前が変わるので登録し直しが要る)
- **`~/.local/bin`**: PATH 末尾の例外レーン。self-update 前提のツールや nixpkgs にない uv tool 用。
  **住人 (2026-10-15 実測)**: `uv/tools.txt` で宣言した uv tool 群 (`colab` `idb` `mlx_whisper`
  `plamo-translate`) + plamo-translate 用に uv が入れた `python3.12` / 自己更新バイナリ `coderabbit` (+ alias `cr`) /
  自作 `npx_safe` / dotfiles.nix が置く `sfsymbols` ラッパ /
  uv installer が置く `env` `env.fish`。**`sheldon` と `claude` は死蔵** — どちらも nix 管理下
  (`packages.nix`) で `/etc/profiles/per-user/gigun/bin` が PATH で先に来るため呼ばれていない
  (claude は nix 側 2.1.226 / このレーン側 2.1.207 で取り残されていた)。消してよいが
  **claude は自分自身を実行中なので別セッションで**。
- **このレーンから出す判断のしかた** (2026-08-10 / Slack platform CLI を brew cask へ移した b3c33b8):
  公式インストーラの `~/.slack/bin` を symlink する形だったので新規 Mac で再現できず v3.14.0 に固着していた。
  **「self-update 前提だからこのレーン」は理由にならない** — `SLACK_SKIP_UPDATE=1` のような更新抑止の口が
  あれば宣言管理下に置ける (`AGY_CLI_DISABLE_AUTO_UPDATE` と同じ形)。抑止しないと自己更新が Caskroom の
  実体を上書きし、brew の記録とズレて `brew upgrade` が効かなくなる。
  また **nixpkgs に同名パッケージがあっても別プロジェクトのことがある** (nixpkgs の `slack-cli` 0.18.0 は
  rockymadden/slack-cli というメッセージ投稿用シェルスクリプトで、公式 platform CLI とは無関係)。
  移す前に確認する 3 点: (1) 同名 cask/nixpkgs が本当に同じものか (homepage を見る)、
  (2) 更新抑止の環境変数があるか (`strings <bin> | grep -oE 'SLACK_[A-Z0-9_]+'` の要領)、
  (3) 設定・認証の置き場所が実体と分離しているか (Slack CLI は `~/.slack` が config dir なので再ログイン不要だった)。
- **cloudflare-os のチェックアウト**: `~/ghq/github.com/cloudflare/cloudflare-os` に clone してあるだけで
  宣言外。systemd 側は `ConditionPathExists` で不在を許容する作りなので、VM を作り直したら
  clone し直すまでサービスは静かにスキップされる (壊れはしない)
- **T3 Code の pairing と linked environments**: iPhone / Pro との pairing は `~/.t3/userdata` の
  セッション状態で、宣言できない。VM を作り直したら pairing し直し (下の「T3 Code」節)
- **`tailscale serve` の設定**: 手で張るものは無い。443 → 127.0.0.1:3773 は `t3code` が起動時に
  `--tailscale-serve` で張り、停止時に外す (journal の "Tailscale Serve configured / disabled")。
  そのため t3code が止まっている間は `tailscale serve status` が空になる。
  以前は cloudflare-os (`127.0.0.1:8787`) を `sudo tailscale serve --bg 8787` で tailnet に出していたが、
  2026-08-09 (6d7decd) に公開経路を Cloudflare tunnel + Access (`os.097969.xyz`) へ移しており、
  T3 Code の serve が 443 を置き換えた今は張り直さない
- **mini の chrome-devtools MCP 登録**: `claude mcp add --scope user` で `~/.claude.json` に入る。
  dotfiles が配布する `hooks` / `commands` とは別に保存される。
- **apple/container**: 公式署名 pkg のみで brew にも nixpkgs にも無いが、pkg を `fetchurl` で hash 固定し
  activation から冪等に `installer` を叩く形で宣言管理下に置いた
  (`nix/modules/darwin/apple-container.nix`)。同種のツールが出たらこの形を踏襲する

## T3 Code (server、T3 Connect と tailnet)

T3 Codeは通常userのsystemd serviceとしてloopbackだけで待ち受け、remote accessはT3 Connectまたは
review済みのprivate network経路を使う。LAN bindやpublic unauthenticated listenerを追加しない。
provider executable、version、hash、service commandはNix宣言を正本とし、この文書へcurrent値を複写しない。

T3 Connectのaccount link、device enrollment、linked environmentはprovider current stateである。再構築時は
本人が短命codeを別端末で承認し、service再起動後にstatusと実接続を確認する。code、approval URL、device ID、
last-seen等をrepoへ保存しない。unlink / logout / provider側revokeを区別し、侵害時はprovider側登録も失効する。

状態確認ではservice active、loopback listener、tunnel / private route、実remote操作を別々に確認する。
一つの到達成功をprovider認証やOS sandboxの証拠にしない。

## 未解決の調査メモ

- **`DF-33` (再起動後の復帰・完了済みの調査記録)** — enrollment (ペアリング済みの状態) の保存先は判明済み:
  `~/.codex/state_5.sqlite` の `remote_control_enrollments` テーブル(文字列 grep で確認)。
  VM 内の通常ファイルなので再起動では消えない。当時の未検証項目は (1) systemd が実際に起動するか
  (`is-enabled` は enabled)、(2) macOS ホスト再起動時に Lima VM 自体が上がるか(自動ログイン依存)だった。
  2026-09-06 にホスト再起動とスマホからの接続で完了確認済み (→ `docs/task-archive.md` の `DF-33`)。
  「到達性ではなく機能を見る」型の具体例でもある。
- **`DF-40` (直 push のバイパス)** — 2026-09-08 に手元から `main` へ push した際、GitHub が
  `Bypassed rule violations for refs/heads/main: 2 of 2 required status checks are expected` を
  返した。required CI は**設定されているが、repo admin の直 push では強制されない**。
  無人経路のトークンを絞る話(上記)と同じ穴の対話経路版。pre-push フックは撤去し、
  mini-vm への適用は autoswitch の CI ゲートが守る(ADR 0011)。main に壊れた commit が
  入ること自体は塞いでいない。
- **`DF-12` (機能確認の型)** — ssh 到達性で合格としたが、その裏で DNS が全滅していた事故があった。
  2026-09-06 の健全性ゲート (mini-vm.nix の `healthGate`) が最初の実装で、名前解決 /
  cloudflare-os の HTTP 応答 / 常駐 unit / control socket の 4 項目を見る。

### Bark の配送先

共通失敗通知と Claude hook は `secrets/bark-env.age` の `BARK_PUSH_URL` に指定した
完全な HTTPS route へ送る。URL は秘密として扱い、ログ・Nix store に保存しない。
未指定時は公式 `https://api.day.app/<device-key>` を使う。hub H0 でも既存の
AES-256-CBC `ciphertext` / `iv` を受け付ける。端末とは鍵だけを揃え、IVは通知ごとに送る。
HTTP 成功と JSON `code=200` は受付の確認で、端末表示の確認とは区別する。

暗号鍵のrotation時は、runtime secretを配送して受信端末の設定を揃えた後に
`sudo systemctl start bark-notify-smoke`を手動実行する。このunitはwantedByもtimerも持たず、
通常運用では起動しない。runtime fileを必須にし、keyのbyte長とHTTPS routeを値非表示で
検査してから既存helperでcontrolled通知を送る。unit成功はHTTP / JSON受付までであり、端末での
新鍵復号表示と旧鍵での復号拒否は本人が別々に確認する。IVは秘密としてrotationせず、送信ごとに
新しいrandom値を生成してrequestへ含める。

## スマホからのCodex接続とペアリング

既存codex-remote-controlはOpenAIリレーへのアウトバウンド接続であり、iPhoneのTailscaleタグを必要としない。端末のペアリング登録を保持し、短命のコードは必要時に発行する。

Codex 0.160.0の`remote-control pair`はcontrol socketのRPC応答を2秒で打ち切る（上流`app-server-daemon/src/client.rs`）。サーバーのペアリングHTTP上限は30秒（`app-server-transport/src/transport/remote_control/enroll.rs`）。2026-10-03は標準プロトコルの直接要求が3.1秒で成功したため、CLIだけが先にtimeoutした。再起動やiPhoneのタグ変更では解決しない。

```sh
uv run scripts/codex-pair.py
```

ローカルからSSHで既存の0600 Unix socketへ一時転送し、同じinitialize／remoteControl/pairing/startを40秒上限で実行する。公開ポート・追加常駐・秘密の保存は増やさない。応答の認証情報を出力せず、本人が入力するコードと期限だけ表示する。成功・失敗のどちらでも一時SSH転送を終了する。CLI本体が修正されたらこの回避コードは削除する。

2026-10-03の受け入れ: 発行helperでコードと期限を取得し、一時転送終了を確認。本人の追加報告後、remoteControl/status/readでconnected、remoteControl/client/listで新しいiOS 27 iPhone登録とlastSeenAtを確認。旧iPhone登録は削除していない。

Tailscale policyは`tofu/tailscale/`の公開templateを正本とし、owner、node selector、OAuth等の
非公開入力はSOPSへ移行する。Cloudflareとはstateとcredentialを分ける。判断は[ADR 0010](adr/0010-tailscale-policy-as-code.md)を参照する。

初回importやpolicy変更では、plan、policy test、必要経路の成功、禁止経路の拒否、変更後の差分なしplanを
確認する。node、address、current scope、到達結果はprovider current stateとして扱う。緊急のdashboard変更は
宣言へ取り込み、次のapplyで意図せず上書きしない。Git pushだけでpolicyを自動適用しない。

## codex の MCP OAuth の張り直し

Cloudflare の MCP (`cloudflare`、codex の cloudflare plugin が足す) の OAuth はログインから 30 日で切れ、
refresh では延びない。張り直しはスマホから行う(設計は ADR 0013、実装は
`nix/modules/nixos/services/codex-mcp-login.nix` と `scripts/codex-mcp-login.py`)。

- **通常の流れ**: 最終ログインから 27 日目以降の毎朝 9 時台と、journal に refresh 拒否が出たときに
  Bark が「mini-vm MCP 再ログイン: cloudflare」を送る。タップ → Cloudflare Access → Cloudflare の同意画面 →
  「cloudflare: ログイン完了」で終わり。通知は server ごとに 1 日 1 通まで。
- **通知を待たずに張り直す**: Accessで保護したlogin入口を開き、開始linkへ進む。完全URLとprovider
  resource対応は宣言を正本にする。
- **通知だけ試す**: `sudo systemctl start codex-mcp-login-remind`(期限前なら何も送らない。送ったかは journal で見る)。
- **入口が使えないとき**: `ssh -t mini-vm codex-mcp-relogin cloudflare` で従来の callback URL 貼り付け手順を
  走らせる。中身は `codex mcp login cloudflare --no-browser` で、成功したら最終ログイン時刻を記録する。
  素の `codex mcp login` で済ませると時刻が記録されず、リマインダは古い時刻のまま鳴り続ける。
- **確認**: `journalctl -u codex-mcp-login -e`(認可 URL と callback の query は伏せて記録する)、
  `journalctl -u codex-mcp-login-remind -e`、`cat /var/lib/codex-mcp-login/cloudflare.login-at`(epoch 秒)。
- **張り直した後**: 実行中の `codex-remote-control` が新しい資格情報に切り替わらない(MCP の呼び出しが
  まだ失敗する)ときは `sudo systemctl restart codex-remote-control`。
- **codex の callback listener**: callbackは一時listenerを使うが、firewallでloopback以外を拒否する。
  listener待受中にloopback成功と外部経路拒否を同時に受入する。port等のcurrent値は宣言で確認する。

## agy の remote control(常駐と、手で当てる状態)

2026-10-09 に mini-vm へ入れ、2026-10-16 に常駐の所有を dotfiles へ移した(理由は `nix/modules/nixos/mini-vm.nix` の antigravity-remote-control のコメント)。
宣言できるものと、できない状態を分けて持つ。

- **宣言している**: パッケージ(`llmAgents.antigravity-cli`)と、常駐の system service
  `antigravity-remote-control`(`mini-vm.nix`、`agy remote-control serve` を flake の package に固定、
  `AGY_CLI_DISABLE_AUTO_UPDATE=1`)。版が変わった switch(autoswitch は 04:00 JST)で再起動するので、
  その時刻に進行中の会話は中断される。`dotfiles-autoswitch` の健全性ゲートにも入っている
  (認可トークンが無い機械では ConditionPathExists でスキップされ、ゲートは落ちない)。
  agy 自身が `remote-control start` で書く旧ユーザー unit `antigravity-cli-daemon.service` は
  store パス直書きで版が固定され、同一アカウントの二重 serve は WebChannel を取り合う
  (`Reconnection attempt N failed`)ため、system service の起動前に止めて unit ごと消す。
  `agy remote-control start` を再実行して復活したら `sudo systemctl restart antigravity-remote-control` で直る。
  linger(旧 `linger-gigun`)は他に使うユーザー unit が無いので宣言を外した。
- **宣言できない(手で当てる)**: Google アカウントの認可と、デバイスの登録。認可は本人の同意の記録で、
  トークンは更新のたびに書き換わるため agenix で配ると古い内容へ戻って壊れる。Codex の `auth.json`・
  `codex-pair.py`・Tailscale のログインと同じ扱い。
  - 登録: `agy remote-control start --name mini-vm`(旧ユーザー unit を書き直すだけなので、実行したら上の restart)。
    `agy remote-control status` は旧ユーザー unit を見ている可能性があり、system service で動いていても
    inactive と出得る(status の判定対象は未検証)。実態は下の確認コマンドとダッシュボードで見る。
  - 認可: ログイン後にデーモンがもう一段の OAuth 認可(`Enter the authorization code:`)を求め、
    stdin が無いので `failed to read authorization code from stdin: EOF` で失敗し続ける。
    ダッシュボード(https://antigravity.google.com)にも同じエラーが出る。
    `sudo systemctl stop antigravity-remote-control` のあと前景で `agy remote-control serve` を起動し、
    表示された URL を別端末のブラウザで承認して、認可コードを貼る。済んだら `sudo systemctl start` で戻す。
    前景 serve と常駐を同時に動かさないこと。
- **確認**: `systemctl status antigravity-remote-control`、`journalctl -u antigravity-remote-control -e`、
  ダッシュボードの `mini-vm` の表示。
- **確認済み(2026-10-09)**: 前景の `serve` で認可を通したあと常駐へ戻すと、デーモンは認可の要求を出さずに
  `active` を保ち、ダッシュボードにも `mini-vm` が出た。認可の結果はデーモンから読める場所に保存される。
- **移行(一度きり)**: 初回の switch で system service が起動し、ExecStartPre が旧ユーザー unit を止めて消す。
  switch 後に `systemctl --user list-units 'antigravity*'` が空で、`pgrep -af 'agy remote-control serve'` が
  1 行であることを確認する。

### mini本体でのiOSビルド・署名

**現在地 (2026-11-09)**: 以下のGUI runner経路は2026-10-04に成功した旧経路の記録であり、
現在の分離済み本番構成ではない。現行本番はGUIログインユーザーと同じsecurity session / UIDで
build、sign / export、publishを同じjobが担う。asc-mcp側には固定archiveの入力digest、未署名IPA拒否、
一時Keychainでのmanual export、publish子processだけへのcredential注入を行う新adapterがあるが、
本番Actions、別OS主体、成果物受渡しには未接続である。

署名専用ユーザーの所有者contextで実行する値非表示inventoryは用意済みだが、そのcontextでは未実行。
通常ユーザーから保護領域を読めなかったことを、資材不存在とは扱わない。inventoryで証明書と秘密鍵、
profileの対象・期限・端末適合を確認してから、同一mini内のbuild / sign / publish専用UID、固定hash manifest、
承認点、旧GUI runnerへのrollbackを設計・受入する。別VMはXcode / Keychainの代替にならないため、最初の
分離案にはしない。

Xcode、SDK、Simulator、Keychainが必要な処理はmacOS本体で実行する。project、scheme、configuration、
destination、archive pathは対象repositoryの宣言を正本とし、host固有checkout pathやaccount selectorを
この文書へ複写しない。通常buildへautomatic provisioningを無条件で許可せず、署名が必要な工程だけ
profile / identityの組を明示する。passwordやcredentialをSSH引数・logへ渡さない。

GUI login sessionで過去に署名できたことは、current identity、profile、runner、再起動後の利用可能性を
証明しない。SSHや別security sessionからidentityが見えなくても、鍵の不存在や失効と判断しない。
current owner inventoryは値非表示で署名主体のcontextから取得し、専用UID案を非秘密artifactで受入する。

ASC CLIの取得元、version、checksumは各hostの宣言を正本とする。凍結hostへ置く場合も公式releaseの
checksumを検証し、具体値をこの運用文書へ複写しない。

`asc xcode archive` / `asc xcode export --method release-testing --ipa-path ...`はローカルのXcodeでarchive・Ad Hoc IPA生成を行う入口。署名・配布検証の `asc distribute prepare` もApp Store ConnectのAPI認証なしで使える。ASCのAPI認証は両ホストとも未登録。配布・通知・サービス専用IaCの手順はasc-mcp repoが管理する。

### Cloudflareのアプリ配布

配布入口、Access policy、download署名、object storageはIaCと配布toolの宣言を正本とする。通常ページは
本人認証、downloadは短命署名と対象path検証を要求し、Access bypassだけでartifactを公開しない。
account selector、resource名、完全URL、local pathはautomationに必要なstructured inputまたはprovider
current stateとして扱う。

build / sign主体とpublisherを分け、publisherは承認済みartifact hashだけを受け取る。配備時はAccess、
Worker、storage、通知の受付と実deviceでの取得を別々に確認する。
