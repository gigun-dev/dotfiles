# 完了記録アーカイブ

旧 `docs/next-directions.md`(2026-09-10 に廃止)から降ろした完了項目。**ID(`DF-*`)は
再利用しない**(コミットメッセージから参照されるため、欠番はそのまま残す)。

- ~~`DF-27` next-directions.md の頭を棚卸しして注入コストを下げる~~ ✅ 2026-08-10
  → 2026-08-10 / (docs/next-directions.md 第2版) / 頭を 23,191 字 → 約 4,000 字にした。
    二段構えで、まず `nd-tasks.sh --archive` で完了 15 件を `## 完了記録` へ降ろし
    (23,191 → 7,752 字、これで切り詰めは解消)、次に積層していた `> 更新:` ブロック 2 つを
    現在地の本文へ溶かし込み、着手順の各項目から調査メモをカタログへ移した。
    移した先: 「Cloudflare OS の AI プロバイダ」「Kitesurf」「正典の頭が切り詰められていた話」。
    **降ろすのと溶かし込むのは別物** — アーカイブは完了項目にしか効かないので、未完了項目が
    抱える調査メモはカタログへ移すしかない。ここが今回の嵩の主因だった (`DF-13` 単独で約 2,400 字)。
    あわせて `session-start.sh` を v0.2.1 → v0.7.0 に更新した。旧版は警告を頭の**後**に出す
    構造で、切り詰められると警告ごと消えていた (この事故が長く見つからなかった直接の原因)。
    検証: `nd-tasks.sh --lint` が警告 0 件、フックの実出力は 3,966 字(切り詰め閾値 10,000)。
    **ただしカタログ側の行数警告は残っている** (417 行 / 閾値 250)。頭から降ろした先が
    マーカー以降なので、頭を減らすとカタログが増えるのは構造上避けられない。→ `DF-29`(採番は DF-28 を飛ばした — 証拠行に先に `DF-28` と書いてしまい、
    採番器が使用済みと判定したため。ID は再利用しないので欠番のままにする)
- ~~`DF-20` Cloudflare 側のリソースを宣言管理下に置く~~ ✅ 2026-08-10
  → 2026-08-10 / `tofu/` + `nix run .#tofu` / **OpenTofu** を採用。Terraform ではないのは
    nixpkgs の `terraform` が BUSL 1.1 で unfree なため (OpenTofu は MPL 2.0 で free、
    provider レジストリは互換)。Pulumi は言語ランタイムを持ち込む分が重く、この規模に合わない。
    取り込み方は `tofu import` コマンドではなく **`import` ブロック + `-generate-config-out`**。
    provider v5 は v4 から大規模にリソース名が変わっており (`cloudflare_record` →
    `cloudflare_dns_record`、`cloudflare_access_*` → `cloudflare_zero_trust_access_*`)、
    属性名を手で当てるのは無理筋だった。生成させてから null を削って整理する手順が速い。
    管理下: DNS `os` / `codex`、Access アプリ、Cloudflare IdP、AI Gateway。
    **state は R2 (`tofu-state` バケット) の S3 互換バックエンド**。ローカルに置くと Mac と
    mini-vm で食い違い、失うと import からやり直しになる。`skip_credentials_validation` 等の
    skip フラグ群が必須 (AWS 前提の検証が全部落ちる)。ロックは OpenTofu 1.10+ の
    `use_lockfile = true` で、R2 の条件付き書き込みだけで済む (DynamoDB 不要)。
    認証情報は agenix (`secrets/tofu-env.age`) に入れ、`nix run .#tofu` が実行のたびに
    復号して環境変数へ流す。**mini-vm の cloudflare-os が使う `CLOUDFLARE_API_TOKEN`
    (Workers AI + Workers Scripts) とは別トークン**。名前が同じなので混同注意。
    検証: `tofu plan` が `No changes`。apply は `5 imported, 0 added, 0 changed, 0 destroyed`。
    **残った穴**: Access のポリシー `gigun-dev account members` は `reusable = false` の
    アプリ専用ポリシーで、独立リソースとして import できない。いまは id 参照だけなので
    **消すとコードから復元できない**。中身 (`decision = allow` /
    `include = [cloudflare_account_member]`) は `tofu/cloudflare.tf` のコメントに残した。
    → `DF-26` で解消済み。
  **管理対象外にしたもの**: トンネル本体 (`tunnel_secret` が state に平文で入る。state は
    R2 にあり暗号化していない)、`os` / `codex` 以外の DNS 22 件 (nextcloud / vikunja /
    supabase / kurrier / trmnl / forwardemail の MX・SPF・DKIM・DMARC など別プロジェクトの
    もの。ゾーン全体を宣言すると apply が消しにかかる)、`Warp Login App` (Cloudflare が
    自動生成するもの)。
  2026-08-09〜10 に API で作ったものが、どこにも宣言されていない: トンネル `cloudflare-os`、
  DNS `os.097969.xyz` / `codex.097969.xyz`、Access アプリとポリシー、Cloudflare IdP、
  AI Gateway `cloudflare-os`。再現手段は `DF-16` `DF-17` `DF-19` に書いた文章だけで、
  事故ったら手で作り直すことになる。mini-vm.nix (OS 層) と cloudflare-os の checkout
  (差分ゼロ) は再現できるのに、**エッジ層だけが再現できない**という非対称がある。
  Terraform か Pulumi の Cloudflare provider が候補。秘密は `DF-21` と同じ扱いで外に出す。
  → 完了条件: VM とアカウントを作り直しても、宣言から同じ構成を再現できること
