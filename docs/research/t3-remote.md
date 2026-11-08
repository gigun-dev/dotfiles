# T3 Code を Mac mini とスマホからも使う構成

調査日: 2026-11-08。読み取りのみ。todo `id:0136` への材料。

参照した版:

- pingdotgg/t3code: `6417151c093e54dbba0e6c824c69d03983793b9a`（2026-11-08。`apps/server/package.json` は 0.1.7）。最新 stable は v0.1.7、nightly は 0.1.8-nightly.20261108（`gh release list`）
- ryoppippi/dotfiles: `de137c2a`
- gigun-dev/dotfiles: 作業ツリー（HEAD `12c5b09`）。flake の nixpkgs は `/nix/store/22wgynxys0wkin1s3g38y9fghidikm0w-source`

表記: **[確認]** は docs・ソース・コマンド出力で裏取りしたもの。**[推測]** は裏取りしていないもの。docs のパスは t3code リポジトリ内の相対パスで、公開版は https://github.com/pingdotgg/t3code/tree/main/docs にある。

---

## 1. 要点

- **Intel Mac（mini の macOS）には `t3` CLI もバックグラウンドサービスも無い。** デスクトップアプリ（x64 dmg）だけがある。ソースからビルドしたサーバーは `t3 update` もサービスも使えない。desktop-managed SSH の接続先も「Linux か Apple Silicon Mac」に限られる。したがって、mini で常駐する T3 環境の置き場所は **Lima の mini-vm（x86_64-linux）** になる。
- mini-vm には nixpkgs の `t3code`（`bin/t3` を含む。x86_64-linux 対応）を入れ、`t3 serve` を NixOS の system service で常駐させられる。CLI の `t3 service install` が作る systemd **user** service は linger を前提とするが、gigun は linger を宣言外の状態として避けている。そのため既存の cloudflare-os と同じ「User= 付きの system service」に揃えるのが自然。
- iPhone からの経路は 2 つある。
  - **T3 Connect**: Clerk ログイン。Cloudflare の managed tunnel で公開ホスト名を持つ。guest links にはこれが必須。
  - **Tailscale HTTPS**: `t3 serve --tailscale-serve` か `t3 pair --tailscale`。tailnet に居ることと pairing code が境界になる。
- Pro と mini-vm の連携は **linked environments**（Labs beta）で行う。両端で有効化し、30 日ごとに貼り直す。gigun の home モジュールは両方のフラグを既に `true` にしている。
- **推奨: 案 B（mini-vm を Tailscale のみで公開し、Pro とは linked environments でつなぐ。T3 Connect は Pro だけ）。** 理由は §5。

---

## 2. 仕組みと要件（公式 docs とソース）

### 2.1 `t3` CLI と server mode / headless

- インストールは `curl -fsSL https://t3.codes/install.sh | sh` で、`~/.local/bin/t3` に入り `$T3CODE_HOME/runtime/versions/<v>` に展開される。デスクトップアプリにも `t3` が同梱されている。**[確認]** `docs/user/install.md`。install.sh の冒頭コメント（"Needs only sh, tar … no Node"）
- **Intel Mac**: 「There is no `t3` executable for Intel Macs (the desktop app is available)」。サーバーを動かすにはソースからビルドするしかなく、その場合 `t3 update` とバックグラウンドサービスは使えない。**[確認]** `docs/user/install.md`「Intel Macs」。install.sh は `darwin-x64` を明示的に弾く（144 行目）。リリース資産にも `t3-0.1.7-darwin-x64` は無い（`T3-Code-0.1.7-x64.dmg` はある）**[確認]** `gh release view`
- 主なコマンド **[確認]** `docs/user/install.md`、`docs/user/background-service.md`
  - `t3 serve`: ブラウザを開かずにサーバーを起動する
  - `t3 up [--connect|--lan|--yes]`: 公開経路を選ぶ。Linux / macOS ではサービス化まで行う
  - `t3 status [--json]`
  - `t3 pair [--tailscale] [--scope …]`
  - `t3 service install|status|restart|uninstall|protect`
  - `t3 update`
  - `t3 auth session list|revoke`
  - `t3 environment link <address> --pairing-code <code> --access <mode>`
  - `t3 connect link|unlink|logout`
