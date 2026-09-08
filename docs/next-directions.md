# 次セッションの方向性(2026-09-08 棚卸し・第3版)

> **位置づけ**: セッション引き継ぎの正典。SessionStart フックが `session-head-end` まで注入する。
> **頭は予算制**(10,000 字超で無言に切り詰められる)。書くのは「いまどこか」「次に何をするか」だけで、
> 詳細はマーカー以降へ。**計画は消さない。着手順を手で編集しない**(書き手は `nd-tasks.sh` だけ)。
> 完了は `--done`(証拠行が必須)、状況変化は `> **YYYY-MM-DD 更新:**` を積層し、嵩んだら棚卸し。

## 現在地(2026-09-08)

- **基盤は mini-vm** (Mac Mini 上の Lima ゲスト / NixOS)。macOS 側は nix 管理を凍結し iPhone
  バックアップ・画面共有・Xcode 26.3 専用。`ssh gigun@mini-vm` (Tailscale SSH / `tag:server`)。
  名前はすべて `mini-vm`(`mini` は macOS 側を指す)。

- **mini-vm が自分で更新を提案し、適用する** (2026-09-06 導入)。01:00 に lock 提案 → 実機ビルド
  → PR + auto-merge、required CI が green なら squash merge。04:00 に pull → switch → 健全性ゲート
  → 失敗なら rollback。**人は PR を見ない**(lock 差分は人に判定できない)。2026-09-08 時点で
  PR #1〜#5 が全て merged、CI も全 green で**回っている**。穴は 2 つ — **沈黙は検出できない**
  → `DF-35`、**required CI は admin の直 push で素通りできる** → `DF-40`。
  詳細はカタログ「mini-vm の自動更新」節。

- **公開境界は Cloudflare**。`os.097969.xyz`(named tunnel + Access)と `codex.097969.xyz`
  (ローカル codex を OpenAI 互換 API として外へ。Access は張れず守りは api_key のみ → `DF-22`)。
  Tailscale は SSH 専用。

- **秘密とエッジ構成は宣言管理下**。agenix (`secrets/*.age`) と OpenTofu (`tofu/`、state は R2 で
  PBKDF2 + AES-GCM 暗号化)。VM を作り直しても `nix run .#switch`、アカウントを作り直しても
  `nix run .#tofu -- apply` で戻せる。**保管用鍵は iPhone の「パスワード」アプリ**。

- **スマホから mini-vm の Codex を使える** (2026-09-01)。リレーへアウトバウンドで繋ぐので受け口が
  無い。ホストごと再起動しても復帰することを実測済み (`DF-33`)。

- **ESP32 は shell 2 本**: `.#esp-idf` (ESP-IDF 6.1) と `.#esp32drop` (Arduino 比較用)。CoreS3 の
  実機まで検証済み、AirDrop 転送は未実装。→ `docs/esp-idf.md` `docs/esp32drop.md`
- **繰り返している失敗の形**: **検知器自身が壊れていると、壊れていることに気づけない**
  (切り詰め警告が切り詰めで消える / ssh 到達性で DNS 全滅を素通り / CI が丸一日赤いのを見逃す)。
  「確認した」と書くときは確認手段が生きているかを別経路で疑う → `DF-12`

- **未検証**: apple/container の再起動後の復帰 → `DF-5`。**裁定待ち**: `DF-2` `DF-3` `DF-6`

## 着手順(次にやること)

**順序**: リストの並びではなく **`DF-37` → `DF-40` → `DF-35` → `DF-38`** が先(無人・対話の
両経路の権限を絞ってから、沈黙検知と信頼境界)。以降は Cloudflare OS の主線 `DF-13` `DF-24`
`DF-22`、その後は裁定待ちと随伴作業。**手で並べ替えない**(書き手は `nd-tasks.sh` だけ)。
各項目の詳細はカタログ「着手順から降ろした詳細」節。

- [ ] `DF-35` 通知を hub に寄せ、沈黙を検出できるようにする
      → 完了条件: 3 系統の成功確認が途絶えたら iPhone に通知され、復旧・計画停止・二重配信防止も検証できること
- [ ] `DF-13` Cloudflare OS に AI プロバイダを繋いで実際に使う
      → 完了条件: Cloudflare OS のチャットでモデルが応答し、Neurons 消費が実測できること
- [ ] `DF-24` Langfuse を codex 経由の推論に挟む
      → 完了条件: codex 経由の推論が Langfuse のトレースに出ること