- ~~`DF-21` 秘密を宣言管理下に置く (agenix)~~ ✅ 2026-08-10
  → 2026-08-10 / `secrets/` + flake input + mini-vm.nix / agenix を採用。sops-nix ではなく
    agenix にしたのは規模が合うため (秘密 3〜4 個、ホスト 1 台、ユーザー 1 人)。既存の
    SSH ホスト鍵をそのまま復号鍵に使えるので新しい鍵管理が発生せず、出力も
    「指定パスに owner/mode 付きでファイルを置く」形なので既存の `credentialsFile` /
    `EnvironmentFile` の書き方を変えずに済んだ。
    管理下: トンネル認証情報 / Cloudflare API トークン / codex ブリッジの api_key。
    **`~/.codex/auth.json` は意図的に対象外**。OAuth のリフレッシュトークンは codex 自身が
    書き換える可変状態で、activation のたびに古い暗号文で上書きすると認証が壊れる。
    VM 再作成時は `codex login` をやり直す (secrets.nix に明記)。
    ついでに非秘密の設定 (`PUBLIC_BASE_URL` / `CF_ACCESS_AUD` / `CF_ACCESS_ISS` /
    gatekeeper の `BASE_URL`) も ExecStartPre で生成する形にし、手で置いた設定をゼロにした。
    検証: 復号後にブリッジが鍵なし 401 / 鍵あり 200、Cloudflare OS 200、
    `os.097969.xyz` 302 (Access)、`codex.097969.xyz` 401。全サービス restarts=0。
    **注意**: `path` を指定した秘密は実体へのシンボリックリンクになるため、`stat` は
    `777` に見える。所有権と権限は `/run/agenix.d/<n>/<name>` 側で確認すること。
  現在 mini に手で置いた秘密が 4 つあり、**VM を作り直すと全部消えて手作業でやり直し**になる:
  `/var/lib/cloudflared/cloudflare-os.json` (トンネル認証情報)、
  `/var/lib/cloudflare-os/env` (Cloudflare API トークン)、
  `packages/workshop-backend/.dev.vars` (CF_ACCESS_AUD/ISS)、
  `~/.config/openai-api-server-via-codex/config.toml` (ブリッジの api_key)。
  dotfiles が public なので平文では置けないが、sops-nix / agenix なら暗号化したまま
  git に入れられ、activation 時にホスト鍵で復号できる。`DF-20` と一緒にやると効率が良い。
  → 完了条件: VM 作り直し後、`nix run .#switch` だけで秘密が揃うこと