- `t3 serve` のフラグと環境変数: `--host`（例として「127.0.0.1, 0.0.0.0, or a Tailnet IP」と説明されている）、`--port`、`--base-dir`（= `T3CODE_HOME`）、`--lan`（= `T3CODE_LAN`）、`--tailscale-serve`、`--tailscale-serve-port`、`--no-browser`。**[確認]** `apps/server/src/cli/config.ts` 31-174 行目
- バックグラウンドサービスの扱いは OS で異なる。**[確認]** `docs/user/background-service.md`「Platform support」
  - Linux: systemd **user** service。セットアップ時に linger を有効にする（管理者権限が要る）。
  - macOS: ログイン時に起動し、ログアウトで止まる。
- 新規サービスは loopback だけで待ち受ける。`--lan` を付けると LAN と Tailscale のアドレスでも待ち受けるが、public アドレスでは待ち受けない。その場合の防御は pairing code だけになる。**[確認]** 同「Local network access」
- Linux で agent がメモリを使い切るときの対策として `t3 service protect` がある（OOM 保護。Tailscale と SSH も保護対象にできる）。**[確認]** 同
- **nixpkgs**: `t3code` 0.1.6 は x86_64-linux を含み、`bin/t3`（node のラッパー）と `bin/t3code-desktop` を出す。NixOS モジュールは無い。Nix 管理下の版は「use Nix to update them instead of the in-app updater or `t3 update`」とされている。**[確認]** gigun の nixpkgs で `nix eval` → `{"v":"0.1.6","pl":[…"x86_64-linux"…]}`。`pkgs/by-name/t3/t3code/unwrapped.nix` 166 行目（`makeWrapper … $out/bin/t3`）。`nixos/modules` に t3code の記述なし。`docs/user/install.md`「Nix」
- **版のずれ**: Pro のデスクトップは brew cask で 0.1.7 以降へ自動更新される。nixpkgs の server は 0.1.6 のままになる。「server が app より古い」場合、UI は更新を勧めるが、Nix 管理の server には「needs a manual update」として skip される **[確認: 一般的な挙動は `docs/user/updating.md`。Nix 管理の server に対して実際にどう表示されるかは推測]**。互換が無い場合に何が壊れるかは未確認。

### 2.2 T3 Connect

- デスクトップでは **Settings → Sharing & access → T3 Connect**、CLI では `t3 up --connect`（= `t3 connect`）で有効にする。他の端末は同じ T3 Connect アカウントでサインインして環境を選ぶ。SSH 越しの CLI では URL と短いコードが出るので、別の端末で承認する（OAuth のコールバックポートを転送する必要は無い）。**[確認]** `docs/user/remote-access.md`「T3 Connect」
- 無料で **3 台まで**つなげる。スマホとブラウザは数に入らない。T3 Chat の Pro で 10 台、Premier で 100 台。**[確認]** 同「More machines with T3 Chat」
- 中身 **[確認]** `docs/internals/t3-connect.md`
  - 認証基盤は Clerk。
  - relay は環境リンクの管理と bootstrap credential の仲介だけを行い、**アプリの HTTP / WebSocket は proxy しない**。クライアントは tunnel のホスト名へ直接つなぐ。
  - tunnel は Cloudflare の managed tunnel。host は版を固定した `cloudflared` を T3 home にダウンロードして起動する。PATH 上の `cloudflared` や `T3CODE_CLOUDFLARED_PATH` があればそれを優先し、置き換えない。
  - session token は DPoP で client の鍵に束縛され、relay は受け取らない。ただし docs 自身が「relay の署名鍵が破られれば無害ではない」と明記している（trust assumption）。
  - webhook 中継（`/v1/hooks/...`）だけは relay が転送する。
