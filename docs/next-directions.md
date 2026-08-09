# 次セッションの方向性(2026-08-06 棚卸し・第1版)

> **位置づけ**: 恒久ドキュメント(セッション引き継ぎの正典)。セッション開始時に SessionStart フック
> (`.claude/settings.json`)がこのファイルの「頭」(`session-head-end` マーカーまで)を自動注入する。
> **更新ルール**: 計画は消さない。完了は打ち消し線 + ✅、状況変化は該当箇所の直下に
> `> **YYYY-MM-DD 更新:** ...` の引用ブロックを積層する。大きな節目でタイトルの日付を更新し
> 全体を棚卸しする(積層を本文へ溶かし込む。生記録が必要な規模なら docs/log.md へ追記)。
> **作業の区切りごとに必ず更新する。**

## 現在地(2026-08-06)

- **Mac Mini (Intel) のエージェント基盤を Lima ゲスト (NixOS) へ移し、稼働中**。macOS 側は nix 管理を
  凍結し、Finder 経由の iPhone バックアップ・画面共有・Xcode 26.3 専用にした。M4 Pro から
  `ssh gigun@mini-vm` で直接入れる (Tailscale SSH / `tag:server`)。経緯はカタログの該当節。
  インスタンス名・tailnet 名・hostname はすべて `mini-vm`(`mini` は macOS 側を指す)。

- **未検証の危険**: apple/container の再起動後の復帰。Apple Silicon 限定なので mini では確認できず、
  M4 Pro を再起動しないと分からない (apiserver は launchd 登録済み)。→ `DF-5`

- **裁定待ち**: SPEC.md の扱いと CLAUDE.md「ディレクトリ構造」節の圧縮。どちらも下に理由付きで書いた。
  あわせて「やってみて分かった手順知識」の置き場所が決まっていない (CLAUDE.md は 200 行制限があり
  不適、log.md は時系列なので引きにくい)。→ `DF-2` `DF-3` `DF-6`

> **2026-08-09 更新:** mini-vm が **3日間まるごと名前解決できていなかった**ことが判明し、直した
> (`DF-9`)。DF-7 の再起動検証が ssh 到達性しか見ていなかったため素通りしていた。
> 到達性が通っていても機能していないことがある、という教訓は `DF-12` に落とした。
> あわせて mini-vm を **Cloudflare OS の常駐ホスト**にした (`DF-10`) — nix-ld で npm 配布の
> プリビルド ELF (workerd) を動かせるようにし、`pnpm run-local` を systemd で常駐させ、
> `tailscale serve` で `https://mini-vm.tailbf83fe.ts.net/` に出してある。
> ブラウザ自動化も mini で完結するようにした (`DF-11`)。
> なお 2026-08-08 に Langfuse フックの作り直し (e6f0bd5) と claude-devtools の cask 導入 (03bd4df)
> が入っているが、このファイルには未反映のまま。次の棚卸しで拾うこと。

## 着手順(次にやること)

- [ ] `DF-2` SPEC.md の扱いを決める
      2026-04-10 の初期コミット以降まったく更新されておらず、Windows 対応も Lima VM も入っていない。
      現行仕様として読まれると事故る。案: (A) 冒頭に「初期設計の記録」と注記して凍結 (推奨)、
      (B) 削除して CLAUDE.md に一本化、(C) 現状に追従。`docs/SPEC-initial.md` へ移す手もある。
      → 完了条件: 3案のどれかを実施し、現行仕様と誤読されない状態にする
- [ ] `DF-3` CLAUDE.md の「ディレクトリ構造」節を圧縮する
      `zsh/.zshrc # メイン設定` のような同語反復を削り、`zsh/functions/ # permission は 755 必須`
      のような非自明な制約だけ残す。`windows/` 配下の詳細は `windows/README.md` に委ねる。
      → 完了条件: 39 行 → 15 行程度にし、doctor の「長い節」指摘が消えること