- [ ] `DF-22` codex エンドポイントにレート制限を入れる
      → 完了条件: 認証失敗が続く送信元に制限がかかること
- [ ] `DF-12` 「到達性テスト」に機能確認を含める型を決める
      → 完了条件: 再起動検証の手順が「上がったか」ではなく「使えるか」を見る形になること
- [ ] `DF-14` Kitesurf を chrome-devtools-mcp から使えるか試す
      → 完了条件: mini から Kitesurf 経由でページを取得・スクショできること
- [ ] `DF-15` Claude / opencode のサブスク枠もブリッジできるか調べる
      → 完了条件: 実装するか見送るかを、翻訳層の分量を見積もった上で決めること
- [ ] `DF-2` SPEC.md の扱いを決める (案 A 凍結明記 / B CLAUDE.md へ一本化 / C 追従)
      → 完了条件: 3案のどれかを実施し、現行仕様と誤読されない状態にする
- [ ] `DF-3` CLAUDE.md の「ディレクトリ構造」節を圧縮する
      → 完了条件: 39 行 → 15 行程度にし、doctor の「長い節」指摘が消えること
- [ ] `DF-5` apple/container の再起動後の復帰を確認する
      → 完了条件: 再起動後に手を触れず apiserver が running であること
- [ ] `DF-6` 意思決定 (ADR) の置き場所について harness の結論を取り込む
      → 完了条件: gigun-dev/claude-code#3 の裁定が出て、このリポジトリで ADR を使うか否かが決まること
- [ ] `DF-30` cloudflare-os へ gatekeeper-mcp の固定 client_id 対応を起票する
      → 完了条件: issue を投稿する(下書きは `docs/drafts/gatekeeper-mcp-static-client-id.md`)
- [ ] `DF-31` Slack 書き込み gatekeeper は upstream PR #95 待ち
      → 完了条件: PR #95 の動向を見て、着手 / 見送り / 自前実装を判断する
- [ ] `DF-32` CLAUDE.md の常時ロード量を予算内へ落とす (≒6352 tok / 予算 2000)
      → 完了条件: doctor の肥大指摘が消えるか、超過を許容する理由が正典に書かれていること
- [ ] `DF-37` mini-vm の gh トークンを絞る (いま admin: true。二段でやる → カタログ)
      → 完了条件: mini-vm から branch protection を変更できない状態になり、lock 提案の PR は従来どおり作れること
- [ ] `DF-38` realbind の業務コードを mini-vm から隔離する
      → 完了条件: 業務リポジトリの作業領域が agenix のホスト鍵と同じ信頼境界に無い状態にする (別 Lima ゲスト / 別 Unix ユーザーのどちらかを選び、選ばなかった理由も残す)
- [ ] `DF-40` main への直 push が required CI をバイパスできる状態を塞ぐ
      → 完了条件: 手元からの push で GitHub の "Bypassed rule violations" が出なくなり、変更は PR + required CI 経由でしか main に入らないこと (自動 merge レーンは従来どおり動くこと)
<!-- session-head-end: ここから下は SessionStart フックが注入しないオンデマンド領域。着手する節をそのとき読む -->

## 完了記録(着手順から降ろしたもの)

頭は予算制なので、完了した項目はここへ降ろす。**ID は再利用しない**(log.md から参照されるため)。

**過去分は `docs/next-directions-archive.md`**(2026-09-08 の棚卸しで移した)。

- ~~`DF-29` マーカー以降の行数警告をどう畳むか決める~~ ✅ 2026-09-08
  → 完了条件: 毎セッション出る警告が消えるか、消せない理由が正典に書かれていること
  → 2026-09-08 / docs/next-directions.md 第3版の棚卸し / 完了記録 25 件を docs/next-directions-archive.md へ、決着済みの解説 5 節を docs/{cloudflare-os,mini-intel-eol,harness-notes}.md へ切り出し、マーカー以降を 637 → 209 行にした。session-start.sh を実行して肥大警告が出ないことを確認 (閾値 250 は変更していない)

## 方向性カタログ

### 着手順から降ろした詳細 (2026-09-06 棚卸し)

頭が予算を超えていた(12,686B / 上限 10,000B。**無言に切り詰められていた**)ので、着手順の各項目は
「1 行の概要 + 完了条件」に縮めた。そこから外した調査結果をここに置く。**計画は消していない。**
決着済みの経緯は別ファイルへ移した: Cloudflare OS の詳細は `docs/cloudflare-os.md`、
Intel 打ち切りは `docs/mini-intel-eol.md`、harness 運用は `docs/harness-notes.md`。