- ~~`DF-26` Access のアプリ専用ポリシーをコードから復元可能にする~~ ✅ 2026-08-10
  → 2026-08-10 / (tofu/cloudflare.tf) / 案 (A) を採用。独立した
    `cloudflare_zero_trust_access_policy.account_members` (reusable) を作り、アプリからは
    id 参照だけにした。旧アプリ専用ポリシーは切り離しと同時に Cloudflare 側で消えた。
    **案 (B) は provider の実装漏れで不可能**だった。`cloudflare_zero_trust_access_application`
    の内蔵 `policies` の include には **`cloudflare_account_member` が無い** — 独立リソースの
    `..._access_policy` と `..._access_group` には有るのに、内蔵版のスキーマからだけ落ちている。
    `tofu providers schema -json` で include のメンバー一覧を突き合わせて確認した (v5.23.0)。
    失敗の出方が 2 段階で分かりにくい: id と include を併記すると
    `Invalid Attribute Combination` (排他)、id を外すと plan は通るのに apply が
    `include field should not be empty` で落ちる (スキーマに無い属性が静かに捨てられる)。
    **落とし穴**: ポリシー側の `session_duration` は明示しないと provider が既定値 "24h" を
    入れ、アプリ側の 168h を上書きする。旧ポリシーはこの項目を持たなかったので、
    黙って再認証が 7 日 → 1 日に縮むところだった。アプリと同じ 168h を明示している。
    検証: `tofu plan` が No changes。`aud` は不変 (= mini の `CF_ACCESS_AUD` の再設定不要)、
    `allowed_idps` も不変、`os.097969.xyz` 302 / `codex.097969.xyz` 401。
    **ブラウザから Cloudflare アカウントで実際にログインできることを確認済み** (これは
    HTTP コードでは分からない部分)。旧ポリシーが消えたことは ID 直引きで確認した —
    アカウントのポリシー一覧に出ないことは根拠にならない (再利用可能ポリシーしか
    並ばない可能性があるため)。`GET .../access/policies/10ac8b2d-…` が 12135 not_found、
    対照の新ポリシーは同じ経路で `reusable: true` / `app_count: 1` を返す。
    アプリ専用ポリシーはアプリから外れると Cloudflare 側が一緒に片付ける
    (OpenTofu は削除を指示していない。plan は `1 to add, 1 to change, 0 to destroy`)。
- ~~`DF-1` pre-push を `git/hooks/pre-push` に置く~~ ✅ 2026-08-06
  harness の `.githooks` は採らなかった。`core.hooksPath` は 1 つしか持てず、切り替えると
  既存の `git/hooks/pre-commit`(staged .nix の nix fmt 自動整形)が無言で死ぬため。
  検証内容は CI と同じ `nix flake check --no-build` + `nix fmt -- --ci .`。
  なお `nix flake check` は現在の system しか評価しないので、壊れている x86_64-darwin 構成は
  この関門では検出されない。
  → 2026-08-06 / f5c82f2 / 成功パス: 本番 push で両コマンドが走ってから push されるのを確認。
    失敗パス: 検証コマンドを `false` に差し替えた複製を実行し、exit 1 と中止メッセージを確認
- ~~`DF-4` harness の不具合を配布元へ起票する~~ ✅ 2026-08-06
  → 2026-08-06 / gigun-dev/claude-code#1 #2 / #1 は doctor が「毎回〜に**なる**」(症状の記述)を
    自動化指示と誤検知し、真に該当する行を挙げていないこと。#2 は init の pre-push テンプレートが
    `if ! {{CHECK_COMMAND}}` のため複合コマンドで `(! a) && b` と解釈され前半の失敗が素通りすること
    (このリポジトリの分は修正済み、他リポジトリへ配った分は要確認)
- ~~`DF-7` mini の再起動からの自動復帰を検証する~~ ✅ 2026-08-06
  → 2026-08-06 / 2ff15f4 / `sudo reboot` 後、「macOS 自動ログイン → LaunchAgent → Lima 起動 →
    VM の tailscaled 復帰」が手を触れず通ることを確認。46 秒で mini へ、その直後に mini-vm へも
    ssh 成立。boot 時は `networking.hostName` が効きゲストの hostname も `mini-vm` になる
