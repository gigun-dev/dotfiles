# mini-vm の運用

旧 `docs/next-directions.md`(2026-09-10 に廃止)から降ろした mini-vm 関連の調査メモ。
決着済みの経緯と、未解決のまま残っている調査項目をまとめる。

## mini-vm の自動更新 (2026-09-06 実装)

**動機**: 無人機なので手で `pull && switch` を打つ機会が無く、push 済みの変更が届かないまま
気づけない(cloudflare-os で実際に 106 コミット遅れた)。

**設計の要点**(実装は `nix/modules/nixos/mini-vm.nix`):

- **lock 更新の提案と適用を分ける。** `dotfiles-lock-propose@fast`(毎日) / `@slow`(日曜)が
  lock 更新 → 実機ビルド → PR・auto-merge 設定まで行い、required CI の成功で merge する。
  人の lock 差分レビューは前提にしない。`dotfiles-autoswitch` 自体は lock を更新せず、
  merge 済みの変更を pull → switch → 健全性確認し、失敗時は rollback する。
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

**実績** (2026-09-08 時点): PR #1〜#5 が全て merged、CI も直近 8 run 全て success。
設計は当初「手元でレビューしてから merge」だったが、lock 差分は人に判定できないと結論し、
2026-09-06 に lock 提案 + required CI ゲートによる自動 merge・適用へ切り替えた。

**残っている穴**: 失敗は鳴るが**沈黙は検出できない**。自動再起動は導入していない。
ホスト再起動後の復帰検証(「mini-vm 再起動後に codex-remote-control が復帰し、スマホから
繋がるか確認する」)は完了済みで、自動再起動の導入とは区別する。
もう 1 つ、**required CI は admin 権限の直 push でバイパスできる**(下記「未解決の調査メモ」)。

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