- **`DF-33` (再起動後の復帰)** — enrollment (ペアリング済みの状態) の保存先は判明済み:
  `~/.codex/state_5.sqlite` の `remote_control_enrollments` テーブル(文字列 grep で確認)。
  VM 内の通常ファイルなので再起動では消えない。残る未検証は (1) systemd が実際に起動するか
  (`is-enabled` は enabled)、(2) macOS ホスト再起動時に Lima VM 自体が上がるか(自動ログイン依存)。
  DF-12 の「到達性ではなく機能を見る」型の具体例でもある。
- **`DF-24` (Langfuse)** — Claude Code 側は導入済み (e6f0bd5)。残るは codex 経由で、
  **openai プロバイダだけ観測できる**。`apiUrl` を差し替えて LiteLLM を挟む形になるため。
  Workers AI は baseUrl 固定で挟めず、AI Gateway は codex と排他。
- **`DF-22` (レート制限)** — 2026-09-01 の切り分け: スマホから Codex を叩く用途は
  codex-remote-control (リレー経由・受け口なし) へ移せる。ブリッジの公開が本当に要るのは
  **Cloudflare OS から OpenAI 互換 API として叩く経路だけ**。
- **`DF-15` (Claude/opencode のブリッジ)** — codex は既存実装を借りて通ったが、Claude は
  Messages API と SSE の自作になり難度が段違い。opencode のサーバモードが互換エンドポイントを
  出せるなら、そちらが現実的。
- **`DF-13` (AI プロバイダ)** — codex 側は通っている(mini に常駐、モデル ID が `SUGGESTED_MODELS`
  と一致するので登録不要)。同じ無料枠で `qwen3-30b-a3b-fp8` は既定の Kimi の 16 倍使える。
  単価表はカタログ「AI プロバイダ」節 → `docs/cloudflare-os.md`。
- **`DF-30` (gatekeeper-mcp)** — 動的クライアント登録 (RFC 7591) しか対応しておらず、事前登録
  必須の認可サーバー (Slack MCP など) に 502 で繋がらない。
- **`DF-31` (Slack 書き込み)** — PR #95 (approval-gated Google Drive/Sheets writes) が唯一の
  設計手本。2026-08-10 時点で draft・conflicting・レビュー 0 件・CLA 未署名で停滞中。
- **`DF-2` (SPEC.md)** — 2026-04-10 以降更新されていない。案 A(凍結を明記)が推奨。
- **`DF-29` (行数警告)** — 完了記録は追記専用で増える一方なのに、上限は頭を降ろす先と
  同じ領域(マーカー以降)にかかっている。頭を縮めるほどカタログが伸びる構造。
- **`DF-40` (直 push のバイパス)** — 2026-09-08 に手元から `main` へ push した際、GitHub が
  `Bypassed rule violations for refs/heads/main: 2 of 2 required status checks are expected` を
  返した。required CI は**設定されているが、repo admin の直 push では強制されない**。
  `DF-37`(無人経路のトークンを絞る)と同じ穴の対話経路版で、pre-push フックは手元の検証で
  あって GitHub 側の関門ではない(`--no-verify` で外れる)。
- **`DF-12` (機能確認の型)** — `DF-7` は ssh 到達性で合格としたが、その裏で DNS が全滅していた。
  2026-09-06 の健全性ゲート (mini-vm.nix の `healthGate`) が最初の実装で、名前解決 /
  cloudflare-os の HTTP 応答 / 常駐 unit / control socket の 4 項目を見る。

### mini-vm のトークンを絞る (2026-09-06 調査)

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

### 通知基盤は hub に寄せる (2026-09-06 決定)

**当初 `DF-35` は「dotfiles の `tofu/` に dead-man's switch の Worker を作る」計画だったが、
それは `gigun-dev/hub` の再発明だった**。hub を読んで撤回した。

**実装済みは H0 の Bark backend 検証 Worker**。OpenTofu で公開し、D1 への端末登録と
APNs 配信を検証済み。本人が iPhone で通常通知・AES 暗号化通知を両方読めたと確認し、
成立性ゲートを通過した。URL タップ・group・level の表示挙動や鍵更新などの受け入れは残る。