- CLI host は停止時に tunnel を手放し、次の起動で張り直す。`t3 connect unlink` で公開を止めてもログインは残る。**[確認]** 同、`docs/user/remote-access.md`「Manage or revoke access」
- Pro が寝ると届かないので、gigun は `pmset -c sleep 0` を入れ済み（ryoppippi と同じ）。**[確認]** dotfiles `nix/modules/darwin/system.nix` 169-174 行目、ryoppippi `nix/modules/darwin/system.nix` 111-115 行目（commit `c6e5ffa3`）

### 2.3 LAN / Tailscale 直結

- `t3 up --lan` か `t3 serve --lan` で LAN と tailnet でも待ち受ける。`t3 pair` で QR と pairing URL を出す。pairing は端末を認可し、以後は token なしで再接続できる。リンクは 1 端末につき 1 回限り。**[確認]** `docs/user/remote-access.md`「Pair over a LAN or private network」
- **Tailscale HTTPS**: `t3 serve --tailscale-serve`、または起動中のサーバーに `t3 pair --tailscale` を使う。`https://machine.tailnet.ts.net/` の pairing link が出て、serve の mapping は再起動後も残る。**[確認]** 同「Tailscale HTTPS」
- 1 台の機械が複数の route（LAN / Tailscale / VPN / public / SSH / T3 Connect）を持てる。T3 Connect か pairing でつながると、LAN と Tailscale のアドレスを route として学習し、最初に応答した route を使う。**[確認]** 同「Reach one machine several ways」
- app.t3.codes（ホスト版の web）は HTTPS エンドポイントが必須。モバイルアプリは HTTP でも IP 直打ちでつながる。**[確認]** 同「Hosted web app」
- 外部エージェントの MCP サインイン（`/mcp`）は https か localhost でないと完了しない。Tailscale の素の http アドレスでは見つけられるがサインインできない。**[確認]** `docs/user/outside-agents.md`

### 2.4 Desktop-managed SSH

- デスクトップアプリから SSH 先に server を立てて port forward する。接続先の要件は「Linux or an Apple Silicon Mac」と `curl`/`wget`、`tar`、`sha256sum`/`shasum`。`~/.t3/runtime` に server をダウンロードし、provider の CLI は非対話 login shell の PATH から探す。**[確認]** `docs/user/remote-access.md`「Desktop-managed SSH」
- **mini の macOS（Intel）は対象外。** mini-vm は形式上は対象。ただし NixOS にダウンロードした実行ファイルが動くかは nix-ld 次第になる **[推測]**。mini-vm では `programs.nix-ld.enable = true` が設定済み **[確認]** `nix/modules/nixos/mini-vm.nix` 859 行目。iPhone からは使えない（デスクトップの機能）。

### 2.5 Linked environments（Labs beta）

- 2 台をつなぎ、片方の agent がもう片方でスレッドの起動・送信・待機・停止、質問への回答、キュー・プロジェクト・予定タスクの管理を行える。`delegate_task` で同じリポジトリのプロジェクトへ仕事を渡し、終わると結果で起こされる。**[確認]** `docs/user/remote-access.md`「Link another environment」
- 要件と性質 **[確認]** 同上
  - **両端で Settings → Labs から有効化**する。
  - 操作する側で **Settings → Environments → Linked environments → Link**、または `t3 environment link <address> --pairing-code <code> --access <mode>`。
  - access は上限として働く。full 未満では、リンク経由で始めたスレッドしか触れず、相手のセットアップスクリプトは実行されない。
  - リンクの寿命は **30 日**で、更新には新しい pairing code が要る。
  - 相手側の Sharing & access で revoke できる。
- gigun の home モジュールは `linkedEnvironmentsEnabled = true; guestSharingEnabled = true;` を宣言済みで、`nix/modules/home/default.nix` が `./programs/t3code` を OS 分岐なしで import している。そのため mini-vm の `~/.t3/userdata/settings.json` にも同じ値が merge される **[確認: 宣言と import。mini-vm の実ファイルは未確認]**。

### 2.6 Guest sharing（Labs beta）