- ~~`DF-25` Workers AI バインディングを有効化して webFetch の文書変換を通す~~ ✅ 2026-08-10
  → 2026-08-10 / (mini-vm.nix) / `--use-workers-ai-binding` を付けて `env.WORKERS_AI` を生やした。
    使うのは webFetch の文書→Markdown 変換だけ (HTML/PDF/DOCX/XLSX/CSV/XML など)。
    無い状態では `WebFetchEnv.ai` が undefined のまま `env.ai.toMarkdown()` が呼ばれて
    TypeError になり、**エージェントが普通の Web ページを読めない**。ガードは無い
    (`web-fetch.ts:26` の `ai: Ai` は必須フィールド)。変換対象はモデルを使わない形式に
    絞られているので課金は発生せず、画像だけ意図的に除外されている。
    **踏んだ罠**: バインディングは `AI / remote` としてリモート実行され、wrangler が
    リモートセッションを張る。その生成には Workers AI の権限では足りず
    **`Workers Scripts: Edit` が別途要る**。無いと起動時に
    `remote session could not be authenticated` で落ちてクラッシュループする。
    紛らわしいのは、トークンが有効でもこれが出ること (Workers AI の REST も AI Gateway も
    200 を返していた) — 「トークンが壊れている」と誤診しやすい。上流の既知の制約で
    狭い権限で動かす要望が cloudflare/workers-sdk#10091 に上がっている。
    **代償**: この権限はアカウント内の Worker をデプロイ・改変・削除できる。トークンは
    無期限で 24/365 の機械にある。webFetch の変換機能と引き換えに受け入れた判断。
- ~~`DF-19` codex ブリッジを mini の外から使えるようにする~~ ✅ 2026-08-10
  → 2026-08-10 / (mini-vm.nix) / `codex.097969.xyz` を既存トンネルの ingress に追加
    (新しいトンネルは張らず、cloudflared は 1 プロセスのまま)。
    **Access は張らない。** Access で守ると `CF-Access-Client-Id` /
    `CF-Access-Client-Secret` ヘッダが要るが、Cloudflare OS の Add Model 画面は
    apiUrl と apiToken (= `Authorization: Bearer`) しか送れず、カスタムヘッダを足す口が無い。
    代わりにブリッジ自身の `api_key` で守る (Authorization に乗るので噛み合う)。
    鍵は `~/.config/openai-api-server-via-codex/config.toml` (0600、git 外)。
    検証: mini 内で鍵なし 401 / 鍵あり 200、M4 Pro から鍵なし 401 かつ Access の 302 が
    挟まらないことを確認。
    **ローカルの Cloudflare OS はこの URL を使わないこと。** 同じ mini に居るので
    `http://127.0.0.1:18080/v1` へループバックで届く。トンネル経由にすると
    mini → エッジ → mini と往復し、エッジやトンネルの不調がローカルの AI まで巻き込む。
    この口の価値は「mini の外から使えること」だけ (将来 Cloudflare にデプロイした OS、
    Mac、CI 等)。
    **未了**: 公開網に出た口が 40 文字の鍵 1 枚で守られている状態。総当たりを鈍らせる
    レート制限 (Cloudflare WAF) は未設定。
    **規約**: サブスク枠のエンドポイントを公開網に出すのは、ブリッジ README の
    「アカウント共有・再販禁止」に近づく方向。単独利用の範囲に留めること。
- ~~`DF-17` Cloudflare OS を Cloudflare Access でログインさせる~~ ✅ 2026-08-09
  → 2026-08-09 / 6d7decd 以降 / **3 層すべてを揃えないと動かない。しかも欠けたときの症状が
    3 層とも「ユーザー名/パスワード画面が出る」で同一**なので、切り分けが極めて難しい。
    1. エッジ: Access アプリ + **Cloudflare IdP**。`cloudflare_account_member` セレクタは
       Cloudflare IdP を使っていないと機能しない (docs に明記)。この tailnet の Zero Trust は
       One-time PIN しか無い古い世代だったので、`type: "cloudflare"` の IdP を追加した
       (`restrict_to_account_members: true`)。アプリ側は `allowed_idps` をその IdP だけに絞り、
       `auto_redirect_to_identity: true` で選択画面を出さない。
       なお Access アプリの更新は `PATCH` が `10405: Method not allowed for this
       authentication scheme` で弾かれる。`PUT` で全項目を送り直すこと。
    2. バックエンド: `CF_ACCESS_AUD` (アプリの aud) と `CF_ACCESS_ISS` (team URL) の両方。
       **置き場所は `packages/workshop-backend/.dev.vars`** — wrangler が設定ファイルと同じ
       ディレクトリの `.dev.vars` を直接読む。リポジトリ直下の `.dev.vars` は
       `run-dev-server.js` が自前で読んで `OPTIONAL_FEATURE_VARS` の allowlist に載る変数だけを
       転記する仕組みで、`CF_ACCESS_*` はそこに無いため**届かない**。
       一度 allowlist にパッチを当てたが、worker 直下へ置けば不要と判明したので撤回した
       (上流との差分ゼロを維持できる)。
    3. フロントエンド: **`VITE_CF_ACCESS_MODE=true` (ビルド時)**。`useAuth.ts:5` が
       `import.meta.env.VITE_CF_ACCESS_MODE` を見ており、false だとフロントは
       `authenticateFromCfAccess()` を一度も呼ばない。実行時 env をいくら直しても効かない。
       vite が `VITE_` 接頭辞を拾うので systemd の environment に置けば足りる。
       ただし `run-local.mjs` はソースのハッシュが変わらないとビルドを飛ばすので、
       初回は `.run-local-stamp` を消して強制リビルドすること。
  → 切り分けの道具: JWT 無しで `curl http://localhost:8787/api` を叩き、
    `Cross-origin API access not allowed.` / `Invalid CF access JWT.` /
    `Access JWT didn't specify email address.` のどれが返るかを見る。この 3 つは
    `if (env.CF_ACCESS_AUD)` ブロックの内側にしか無いので、**返ってくること自体が
    バックエンド層が効いている証拠**になる。