- [ ] `DF-5` apple/container の再起動後の復帰を確認する
      M4 Pro を再起動する機会に `container system status` を見るだけ。単独で再起動する必要はない。
      → 完了条件: 再起動後に手を触れず apiserver が running であること
- [ ] `DF-6` 意思決定 (ADR) の置き場所について harness の結論を取り込む
      確定した決定を残す場所が無い。カタログは可変の方向性、log.md は時系列、コメントはコード必須、
      コミットログは却下案が残らない (revert すれば消える)、CLAUDE.md は 200 行制限。
      配布元へ起票済み: gigun-dev/claude-code#3。ADR を docs/adr/ に置き rules の `paths:` で
      スコープする案を出してある (agent-optimized ADR の推奨は番号ファイリングでなく file glob)。
      なお手順知識 (Lima のリネーム等) は ADR とは別問題で、頻度が低ければ永続化しない判断もある。
      → 完了条件: #3 の裁定が出て、このリポジトリで ADR を使うか否かが決まること
- [ ] `DF-13` Cloudflare OS に AI プロバイダを繋いで実際に使う
      現状は器が立っているだけでモデルが繋がっていない。`AiModelConfig.apiUrl` は
      「互換 API を提供する別プロバイダ用」と型定義に明記されており、UI では
      Add Model の **Advanced Settings** に "API URL" として出る (ollama/cloudflare 以外、
      かつ Gateway モードでないとき)。provider ごとの既定と喋る形式は
      anthropic=`anthropic-messages` / openai=**`openai-responses`** / google=`google-generative-ai` /
      ollama=`openai-completions` (apiToken 空なら Authorization ヘッダ自体を送らない)。
      サブスク枠を使うなら hotchpotch/openai-api-server-via-codex (`/v1/responses` 実装) を
      mini に立てて provider=openai + apiUrl=`http://127.0.0.1:18080/v1` が第一候補。
      **mini で動かす必然性**: `global_fetch_strictly_public` により本番 Worker からは
      localhost/プライベート IP に届かない。`wrangler dev` だけが意図的に例外
      (workshop-backend/wrangler.jsonc のコメントに明記)。
      Workers AI は Workers Paid でも 10,000 Neurons/日までで超過は $0.011/1,000 Neurons なので
      「$5 に収まる」前提は成り立たない。
      → 完了条件: Cloudflare OS のチャットでモデルが応答すること

> **2026-08-09 更新:** codex 側は通った。`systemd.services.codex-openai-bridge` として mini に常駐
> (`~/.codex/auth.json` を `ConditionPathExists` にしてあるので `codex login` 前は静かにスキップ)。
> `gpt-5.6-sol` / `gpt-5.4-mini` が `/v1/responses` で応答することを実測済み。
> **ブリッジが出すモデル ID (`gpt-5.6-sol`/`luna`/`terra`) は Cloudflare OS の `SUGGESTED_MODELS`
> の openai 欄と完全一致する**ので、カスタムモデル登録すら要らずピッカーから選べる。
>
> Workers AI 側は **モデル選択が支配的**と判明した。API から取れた USD/1M トークン単価:
> `qwen3-30b-a3b-fp8` $0.0509/$0.335、`gemma-4-26b-a4b-it` $0.10/$0.30、
> `gpt-oss-120b` $0.35/$0.75、`kimi-k2.7-code` $0.95/$4.00、`glm-5.2` $1.40/$4.40。
> 1日1万 Neurons = $0.11 なので、既定の Kimi だと入力 8万トークン/日で尽きるが
> **`qwen3-30b-a3b-fp8` なら入力 130万/日 — 同じ無料枠で 16 倍使える**
> (Llama 3.2 3B と同額なのに 30B MoE)。Kimi/GLM には cached input 価格 ($0.19/$0.26 per M) も
> あるので、文脈が安定する用途では実効値がさらに良くなる。
>
> 計測用に AI Gateway `cloudflare-os` を作成済み (collect_logs 有効、sliding 60s/120req の
> レート上限、`workers_ai_billing_mode=postpaid`)。AI Gateway のクレジット残高は $0 で
> auto top-up 未設定なので、勝手に課金が走る状態ではない。
>
> **残りはダッシュボード作業待ち**: OAuth client の作成には `OAuth Clients Write` 権限が要り、
> プラグインの OAuth セッションでは `10000: Authentication error` / API トークン作成も
> `9109: Unauthorized` で弾かれる。ここは人手が要る。
- [ ] `DF-15` Claude / opencode のサブスク枠もブリッジできるか調べる
      codex 枠は `openai-api-server-via-codex` で通った (`DF-13`)。同じことを Claude でやりたいが
      難度が違う。Cloudflare OS の anthropic プロバイダは pi の `anthropic-messages` 実装を使い
      拡張思考 (adaptive thinking) まで前提にしているので、ブリッジ側は **Messages API の形と
      SSE ストリーミングを本物として実装**する必要がある。`claude -p` が返すのはテキストか
      `stream-json` なので、codex のときのように既存実装を借りる形にならず翻訳層を自作することになる。
      opencode のサーバモードが OpenAI/Anthropic 互換エンドポイントを出せるかは未調査 (出せるなら
      そちらが現実的)。規約上の扱いは利用者判断で、ブリッジの README 自身も
      「アカウント共有・再販は禁止、ToS に従え」としている。
      → 完了条件: 実装するか見送るかを、翻訳層の分量を見積もった上で決めること