- スレッドを 1 人に共有する。アカウントは不要で、閲覧と質問の提案ができる。リンクは 24 時間有効で 1 ブラウザ限り。ゲストの発言は host が Send / Dismiss するまで実行されない。**T3 Connect が必須**（リンクが T3 Connect のアドレスを指すため）。**[確認]** `docs/user/guest-links.md`
- token は thread と share id の HMAC で、`SessionStore` に入らないので RPC / WS / MCP には使えない。guest のルートは T3 Connect がそのホスト名を配信している間だけ有効。**[確認]** `docs/internals/environment-auth.md`「Guest links are not sessions」
- ゲストには agent が読んだ値も見える。共有してよいスレッドだけを渡す。**[確認]** `docs/user/guest-links.md`

### 2.7 権限の粒度

- `--scope` を付けない pairing は全権限になる（access 管理と T3 Connect 管理を含む）。`terminal:operate` は server ユーザーの shell、`orchestration:operate` は full access の agent を起動できるので、実質的にどちらも全権と同じ。スマホを読むだけにするなら `--scope orchestration:read` などに絞る。**[確認]** `docs/user/remote-access.md`「Manage or revoke access」、`docs/internals/environment-auth.md`

---

## 3. gigun の環境で効く前提

| 機械 | T3 の担い手 | 根拠 |
|---|---|---|
| MacBook Pro（aarch64-darwin） | brew cask `t3-code` と home モジュール `programs/t3code`（settings を jq で merge）。AC 時 `pmset -c sleep 0` | **[確認]** `nix/modules/darwin/homebrew.nix` 83 行目、`nix/modules/home/programs/t3code/default.nix`、`system.nix` 169-174 行目 |
| mini macOS（x86_64-darwin、Nix 凍結、Ansible へ移行中） | CLI もサービスも無い（§2.1）。役割を減らす方針 | **[確認]** CLAUDE.md、ADR 0014 |
| mini-vm（NixOS、x86_64-linux、24/365） | 未導入。nix-ld あり。`tailscale serve` は 8787 で既に使っている（宣言外の状態） | **[確認]** `mini-vm.nix` 859 行目、`docs/mini-vm.md` 214 行目 |
| iPhone | App Store の T3 Code | **[確認]** `docs/user/install.md`「Mobile app」 |

tailnet の ACL は全タグ間で IP を全許可している（`tag:admin-device/client/storage/proxmox/server`）**[確認]** `tofu/tailscale/policy.hujson.tftpl` 15-35 行目。iPhone にどのタグが付いているかは未確認で、タグが無い端末は grants の外になる **[推測]**。

mini-vm の既存の方針 **[確認]** `mini-vm.nix` 897-898 行目、1226-1228 行目
- 常駐物は「user service は linger が宣言から漏れるので、`User=` 付きの system service」にする（cloudflare-os）。
- Cloudflare OS は「tailscale serve では境界が tailnet に居るかどうかになる」ことを理由に Cloudflare Access へ移した。

未解決の todo `id:0006` として「realbind の業務コードを mini-vm から隔離する」が残っている **[確認]** `todo.txt`。

---

## 4. 構成案

### 案 A: T3 Connect に一本化（ryoppippi 型の延長）

- 構成
  - Pro: 今のまま T3 Connect（デスクトップ）。
  - mini-vm: `t3 serve` を system service で常駐させ、T3 Connect にリンクする（初回だけ `t3 connect` で端末承認）。
  - iPhone: T3 Connect アカウントで両方を見る。
  - Pro↔mini-vm: linked environments。
  - 台数: Pro と mini-vm で 2/3。
- 前提: Clerk の T3 Connect アカウント、mini-vm からの外向き通信、cloudflared（自動ダウンロードか `T3CODE_CLOUDFLARED_PATH = lib.getExe pkgs.cloudflared`）。
- セキュリティ境界
  - 公開範囲: Cloudflare 上の公開ホスト名で、インターネットから到達できる。
  - 認証: Clerk のアカウント、relay が仲介する bootstrap、DPoP 付きの環境 session。
  - 信頼する第三者: T3 の relay（署名鍵）、Clerk、Cloudflare。
  - Tailscale は経路の 1 つ（学習 route）としてのみ使う。
  - 利点: guest links と app.t3.codes が使え、外出先で tailnet が無くても届く。
  - 欠点: mini-vm の shell 権限相当を第三者の認証基盤の後ろに置くことになる。realbind の業務コードが未隔離のまま公開面が増える。