- ~~`DF-18` cloudflare-os サービスの外向き HTTPS が全滅していたのを直す~~ ✅ 2026-08-09
  → 2026-08-09 / (mini-vm.nix) / `kj/compat/tls.c++:269: TLS peer's certificate is not
    trusted` で workerd の外向き HTTPS が全て失敗していた。最初に踏んだのは Access の
    JWKS 取得で、ブラウザには "Can't reach the server. Retrying..." としか出ず原因が見えない。
    原因は systemd 化で環境を絞った際に `SSL_CERT_FILE` を渡し忘れたこと。対話シェルでは
    NixOS が自動で入れるため手動の `pnpm run-local` では再現しない。`procps` が無くて
    `spawn ps ENOENT` になったのと同じ罠を同じユニットで二度踏んだ。
    **教訓: 環境を絞った systemd service は、対話シェルが暗黙に与えているものを
    一つずつ失う。** AI 推論も同じ HTTPS 経路なので、Access を使わなくてもいずれ踏んでいた。
- ~~`DF-16` Cloudflare OS の公開経路を named tunnel に移し、認証境界を Access にする~~ ✅ 2026-08-09
  → 2026-08-09 / 6d7decd / `tailscale serve` だと境界が「tailnet に居るかどうか」になり、
    要件の「Cloudflare アカウントでログイン」にならなかった。トンネルを張るとエッジが
    前段に立つので Access が使える。Tailscale は ssh 用に残す。
    作ったもの: トンネル `cloudflare-os` (5b8ec787-4730-4b2b-87b8-e86acbd3954b、config_src=local)、
    DNS `os.097969.xyz` CNAME → `<id>.cfargotunnel.com` (proxied)、
    Access アプリ `Cloudflare OS (mini-vm)` (self_hosted / 168h /
    aud 171feed26a9a959a47baea51a250993280867e6a264baca9328220dc93fbf419)、
    ポリシー `cloudflare_account_member` (= gigun-dev のアカウントメンバー)。
    **アプリ内 OAuth gatekeeper は足さない判断をした。** Cloudflare OS は Access を一級の
    認証方式として持ち、Access の verified email で UserDurableObject を引く
    (docs/oauth-signin.md が "the same scheme as Cloudflare Access" と明記) ため、
    Access だけでログインが完結し二重ログインにならない。後から gatekeeper を connect
    しても email が同じなのでアカウントは分裂しない。
    検証: 未認証の GET が 302 で `gigun.cloudflareaccess.com` へ飛び、`kid` が aud と一致。
    cloudflared は 4 本 (kix06/nrt09/kix05/nrt09) で接続。
    **積み残し**: cloudflared 側で `Cf-Access-Jwt-Assertion` を検証する
    `originRequest.access` は NixOS モジュールが公開しておらず設定できない。多層防御の
    1 枚が欠けている (主境界のエッジ Access は効いているので実害は小さいが、Access 設定を
    消すと素通しになる)。
    **共有の設計**: Access ポリシーは `cloudflare_account_member` 以外に `email` /
    `email_domain` も書けるので、外部の人に共有するのにアカウントメンバー化も REALBIND への
    移設も要らない。共有は 2 層 (Access = URL に到達できるか / Cloudflare OS の collaborator =
    到達後に何が見えるか) で、両方通らないと見えない。`use` ロールは UI のみでコードは見えない。