**共通受付 `/notify`、履歴・outbox・再試行は H1、heartbeat による沈黙検知は H1b の計画**で、
まだ実装されていない。Slack 配信も未実装。`level` と配信先の対応は今後の設計対象とする。
pve の SSD 障害に長期間気づけなかった反省は引き継ぐが、7 日ごとの一律確認ではなく、
通知元ごとの実行周期に応じて成功確認の遅延を検出する。

**所有境界**([hub の定義](../../hub/docs/infra-ownership-2026-09-06.md)):
配信 API・認証・履歴・Bark backend・Slack adapter は hub、
**通知元 hook・利用 URL・個人の資格情報は dotfiles**。
H0 は Worker/version/deployment と D1 を hub の OpenTofu で管理し、暗号化した独立 state を使う。
Wrangler は bundle と migration に使う。dotfiles の共通インフラと state へ混ぜない。

**dotfiles 側の移行範囲**(現時点では既存の Bark 直送を維持):

1. mini-vm の共通失敗通知と `claude/hooks/bark-notify.sh` を hub の共通受付へ移行する。
2. `dotfiles-autoswitch`・`dotfiles-lock-propose@fast`・`@slow` の **3 系統**に成功 heartbeat を足す。
   lock に差分が無い正常終了も報告する。Claude hook はイベント駆動なので同じ周期監視に含めない。
3. 通知元 ID・認証・監視周期を宣言管理し、30 分の起動ジッターと処理時間を猶予に含める。
   日次と週次を区別し、不発・復旧・計画停止と移行時の二重配信防止を検証する。

共通受付への切替は H1 の受け入れ後。**DF-35 完了には H1b の監視と H2 の移行検証も必要**。
「成功確認が届かない」ことを知らせる設計であり、通知だけで VM 障害の原因を断定しない。

**UI と MCP は両立する**。通知履歴を見る Cloudflare OS gadget は候補、エージェントによる
hub 操作には MCP を検討する。どちらも未実装で、専用 MCP を一律に却下しない。
外部 MCP の認証互換性 (`DF-30`) は gadget が API を呼ぶ経路とは別途検証する。

**認証案は実装済み構成と分ける**。機械向け `/notify` は Bearer、人向け `/history` は
Cloudflare Access で守る案を持つが、H0 は workers.dev 上の秘密のパス接頭辞による構成。
共通 API・履歴 UI の認証と独自ドメインは hub 側で確定する。

**訂正の履歴** (2026-09-06): 一度この節を「設計は既にある」と書いたが、実機で成立が確認できて
いるのは H0 と OpenTofu 管理だけで H1/H1b/H2 は未着手だった。専用 MCP の一律却下も同時に撤回し、
通知移行の範囲に lock 提案 2 系統の成功確認を足した。

### mini-vm の自動更新 (2026-09-06 実装)

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

**残っている穴**: 失敗は鳴るが**沈黙は検出できない** → `DF-35`。自動再起動は導入していない。
`DF-33` のホスト再起動後の復帰検証は完了済みで、自動再起動の導入とは区別する。
もう 1 つ、**required CI は admin 権限の直 push でバイパスできる** → `DF-40`。

### 宣言管理から外れているもの

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

### 保留中の課題 (このセッション以前から)

- **pve の SSD 故障**: 2026-05-20 に ext4 emergency_ro 転落。データは mini へ退避済み
  (`~/pve-*.img.gz` で計 28GB)。交換か再インストールかの判断が保留。mini のストレージ整理と連動する
- **uv tools の宣言管理**: mlx_whisper 等の uv tool 群を nix か宣言スクリプトで管理したい。未着手
- **Taildrive**: mini の `~/Storage` を中央ストレージにする構想だったがほぼ使われていない。
  VM 移行で mini の役割が変わったので、続けるか畳むか要判断

### Kitesurf (2026-08-06 リリース、beta 無料)

OSS ではなくローカルには持ってこられないが、CDP を WebSocket で外部公開しており接続できる:
`wss://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/browser-run/devtools/browser?browser=kitesurf`
+ `Authorization: Bearer <API_TOKEN>`。chrome-devtools-mcp には `--wsEndpoint` と
`--wsHeaders '{"Authorization":"Bearer ..."}'` があるので、そのまま刺さるはず。
**WebGL / 動画再生 / ボット検出ハンドシェイク / 永続状態が要る長時間セッションは未対応**なので、
ログインが要る操作はローカル Chromium 側に残す使い分けになる。
