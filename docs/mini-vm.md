# mini-vm の運用

旧 `docs/next-directions.md`(2026-09-10 に廃止)から降ろした mini-vm 関連の調査メモ。
決着済みの経緯と、未解決のまま残っている調査項目をまとめる。

## 運用ダッシュボード

mini-vmのCPU・メモリ・ディスク・ネットワークとDockerコンテナ別の使用量はBeszelで
確認する。VMには物理温度sensorが公開されていないため、現状は温度だけ取得できない。
Hubは`127.0.0.1:8090`だけで待ち受け、ブラウザからは既存named tunnelの
`https://beszel.097969.xyz`をCloudflare Accessで保護して開く。障害時の切り分けでは
`ssh -L 8090:127.0.0.1:8090 mini-vm`でも直接確認できる。

mini-vm自体が停止した場合は同居するBeszelでは検出できないため、LangfuseとCodex Proxyの
死活監視はCloudflare Worker Cronから5分ごとに行う。最新結果は
`https://uptime.097969.xyz`で確認でき、2回連続失敗と復旧時はBarkへ通知する。
Worker・KV・Cron・custom domainは`gigun-dev/hub`の`infra/uptime/`でOpenTofu管理する。
詳細はADR 0008を参照する。

## mini-vm の自動更新 (2026-09-06 実装)

**動機**: 無人機なので手で `pull && switch` を打つ機会が無く、push 済みの変更が届かないまま
気づけない(cloudflare-os で実際に 106 コミット遅れた)。

**設計の要点**(実装は `nix/modules/nixos/mini-vm.nix`):

- **lock 更新の提案と適用を分ける。** `dotfiles-lock-propose@fast`(毎日) / `@slow`(日曜)が
  lock 更新 → 実機ビルド → PR・auto-merge 設定まで行い、required CI の成功で merge する。
  人の lock 差分レビューは前提にしない。`dotfiles-autoswitch` 自体は lock を更新せず、
  merge 済みの変更を pull → switch → 健全性確認する。失敗時の復帰先は今回の
  開始時に稼働していた構成だけとし、Langfuse の image pair が変わる場合は戻さない。
- **`system.autoUpgrade` は使わない。** home 層が視野の外(`nixos-rebuild` しか叩かない)で、
  pre/post フックが無いため健全性ゲートも dirty ガードも挟めない。nixpkgs の
  `nixos/modules/tasks/auto-upgrade.nix` を読んで確認した。提供価値は timer 1 本分。
- **`--flake github:...` の直接参照も却下。** 手動 switch(作業コピー)と自動更新(github:)で
  真実が二重になり、「いま動いている rev」を作業コピーから読めなくなる。ローカル pull なら
  食い違いが dirty ガードで鳴る。
- **dirty ガードは検知器**。作業コピーが汚れている = 誰かが VM 上でいじって放置した、なので
  踏み潰さず止めて通知する。
- **駆動スクリプトは現 generation のものが走る**。新しいツリーが更新器自身を壊しても、次回は
  壊れる前の更新器で回る(自己更新は 1 サイクル遅れる)。

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
  autoswitch と意図的に分離してあり、理由は `docs/adr/0006-track-uvx-versions-outside-nix.md`。

**実績** (2026-09-08 時点): PR #1〜#5 が全て merged、CI も直近 8 run 全て success。
設計は当初「手元でレビューしてから merge」だったが、lock 差分は人に判定できないと結論し、
2026-09-06 に lock 提案 + required CI ゲートによる自動 merge・適用へ切り替えた。

**残っている穴**: 失敗は鳴るが**沈黙は検出できない**。自動再起動は導入していない。
ホスト再起動後の復帰検証(「mini-vm 再起動後に codex-remote-control が復帰し、スマホから
繋がるか確認する」)は完了済みで、自動再起動の導入とは区別する。
もう 1 つ、**required CI は admin 権限の直 push でバイパスできる**(下記「未解決の調査メモ」)。

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

## mini-vm のトークンを絞る (2026-09-06 調査)

mini-vm の `gh` トークンは `repo` scope で、dotfiles に対して **`admin: true`**(branch protection の
変更まで可能)。無人で毎日 push する経路に乗っている資格としては広すぎる。