- ~~`DF-9` mini-vm の名前解決が全滅していたのを直す~~ ✅ 2026-08-09
  → 2026-08-09 / 7ac7a24 / `nix run .#switch` が github.com を引けず発覚。tailscaled が
    `dns: resolver: forward: no upstream resolvers set, returning SERVFAIL` を吐き続けていた。
    dhcpcd と tailscaled の起動順レース: tailnet は global nameserver を配らず「system default を
    使え」と指示するが、boot 直後の tailscaled はまだ書かれていない resolv.conf を読んで
    上流ゼロを掴み、その後 resolv.conf を自分 (100.100.100.100) で上書きするため、
    以降誰も上流を取り直さず恒久的に壊れる。tailscaled の起動時刻は 2026-08-06 23:07 で
    DF-7 の再起動検証の瞬間。**3日間壊れていた**。
    `networking.nameservers = [ "1.1.1.1" "1.0.0.1" ]` を宣言してレースごと消した。
    検証: 再起動後、手を触れず `getent hosts github.com` が通り、
    `tailscale dns query` の上流に DoH / 192.168.5.2 / 1.1.1.1 / 1.0.0.1 が並ぶことを確認。
    なお切り分け中に手で書いた `/etc/resolv.conf` は resolvconf の署名検査に引っかかって
    switch を一度失敗させた (`resolvconf -u` で復旧)。手で書くなら必ず戻すこと。
- ~~`DF-10` mini-vm を Cloudflare OS の常駐ホストにする~~ ✅ 2026-08-09
  → 2026-08-09 / e26d5a8 f74b50f 9ac26a4 /
    (1) `programs.nix-ld.enable` — wrangler が実行時に取得する
    `@cloudflare/workerd-linux-64` は interpreter が `/lib64/ld-linux-x86-64.so.2` の素の ELF で、
    NixOS では起動できない (バイナリはあるのに ENOENT という分かりにくい失敗)。
    `npx workerd --version` → `workerd 2026-08-09` で実証。
    (2) `pnpm run-local` を **User= 付きの system service** で常駐 (user service だと
    boot 起動に loginctl enable-linger という imperative な状態が要り宣言から漏れる)。
    `ConditionPathExists` でチェックアウト不在時の無限再起動を防止。
    (3) PATH を絞ったことで `Error: spawn ps ENOENT` が出た — wrangler のビルドが
    `ps -o pid --no-headers --ppid <pid>` を叩くため `procps` が要る。対話 shell では
    常に PATH にあるので systemd 化して初めて表面化した。
    (4) 公開は `sudo tailscale serve --bg 8787` で `https://mini-vm.tailbf83fe.ts.net/`。
    wrangler dev は 127.0.0.1 にしか bind せず `--ip` の通し口も無い (run-dev-server.js が
    引数を固定生成する) ため、リポジトリを patch せずに済むこの形を採った。
    検証: 再起動後、手を触れず M4 Pro から 200。cold start は約 1 分半 (17 gatekeeper +
    フロントエンドを全ビルドするため)、ビルド済みなら数十秒。
- ~~`DF-11` mini でブラウザ自動化を完結させる~~ ✅ 2026-08-09
  → 2026-08-09 / 6446447 / `chromium` を **systemPackages** に追加。packages.nix ではなく
    ここなのは、packages.nix が WSL と共用でありブラウザ操作を Windows ネイティブ Chrome に
    投げる WSL には不要なため、および `/run/current-system/sw/bin/chromium` という
    更新で変わらない安定パスが要るため。
    chrome-devtools-mcp は実行ファイルを環境変数で受け取らず `--executablePath` /
    `--browserUrl` / `--wsEndpoint` のみを解する (`--help` で確認)。よって mini では
    `claude mcp add chrome-devtools --scope user -- bunx chrome-devtools-mcp@latest
    --headless --isolated --executablePath=/run/current-system/sw/bin/chromium` で登録した
    (mini にはこのプラグインが入っておらず、プラグイン側の args は固定で NixOS では動かないため)。
    `--isolated` は同時に走るエージェントがプロファイルを奪い合わないようにするため。
    検証: sandbox 有効のまま `--dump-dom` が通り、`claude mcp list` が Connected。