- [ ] `DF-14` Kitesurf を chrome-devtools-mcp から使えるか試す
      Kitesurf (2026-08-06 リリース、beta 無料) は OSS ではなくローカルには持ってこられないが、
      CDP を WebSocket で外部公開しており、ローカルから接続できる:
      `wss://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/browser-run/devtools/browser?browser=kitesurf`
      + `Authorization: Bearer <API_TOKEN>`。chrome-devtools-mcp には
      `--wsEndpoint` と `--wsHeaders '{"Authorization":"Bearer ..."}'` があるので、そのまま刺さるはず。
      狙いは「エージェントごとにブラウザを用意する」「ローカルポート競合を消す」「Chromium より
      3〜7 倍軽い」。ただし **WebGL / 動画再生 / ボット検出ハンドシェイク / 永続状態が要る長時間
      セッションは未対応**なので、ログインが要る操作はローカル Chromium 側に残す使い分けになる。
      → 完了条件: mini から Kitesurf 経由でページを取得・スクショできること
- [ ] `DF-12` 「到達性テスト」に機能確認を含める型を決める
      DF-7 は ssh が通ることを確認して合格としたが、その裏で DNS が全滅していた (`DF-9`)。
      ping/ssh が通ることと使えることは別。最低限 DNS 解決と主要サービスの HTTP 応答まで
      見るチェックを、再起動検証の定型にしたい。スクリプト化するか手順として書くかは未定。
      → 完了条件: 再起動検証の手順が「上がったか」ではなく「使えるか」を見る形になること
- [x] `DF-1` pre-push を `git/hooks/pre-push` に置く
      harness の `.githooks` は採らなかった。`core.hooksPath` は 1 つしか持てず、切り替えると
      既存の `git/hooks/pre-commit`(staged .nix の nix fmt 自動整形)が無言で死ぬため。
      検証内容は CI と同じ `nix flake check --no-build` + `nix fmt -- --ci .`。
      なお `nix flake check` は現在の system しか評価しないので、壊れている x86_64-darwin 構成は
      この関門では検出されない。
      → 2026-08-06 / f5c82f2 / 成功パス: 本番 push で両コマンドが走ってから push されるのを確認。
        失敗パス: 検証コマンドを `false` に差し替えた複製を実行し、exit 1 と中止メッセージを確認