- 宣言の置き場所
  - `nix/modules/nixos/mini-vm.nix` に `systemd.services.t3code`（`User=gigun`、`ExecStart = ${pkgs.t3code}/bin/t3 serve --host 127.0.0.1 --port 3773 --no-browser`、`environment.T3CODE_HOME`、`T3CODE_CLOUDFLARED_PATH`、`path` に provider CLI）。
  - provider の設定は既存の `nix/modules/home/programs/t3code` を共用する。
  - Connect のリンク状態（ログイン）は imperative なので、docs/mini-vm.md の「宣言外の状態」に追記する。

### 案 B: mini-vm は Tailscale だけ、Pro↔mini-vm は linked environments（推奨）

- 構成
  - mini-vm: `t3 serve` を system service で常駐（loopback）させ、`tailscale serve` の HTTPS で tailnet にだけ出す（`t3 serve --tailscale-serve`、または既存の 8787 と同様に宣言外で張る）。
  - iPhone と Pro: `t3 pair --tailscale` の URL で 1 回ずつ pairing する。iPhone は `--scope` で権限を絞るか、全権にするかを選ぶ。
  - Pro: T3 Connect は今のまま（Pro 自身の外出先アクセス用）。
  - Pro→mini-vm: linked environments（`t3 environment link https://mini-vm.<tailnet>.ts.net --pairing-code … --access …`）。
  - mini macOS には何も入れない。
- 前提: iPhone と Pro が同じ tailnet にいて、tag:server へ到達できる grant を持つこと。tailnet の HTTPS 証明書（mini-vm で serve 8787 を運用しているので有効と見られる **[推測]**）。
- セキュリティ境界
  - 公開範囲: tailnet 内だけ（public アドレスでは待ち受けない）。
  - 認証: tailnet の ACL と、T3 の pairing / session（scope で絞れる）。
  - 第三者は Tailscale だけで、T3 の relay、Clerk、Cloudflare に依存しない。
  - 欠点 1: guest links が使えない（T3 Connect 必須）。
  - 欠点 2: app.t3.codes は tailnet 内の https なら使える。
  - 欠点 3: 外部の hosted agent（ChatGPT など）から MCP で届かない。
  - Cloudflare OS で問題になった「境界が tailnet に居るかどうか」に戻るが、T3 は自前の pairing / session を持つ。tailnet 内の端末でも pairing 無しには入れない **[確認]** §2.3。
- 宣言の置き場所
  - `nix/modules/nixos/mini-vm.nix` に `systemd.services.t3code`（案 A と同じで、Connect 関連の環境変数は無し）。
  - `tailscale serve` は宣言外の状態として `docs/mini-vm.md` に追記するか、`--tailscale-serve` で server 自身に張らせる。後者は server を起動するたびに張り直すので VM を作り直しても漏れない **[推測: 起動時の serve の張り方はソースで未確認]**。
  - linked environments と pairing は端末側の状態なので宣言できない。30 日ごとの貼り直しは todo か通知で拾う。

### 案 C: mini macOS にデスクトップアプリを置く（参考。非推奨）

- 構成: mini の macOS に x64 dmg のデスクトップアプリ（brew cask。Ansible で宣言）を入れて Local environment を有効にする。自動ログイン済みなので起動はできる。T3 Connect か Network access で公開する。
- 前提と欠点
  - 最後のウィンドウを閉じると server が止まる。バックグラウンドサービスも `t3` CLI も無い **[確認]** §2.1。
  - agent が mini の macOS 上で直接動く。ADR 0014 の「mini の macOS の役割を減らす」に逆行する。
  - Nix 凍結中の claude / codex を provider に使うことになる。