- ~~`DF-8` Lima インスタンス名を mini-vm に揃える~~ ✅ 2026-08-06
  → 2026-08-06 / 2ff15f4 / `limactl stop` → `~/.lima/nixos` を rename → `limactl start` で改名でき、
    VM 作り直し (nix store 9.5GB の再取得) は不要だった。autostart は名前が変わるので登録し直し。
    `limactl list` が `mini-vm Running`、LaunchAgent も `io.lima-vm.autostart.mini-vm.plist` に
- ~~`DF-34` cloudflare-os を宣言管理下に置き、あわせて fork を畳む~~ ✅ 2026-09-06
  いまは ghq の imperative なチェックアウトを systemd が WorkingDirectory にしているだけで、
  版は誰も固定していない。実際 2026-09-01 に 106 コミット (3 週間) 遅れているのを
  たまたま気づいた。flake input として pin すれば更新は nix flake update + switch に
  統合され、flake.lock が唯一の真実という既存の原則に乗り、generation でロールバックも効く。
  難所: 実行形態が pnpm run-local (install とビルドを実行時にやる) なので、
  素直に derivation にはならない。pin だけして checkout は残す折衷もありうる。
  fork (gigun-dev/cloudflare-os) は独自コミット 0 本で実質何も担っていないため同時に畳む。
  畳むと cloudflareOsDir と fork 運用のコメント (mini-vm.nix:14-25) が変わる。
  自動更新まで踏み込むのはこれができてから (戻せないものを無人で上げない)。
  → 完了条件: cloudflare-os の版が flake.lock か同等の宣言で固定され、更新が nix run .#update / switch の経路に乗ること
  → cloudflare-os は flake input として rev を pin 済み (flake.nix:95, flake=false) で、ExecStartPre が毎起動時に flake.lock の rev へ checkout する (mini-vm.nix)。fork も 2026-09-01 に畳み済み。2026-09-06 に現物を確認し、実質完了していたと判断
- ~~`DF-36` Cloudflare トンネル本体を OpenTofu の管理下へ入れる~~ ✅ 2026-09-06
      state 暗号化 (2026-09-06) で前提は済んだ。あとは import するだけ。
      → 完了条件: `tofu plan` が No changes のままトンネルが state に入っていること
      → ae6ba93 / tofu plan が No changes、apply は 1 imported / 0 added / 0 changed / 0 destroyed。state 内の tunnel_secret は null (宣言しないので載らない) で、コネクタの認証情報は agenix のまま。state 自体も PBKDF2 + AES-GCM で暗号化済み。
        **途中で一度 401 Unauthorized で止まった** — `tofu-env.age` の `CLOUDFLARE_API_TOKEN` に
        Cloudflare Tunnel の読み取り権限が無かった。ダッシュボードで Account / Cloudflare Tunnel:Read を
        足して解消 (手作業)。同種の import で最初に疑う場所
- ~~`DF-33` mini-vm 再起動後に codex-remote-control が復帰し、スマホから繋がるか確認する~~ ✅ 2026-09-06
      **自動更新の再起動を解禁する前提**(mini-vm.nix がこの ID を参照している)。詳細はカタログ。
      → 完了条件: 再起動後に手を触れず、スマホの ChatGPT アプリから mini-vm が CLI として見え、実際にタスクが通ること
      → 2026-09-06 に macOS ホストごと再起動して実測。**復帰 51 秒**。機械側は全て合格 (Lima VM が autostart + 自動ログインで自動起動、常駐 5 サービスが手を触れず active、timer 再登録、健全性ゲート 4 項目通過、公開エンドポイントは再起動前と同じ os=302 / codex=404、enrollment と control socket も残存)。**スマホの ChatGPT アプリから mini-vm が見え、接続済みになることも本人が確認**。これで自動更新の再起動解禁の前提が揃った
- ~~`DF-29` マーカー以降の行数警告をどう畳むか決める~~ ✅ 2026-09-08
  → 完了条件: 毎セッション出る警告が消えるか、消せない理由が正典に書かれていること
  → 2026-09-08 / docs/next-directions.md 第3版の棚卸し / 完了記録 25 件を docs/next-directions-archive.md へ、決着済みの解説 5 節を docs/{cloudflare-os,mini-intel-eol,harness-notes}.md へ切り出し、マーカー以降を 637 → 209 行にした。session-start.sh を実行して肥大警告が出ないことを確認 (閾値 250 は変更していない)