**A(1 本を絞る)と B(無人経路だけ専用トークン)は対立しない。二段でやる。**
mini-vm には性質の違う 2 つの信頼経路があり、1 本に両方を担がせているのが根本の問題:

| 経路 | 必要権限 | ライフサイクル |
|---|---|---|
| 無人(`dotfiles-lock-propose@`) | dotfiles に contents + PR だけ | 無期限に安定していてほしい |
| 対話(ssh して realbind で作業) | 広い | いつでも失効・再ログインできる |

- **段 1(今すぐ・可逆)**: dotfiles 限定の fine-grained PAT を発行し、agenix 経由で
  `GH_TOKEN` として `EnvironmentFile` から注入。**gigun-dev 個人所有なので org ポリシーと
  無関係に今日できる**。`GH_TOKEN` は hosts.yml より優先され、remote が HTTPS なら
  `git push` にも効く(`gh auth git-credential` が同じ解決系を通るため。実機の remote は HTTPS)。
- **段 2**: 対話用の `gho_` を縮める。**ただし classic PAT では `admin: true` を消せない** —
  `repo` scope は分割不能で、権限は「scope ∩ 本人の権限」なので repo admin である限り
  admin API が付く。`public_repo` にすると realbind(private)が全滅する。構造的に不可。
  fine-grained へ移すには **realbind org が fine-grained PAT を許可しているか**の確認が要る
  (GitHub の既定は管理者承認必須)。

**B の効用は侵入対策ではない**(hosts.yml を読める侵入者には無力)。守るのは
**confused deputy と事故** — このホストはエージェント基盤で、LLM が ambient な `gh` 認証を
継承して動く。誤動作で `gh api -X DELETE` や branch protection 変更が飛ぶ確率は侵入より高い。
専用トークンなら最悪でも「変な PR が立つ」で止まる(required CI と squash merge が受け皿)。
もう一つは**ライフサイクル分離** — 広いトークンを revoke してもパイプラインが死なない。

**別の課題**: realbind の業務コードと agenix のホスト鍵が同じ機械に同居している。トークンを
絞っても clone 自体はディスクに在るので緩和できない。分離するなら別 Lima ゲストか別 Unix
ユーザー。優先度は上記より下(可逆性とコストの差)。

## 宣言管理から外れているもの

- **mini の macOS**: generation 26 で凍結。設定変更は手で当てる。アンインストールはしていない
- **Lima 本体**: brew で導入 (macOS 側が nix 管理外のため)。`limactl autostart enable mini-vm` で
  LaunchAgent 登録済み。**macOS の自動ログインが前提** — 無いと再起動後に VM が上がらない。
  FileVault を有効にすると自動ログインが使えなくなり 24/365 運用が崩れる。
  インスタンス名は当初 `nixos` (テンプレート名のまま) だったが、`limactl stop` →
  `~/.lima/` 配下のディレクトリを rename → `limactl start` で改名できた
  (公式サポートされた操作ではないが動く。autostart は名前が変わるので登録し直しが要る)
- **`~/.local/bin`**: PATH 末尾の例外レーン。self-update 前提のツールや nixpkgs にない uv tool 用。
  **住人 (2026-08-10 実測)**: uv tool 群 12 コマンド (`hf` `huggingface-cli` `tiny-agents` `idb`
  `it2` `kimi` `kimi-cli` `majin` `mlx_whisper` `plamo-translate` `skills-ref` `yt-dlp`) + `python3.12`
  = 下記「保留中の課題」の本体 / 自己更新バイナリ `coderabbit` (+ alias `cr`) / 自作 `npx_safe` /
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
- **`tailscale serve` の設定**: `sudo tailscale serve --bg 8787` は tailscaled の状態として永続し
  再起動も越えるが、宣言には無い。VM を作り直したら張り直しが要る
- **mini の chrome-devtools MCP 登録**: `claude mcp add --scope user` で `~/.claude.json` に入る。
  dotfiles が管理しているのは `claude/settings.json` / `hooks` / `commands` だけなので、ここは外