- 利点: Xcode を直接触る agent をスマホから回せる。ただし mini-vm から `host.lima.internal` 経由で Xcode を叩く既存の経路で同じ目的は果たせる **[確認: 方針は CLAUDE.md「Mac Mini / Lima VM 規約」]**。
- 宣言の置き場所: `ansible/mini-macos` の cask 対象と、アプリの設定ファイル。home モジュールは mini macOS には効かない（Nix 凍結）。

### 比較

| | A: Connect 一本化 | B: Tailscale + linked | C: mini macOS desktop |
|---|---|---|---|
| iPhone→mini 系 | Connect | tailnet HTTPS | Connect / LAN |
| 公開範囲 | インターネット（認証付き） | tailnet のみ | どちらも可 |
| 第三者依存 | T3 relay、Clerk、Cloudflare | Tailscale | 選んだ経路次第 |
| guest links | 可 | 不可 | Connect なら可 |
| 24/365 の常駐 | system service | system service | GUI 依存（不安定） |
| 宣言の置き場所 | `mini-vm.nix` と宣言外の Connect ログイン | `mini-vm.nix` と宣言外の pairing / serve | Ansible（mini macOS） |
| ADR / 方針との整合 | realbind 未隔離のまま公開面が増える | 既存の tag:server 運用の延長 | ADR 0014 に逆行 |

---

## 5. 推奨: 案 B

1. mini の macOS は CLI もサービスも SSH 接続先も対象外なので、常駐先は mini-vm 以外に無い（§2.1、§2.4）。
2. mini-vm は shell と full access agent の権限を持ち、realbind の隔離（todo 0006）も未了。最初は公開面をインターネットに広げず、tailnet と pairing の二重にする方が既存の `tag:server` 運用と揃う。
3. スマホから使うのに T3 Connect は要らない（モバイルは pairing URL で直結できる）。Connect が必須なのは guest links と hosted agent だけ。必要になったら `t3 connect` を後から足せば案 A になる。宣言の差分は環境変数と cloudflared のパスだけ。
4. Pro との連携は linked environments で、Connect が無くても address と pairing code で張れる（§2.5）。

実装の粗い手順（実施は別タスク）:

1. `mini-vm.nix` に `systemd.services.t3code` を追加する（`User=gigun`、`WorkingDirectory`、`path` に claude / codex / git / gh、`ConditionPathExists` は不要、`Restart=always`）。
2. 版の追従方法を決める（§6 の論点 1）。
3. `t3 pair --tailscale` で iPhone と Pro を pairing する。
4. Pro で `t3 environment link` を実行する。
5. `docs/mini-vm.md` の宣言外の状態に、pairing、リンクの期限、serve の mapping を追記する。

検証は「iPhone のアプリから mini-vm のスレッドを起動できる」ことと「Pro の agent から `delegate_task` で mini-vm に渡せる」ことで行う。

---

## 6. ユーザーの判断が要る論点

1. **mini-vm の T3 server の版の追従方法**
   - (a) nixpkgs の `t3code`（現在 0.1.6。Pro の 0.1.7 より古く、更新は flake.lock 任せ）
   - (b) overlay か別 input で上流の新しい版を pin する（キャッシュを外れるのでビルドが要る）
   - (c) install.sh の `~/.t3/runtime` と `t3 update` に任せる（nix-ld 前提。宣言の外。mini-vm で動くかは未検証）
2. **T3 Connect を mini-vm で有効にするか**（guest links、外出先で tailnet が無い場合、ChatGPT からの MCP が要るか）。有効にすると無料枠 3 台のうち 2 台を使う。
3. **iPhone に与える権限**: 全権か、`--scope` で読み取りと orchestration に絞るか。iPhone に付いている Tailscale タグ（tag:server へ届くか）も確認が要る。
4. **linked environments の access 上限**（full か、それ未満か）と、30 日ごとの貼り直しをどう拾うか。
5. **mini macOS に T3 を置かないことの確定**（Xcode を使う agent は mini-vm 経由に限る）。
6. **realbind の隔離（todo 0006）を T3 の常駐より先にやるか。**