- [x] `DF-4` harness の不具合を配布元へ起票する
      → 2026-08-06 / gigun-dev/claude-code#1 #2 / #1 は doctor が「毎回〜に**なる**」(症状の記述)を
        自動化指示と誤検知し、真に該当する行を挙げていないこと。#2 は init の pre-push テンプレートが
        `if ! {{CHECK_COMMAND}}` のため複合コマンドで `(! a) && b` と解釈され前半の失敗が素通りすること
        (このリポジトリの分は修正済み、他リポジトリへ配った分は要確認)
- [x] `DF-7` mini の再起動からの自動復帰を検証する
      → 2026-08-06 / 2ff15f4 / `sudo reboot` 後、「macOS 自動ログイン → LaunchAgent → Lima 起動 →
        VM の tailscaled 復帰」が手を触れず通ることを確認。46 秒で mini へ、その直後に mini-vm へも
        ssh 成立。boot 時は `networking.hostName` が効きゲストの hostname も `mini-vm` になる
- [x] `DF-19` codex ブリッジを mini の外から使えるようにする
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
- [x] `DF-17` Cloudflare OS を Cloudflare Access でログインさせる
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
- [x] `DF-18` cloudflare-os サービスの外向き HTTPS が全滅していたのを直す
      → 2026-08-09 / (mini-vm.nix) / `kj/compat/tls.c++:269: TLS peer's certificate is not
        trusted` で workerd の外向き HTTPS が全て失敗していた。最初に踏んだのは Access の
        JWKS 取得で、ブラウザには "Can't reach the server. Retrying..." としか出ず原因が見えない。
        原因は systemd 化で環境を絞った際に `SSL_CERT_FILE` を渡し忘れたこと。対話シェルでは
        NixOS が自動で入れるため手動の `pnpm run-local` では再現しない。`procps` が無くて
        `spawn ps ENOENT` になったのと同じ罠を同じユニットで二度踏んだ。
        **教訓: 環境を絞った systemd service は、対話シェルが暗黙に与えているものを
        一つずつ失う。** AI 推論も同じ HTTPS 経路なので、Access を使わなくてもいずれ踏んでいた。
- [x] `DF-16` Cloudflare OS の公開経路を named tunnel に移し、認証境界を Access にする
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
- [x] `DF-9` mini-vm の名前解決が全滅していたのを直す
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
- [x] `DF-10` mini-vm を Cloudflare OS の常駐ホストにする
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
- [x] `DF-11` mini でブラウザ自動化を完結させる
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
- [x] `DF-8` Lima インスタンス名を mini-vm に揃える
      → 2026-08-06 / 2ff15f4 / `limactl stop` → `~/.lima/nixos` を rename → `limactl start` で改名でき、
        VM 作り直し (nix store 9.5GB の再取得) は不要だった。autostart は名前が変わるので登録し直し。
        `limactl list` が `mini-vm Running`、LaunchAgent も `io.lima-vm.autostart.mini-vm.plist` に

<!-- session-head-end: ここから下は SessionStart フックが注入しないオンデマンド領域。着手する節をそのとき読む -->

## 方向性カタログ

### Mac Mini の Intel 打ち切り対応 (2026-08-05 実施)

**背景**: nixpkgs 26.11 が x86_64-darwin を drop し、`nix run .#switch` が eval すら通らなくなった
(実際 mini は 2026-04-25 の generation 26 で止まっていた)。26.05 への固定で延命するには
nixpkgs / home-manager / nix-darwin の3つを固定する必要があり、しかも llm-agents が x86_64-darwin
非対応なので AI ツールは結局入らない。2026年末で切れる延命に複雑度を払わないと判断した。

**採った構成**: macOS を温存したまま Lima ゲスト (NixOS) を常駐させ、エージェント環境だけを移した。
T2 機のネイティブ Linux 化 (デュアルブート) は Activation Lock 解除と Secure Boot 無効化が要り、
かつ有線 LAN 未接続で Wi-Fi (BCM4364) 依存になるためリスクが高く、採らなかった。