- **apple/container**: 公式署名 pkg のみで brew にも nixpkgs にも無いが、pkg を `fetchurl` で hash 固定し
  activation から冪等に `installer` を叩く形で宣言管理下に置いた
  (`nix/modules/darwin/apple-container.nix`)。同種のツールが出たらこの形を踏襲する

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
  無人経路のトークンを絞る話(上記)と同じ穴の対話経路版で、pre-push フックは手元の検証で
  あって GitHub 側の関門ではない(`--no-verify` で外れる)。
- **`DF-12` (機能確認の型)** — ssh 到達性で合格としたが、その裏で DNS が全滅していた事故があった。
  2026-09-06 の健全性ゲート (mini-vm.nix の `healthGate`) が最初の実装で、名前解決 /
  cloudflare-os の HTTP 応答 / 常駐 unit / control socket の 4 項目を見る。

### Bark の配送先

共通失敗通知と Claude hook は `secrets/bark-env.age` の `BARK_PUSH_URL` に指定した
完全な HTTPS route へ送る。URL は秘密として扱い、ログ・Nix store に保存しない。
未指定時は公式 `https://api.day.app/<device-key>` を使う。hub H0 でも既存の
AES-256-CBC `ciphertext` / `iv` を受け付けるので、端末の鍵・IV と揃える。
HTTP 成功と JSON `code=200` は受付の確認で、端末表示の確認とは区別する。

## スマホからのCodex接続とペアリング

既存codex-remote-controlはOpenAIリレーへのアウトバウンド接続であり、iPhoneのTailscaleタグを必要としない。端末のペアリング登録を保持し、短命のコードは必要時に発行する。

Codex 0.160.0の`remote-control pair`はcontrol socketのRPC応答を2秒で打ち切る（上流`app-server-daemon/src/client.rs`）。サーバーのペアリングHTTP上限は30秒（`app-server-transport/src/transport/remote_control/enroll.rs`）。2026-10-03は標準プロトコルの直接要求が3.1秒で成功したため、CLIだけが先にtimeoutした。再起動やiPhoneのタグ変更では解決しない。

```sh
uv run scripts/codex-pair.py
```

ローカルからSSHで既存の0600 Unix socketへ一時転送し、同じinitialize／remoteControl/pairing/startを40秒上限で実行する。公開ポート・追加常駐・秘密の保存は増やさない。応答の認証情報を出力せず、本人が入力するコードと期限だけ表示する。成功・失敗のどちらでも一時SSH転送を終了する。CLI本体が修正されたらこの回避コードは削除する。

2026-10-03の受け入れ: 発行helperでコードと期限を取得し、一時転送終了を確認。本人の追加報告後、remoteControl/status/readでconnected、remoteControl/client/listで新しいiOS 27 iPhone登録とlastSeenAtを確認。旧iPhone登録は削除していない。

Tailscaleポリシーは `tofu/tailscale/` で管理する。公開テンプレートは汎用タグと権限定義、所有者IDは `secrets/tofu-env.age` の `TF_VAR_tailnet_owner`、OAuth資格情報も同じage環境ファイルに保存する。Cloudflareとは別の暗号化stateを使い、既存の `nix run .#tofu -- -chdir=tailscale` で実行する。判断はADR 0010を参照。

初回はpolicy_file権限のOAuth資格情報を登録後、`init`、`import tailscale_acl.policy acl`、`plan -detailed-exitcode` の順で現行の意味を変えていないことを確認する。ポリシー用OAuthをageへ保存し、importと本番の変更なしplanを確認済み。OAuthにはpolicy_fileとTailscaleが自動追加するdevices:core:read／devices:posture_attributesの依存権限が付く。管理画面のSSO問題はChromeで解消し、現行ポリシーを取得済み。

取り込みの確認後、タグ無しの本人端末からPro／miniへのHTTPS許可を追加し、本人HTTPSの許可・本人SSHの拒否・既存管理端末の接続維持をpolicy testsに入れる。`plan`でAPIによる検証を通してから`apply`する。Proとminiはタグ全体でなく正確な配布先へ限定する。現在の広いタグ間許可は別変更で見直す。管理画面で緊急変更した場合は正典へ取り込み、次のapplyで黙って上書きしない。