**残る選択肢**: Xcode 26.4 以降は macOS Tahoe 26.2 必須なので、mini の Xcode は 26.3 が上限。
それが問題になる日が来たら macOS を残す理由は iPhone バックアップだけになるので、ネイティブ
NixOS 化を再検討してよい。t2linux の NixOS サポートは現役 (nixos-hardware の `apple/t2`、
kernel 6.18 LTS / 7.0 に追従)。

### Cloudflare OS を mini-vm に置いた話 (2026-08-09)

**Cloudflare OS とは**: 2026-08-05 に Apache-2.0 で公開された、Cloudflare Workers 上で動く
エージェント用ワークスペース。Linux のような OS ではない。ワークスペースが Durable Object、
各 Gadget が Dynamic Worker Facet として動く。

**自前ホストの現在地**: README の「Deploy to your own server using `workerd`」節は見出しごと
**COMING SOON**。「workerd 上で全部動くが、手順もツールもまだ無い。やるなら workerd.capnp を
自分で書け」という状態。必要なバインディングのうち DO(SQLite)/Facets と `worker_loaders` は
workerd の機能だが、**KV / R2 / Browser Rendering は Cloudflare のサービス**で、dev では
miniflare が模倣しているだけ。ここの代替が「準備中のツール」の中身。
したがって現状の最善手は `pnpm run-local` の常駐であり、これは体験版ではなく
**中身は workerd 本体**(公式ブログが明言)。将来の本番セルフホストとほぼ同じものを触れる。

**deploy 経路と repo の要否**: 作った Gadget / ブループリントは DO・KV・R2 に入り git には入らない。
repo はプラットフォームのバージョンと設定の置き場でしかない。
`os.cloudflare.app/deploy` は repo 不要、`cloudflare-os-starter` は repo 必要
(上流リリースを submodule で pin し、Workers Builds ではなく手元から `pnpm deploy`)。
starter が要求するアカウント機能は "Workers, KV, R2, Browser Rendering, and Dynamic Worker Loaders"。

**コネクティビティ**: gatekeeper が 17 個 (github/google/cloudflare/supabase/notion/confluence/
email/homeassistant/slack/spotify/zoominfo/linear/mcp/mcp-portal/context/scheduler)。
Slack は **read-only** で、bot token ではなく user token (`xoxp-`) を使い「接続した本人に見えるもの」
だけを見せる (private channel も DM も検索も含む)。許可の粒度は workspace / conversation / thread。
`gatekeeper-mcp` があるので 17 個に無いものは MCP で吸収できる。

**バージョン結合の罠**: wrangler と workerd はバージョンが結合している
(`docs/integration-testing.md`)。**nixpkgs の wrangler を使わずリポジトリの pnpm 管理下のものを使う**こと。
`packages.nix` に足すのは nodejs / pnpm までで正しい。
なお pnpm は `packageManager` の pin を見て自分でその版に切り替える (pnpm 10+ の既定) ので、
入っている pnpm の版が一致していなくてよい。

**bun に置き換えられない**: `scripts/run-local.mjs` が `pnpm install` / `pnpm --filter ... build` を
直接 spawn しており、`packageManager: pnpm@11.17.0` も宣言されている。bun 化するなら
このスクリプトの書き換えが要る。

### 宣言管理から外れているもの

- **mini の macOS**: generation 26 で凍結。設定変更は手で当てる。アンインストールはしていない
- **Lima 本体**: brew で導入 (macOS 側が nix 管理外のため)。`limactl autostart enable mini-vm` で
  LaunchAgent 登録済み。**macOS の自動ログインが前提** — 無いと再起動後に VM が上がらない。
  FileVault を有効にすると自動ログインが使えなくなり 24/365 運用が崩れる。
  インスタンス名は当初 `nixos` (テンプレート名のまま) だったが、`limactl stop` →
  `~/.lima/` 配下のディレクトリを rename → `limactl start` で改名できた
  (公式サポートされた操作ではないが動く。autostart は名前が変わるので登録し直しが要る)
- **`~/.local/bin`**: PATH 末尾の例外レーン。self-update 前提のツールや nixpkgs にない uv tool 用
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
