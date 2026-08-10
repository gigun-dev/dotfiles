# 次セッションの方向性(2026-08-10 棚卸し・第2版)

> **位置づけ**: セッション引き継ぎの正典。SessionStart フックが `session-head-end` まで注入する。
> **頭は予算制**(10,000 字超で無言に切り詰められる)。書くのは「いまどこか」「次に何をするか」だけで、
> 詳細はマーカー以降へ。**計画は消さない。着手順を手で編集しない**(書き手は `nd-tasks.sh` だけ)。
> 完了は `--done`(証拠行が必須)、状況変化は `> **YYYY-MM-DD 更新:**` を積層し、嵩んだら棚卸し。

## 現在地(2026-08-10)

- **エージェント基盤は mini-vm** (Mac Mini 上の Lima ゲスト / NixOS)。macOS 側は nix 管理を凍結し
  iPhone バックアップ・画面共有・Xcode 26.3 専用。`ssh gigun@mini-vm` (Tailscale SSH / `tag:server`)。
  インスタンス名・tailnet 名・hostname はすべて `mini-vm`(`mini` は macOS 側を指す)。

- **Cloudflare OS が mini-vm に常駐し、公開境界は Cloudflare**。`https://os.097969.xyz`
  (named tunnel + Access、Cloudflare アカウントでログイン)と `https://codex.097969.xyz`
  (ローカル codex を OpenAI 互換 API として外へ。Access は張れず守りはブリッジの api_key のみ
  → `DF-22`)。Tailscale は SSH 専用に戻した。

- **秘密とエッジ構成は宣言管理下**。秘密は agenix (`secrets/*.age`)、Cloudflare のリソースは
  OpenTofu (`tofu/`、state は R2)。VM を作り直しても `nix run .#switch`、アカウントを作り直しても
  `nix run .#tofu -- apply` で戻せる。**トンネル本体だけ管理外**(`tunnel_secret` が state に
  平文で入るため。詳細は完了記録の `DF-20`)。

- **未検証の危険**: apple/container の再起動後の復帰。Apple Silicon 限定で mini では確認できず、
  M4 Pro を再起動しないと分からない (apiserver は launchd 登録済み)。→ `DF-5`

- **繰り返している失敗の形**: **検知器自身が壊れていると、壊れていることに気づけない**
  (切り詰め警告が切り詰めで消える / ssh 到達性で DNS 全滅を素通り)。「確認した」と書くときは
  確認手段が生きているかを別経路で疑う。→ `DF-12`・カタログ「正典の頭が…」節

- **裁定待ち**: SPEC.md の扱い、CLAUDE.md「ディレクトリ構造」節の圧縮、確定した決定 (ADR) の
  置き場所。→ `DF-2` `DF-3` `DF-6`

## 着手順(次にやること)

**順序の理由**: `DF-13` が主線(Cloudflare OS を使える状態にする)、`DF-24` `DF-22` はその周辺。
`DF-12` は今日の教訓を型にする作業で、後回しだと同じ事故を繰り返す。以降は裁定待ちか随伴作業。

- [ ] `DF-13` Cloudflare OS に AI プロバイダを繋いで実際に使う
      codex 側は通っている(mini に常駐、モデル ID が `SUGGESTED_MODELS` と一致するので登録不要)。
      残りは Workers AI 側で、**モデル選択が支配的** — 同じ無料枠で `qwen3-30b-a3b-fp8` は既定の
      Kimi の 16 倍使える。単価表と経緯はカタログ「AI プロバイダ」節。
      → 完了条件: Cloudflare OS のチャットでモデルが応答し、Neurons 消費が実測できること
- [ ] `DF-24` Langfuse を codex 経由の推論に挟む
      Claude Code 側は導入済み (e6f0bd5)。**openai プロバイダだけ観測できる**(`apiUrl` を
      差し替えて LiteLLM を挟む)。Workers AI は baseUrl 固定、AI Gateway は codex と排他。
      → 完了条件: codex 経由の推論が Langfuse のトレースに出ること
- [ ] `DF-22` codex エンドポイントにレート制限を入れる
      公開網に出ていて守りは 40 文字の api_key 1 枚だけ。Access は張れない(OpenAI 互換 API に
      ブラウザログインを挟むとクライアントが使えなくなる)。
      → 完了条件: 認証失敗が続く送信元に制限がかかること
- [ ] `DF-12` 「到達性テスト」に機能確認を含める型を決める
      `DF-7` は ssh 到達性で合格としたが、その裏で DNS が全滅していた。最低限 DNS 解決と主要
      サービスの HTTP 応答まで見る形にしたい。スクリプト化するか手順として書くかは未定。
      → 完了条件: 再起動検証の手順が「上がったか」ではなく「使えるか」を見る形になること
- [ ] `DF-14` Kitesurf を chrome-devtools-mcp から使えるか試す
      CDP を WebSocket で公開しており `--wsEndpoint` でそのまま刺さるはず。狙いは軽さと
      「エージェントごとにブラウザ」。接続 URL と未対応の機能はカタログ「Kitesurf」節。
      → 完了条件: mini から Kitesurf 経由でページを取得・スクショできること
- [ ] `DF-15` Claude / opencode のサブスク枠もブリッジできるか調べる
      codex は既存実装を借りて通ったが、Claude は Messages API と SSE の自作になり難度が段違い。
      opencode のサーバモードが互換エンドポイントを出せるなら、そちらが現実的。
      → 完了条件: 実装するか見送るかを、翻訳層の分量を見積もった上で決めること
- [ ] `DF-2` SPEC.md の扱いを決める
      2026-04-10 以降未更新で Windows も Lima VM も無い。現行仕様と誤読されると事故る。
      案: (A) 凍結を明記 (推奨) / (B) CLAUDE.md へ一本化 / (C) 追従。
      → 完了条件: 3案のどれかを実施し、現行仕様と誤読されない状態にする
- [ ] `DF-3` CLAUDE.md の「ディレクトリ構造」節を圧縮する
      同語反復を削り、非自明な制約 (`permission は 755 必須`) だけ残す。
      → 完了条件: 39 行 → 15 行程度にし、doctor の「長い節」指摘が消えること
- [ ] `DF-5` apple/container の再起動後の復帰を確認する
      M4 Pro を再起動する機会に `container system status` を見るだけ。
      → 完了条件: 再起動後に手を触れず apiserver が running であること
- [ ] `DF-6` 意思決定 (ADR) の置き場所について harness の結論を取り込む
      確定した決定を残す場所が無い。配布元へ起票済み: gigun-dev/claude-code#3。
      → 完了条件: #3 の裁定が出て、このリポジトリで ADR を使うか否かが決まること
- [ ] `DF-29` マーカー以降の行数警告 (417行/閾値250) をどう畳むか決める
      完了記録は追記専用で増える一方なのに、上限は頭を降ろす先と同じ領域にかかっている。
      → 完了条件: 毎セッション出る警告が消えるか、消せない理由が正典に書かれていること
<!-- session-head-end: ここから下は SessionStart フックが注入しないオンデマンド領域。着手する節をそのとき読む -->

## 完了記録(着手順から降ろしたもの)

頭は予算制なので、完了した項目はここへ降ろす。**ID は再利用しない**(log.md から参照されるため)。

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
  > **2026-08-10 更新:** Slack platform CLI をこのレーンから外し、brew cask へ移した (b3c33b8)。
  > 公式インストーラの `~/.slack/bin` を symlink する形で、新規 Mac で再現できず v3.14.0 に固着していた。
  > **教訓 1**: 「self-update 前提だからこのレーン」は理由にならない。`SLACK_SKIP_UPDATE=1` のような
  > 更新抑止の口があれば宣言管理下に置ける (既存の `AGY_CLI_DISABLE_AUTO_UPDATE` と同じ形)。
  > 抑止しないと自己更新が Caskroom の実体を上書きし、brew の記録とズレて `brew upgrade` が効かなくなる。
  > **教訓 2**: nixpkgs に同名パッケージがあっても別プロジェクトのことがある。nixpkgs の `slack-cli`
  > (0.18.0) は rockymadden/slack-cli というメッセージ投稿用シェルスクリプトで、公式 platform CLI とは無関係。
  > **他のツールを移す前に確認すること**: (1) 同名 cask/nixpkgs が本当に同じものか (homepage を見る)、
  > (2) 更新抑止の環境変数があるか (`strings <bin> | grep -oE 'SLACK_[A-Z0-9_]+'` の要領)、
  > (3) 設定・認証の置き場所が実体と分離しているか (Slack CLI は `~/.slack` が config dir なので再ログイン不要だった)。
  > **残りの住人 (2026-08-10 実測)**: uv tool 群 12 コマンド (`hf` `huggingface-cli` `tiny-agents` `idb`
  > `it2` `kimi` `kimi-cli` `majin` `mlx_whisper` `plamo-translate` `skills-ref` `yt-dlp`) + `python3.12`
  > = 下記「保留中の課題」の本体 / 自己更新バイナリ `coderabbit` (+ alias `cr`) / 自作スクリプト `npx_safe` /
  > uv installer が置く `env` `env.fish`。
  > **そのうち `sheldon` と `claude` は既に死蔵**: どちらも nix 管理下 (`packages.nix:49` sheldon /
  > `packages.nix:21` claude-code) にあり `/etc/profiles/per-user/gigun/bin` が PATH で先に来るため、
  > `~/.local/bin` 側は呼ばれていない。claude は nix 側 2.1.226 が走る一方 `~/.local/bin` 側は 2.1.207 で
  > 取り残されていた (`which -a` と両方の `--version` で確認)。消しても影響しないはずだが、
  > **claude は自分自身を実行中なので消すのは別セッションで**。
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

### Cloudflare OS の AI プロバイダ (2026-08-09〜10 調査)

**プロバイダごとの既定と喋る形式**: anthropic=`anthropic-messages` / openai=**`openai-responses`** /
google=`google-generative-ai` / ollama=`openai-completions`(apiToken 空なら Authorization ヘッダ
自体を送らない)。`AiModelConfig.apiUrl` は「互換 API を提供する別プロバイダ用」と型定義に明記されて
おり、UI では Add Model の **Advanced Settings** に "API URL" として出る(ollama/cloudflare 以外、
かつ Gateway モードでないとき)。

**codex ブリッジ (通っている)**: hotchpotch/openai-api-server-via-codex を
`systemd.services.codex-openai-bridge` として mini に常駐させた。`~/.codex/auth.json` を
`ConditionPathExists` にしてあるので `codex login` 前は静かにスキップする。
`gpt-5.6-sol` / `gpt-5.4-mini` が `/v1/responses` で応答することを実測済み。
**ブリッジが出すモデル ID (`gpt-5.6-sol`/`luna`/`terra`) は Cloudflare OS の `SUGGESTED_MODELS` の
openai 欄と完全一致する**ので、カスタムモデル登録すら要らずピッカーから選べる。

**mini で動かす必然性**: `global_fetch_strictly_public` により本番 Worker からは localhost /
プライベート IP に届かない。`wrangler dev` だけが意図的な例外
(workshop-backend/wrangler.jsonc のコメントに明記)。

**Workers AI はモデル選択が支配的**。API から取れた USD/1M トークン単価(入力/出力):
`qwen3-30b-a3b-fp8` $0.0509/$0.335、`gemma-4-26b-a4b-it` $0.10/$0.30、`gpt-oss-120b` $0.35/$0.75、
`kimi-k2.7-code` $0.95/$4.00、`glm-5.2` $1.40/$4.40。
Workers Paid でも 10,000 Neurons/日までで超過は $0.011/1,000 Neurons なので「$5 に収まる」前提は
成り立たない。1日1万 Neurons = $0.11 で、既定の Kimi だと入力 8万トークン/日で尽きるが
**`qwen3-30b-a3b-fp8` なら入力 130万/日 — 同じ無料枠で 16 倍使える**(Llama 3.2 3B と同額なのに
30B MoE)。Kimi/GLM には cached input 価格 ($0.19/$0.26 per M) もあるので、文脈が安定する用途では
実効値がさらに良くなる。

**AI Gateway**: `cloudflare-os` を作成済み(collect_logs 有効、sliding 60s/120req、
`workers_ai_billing_mode=postpaid`)。クレジット残高 $0・auto top-up 未設定なので勝手に課金は走らない。
**ただし codex ブリッジと排他** — `CF_AI_GATEWAY` を設定すると全モデルがゲートウェイ経由になり
`apiUrl` が無視される。どちらか一方しか使えない。

**Langfuse を挟める範囲 (`DF-24`)**: openai プロバイダは `apiUrl` を差し替えられるので
`Cloudflare OS → LiteLLM (Langfuse callback) → codex ブリッジ` と数珠つなぎにできる(全部 mini 内で
完結する)。**cloudflare プロバイダ (Workers AI) は baseUrl がコード内で固定**されていて
(`getModelDirect` の `case "cloudflare"`)、プロキシを挟む余地が無い。よって「Langfuse で codex 側、
Cloudflare ダッシュボードで Workers AI 側」の二本立てになる。

**Claude のブリッジが難しい理由 (`DF-15`)**: Cloudflare OS の anthropic プロバイダは pi の
`anthropic-messages` 実装を使い拡張思考 (adaptive thinking) まで前提にしているので、ブリッジ側は
**Messages API の形と SSE ストリーミングを本物として実装**する必要がある。`claude -p` が返すのは
テキストか `stream-json` なので、codex のときのように既存実装を借りる形にならず翻訳層を自作する
ことになる。opencode のサーバモードが互換エンドポイントを出せるかは未調査(出せるならそちらが現実的)。
規約上の扱いは利用者判断で、ブリッジの README 自身も「アカウント共有・再販は禁止、ToS に従え」としている。

**使用状況の可視化は期待できない**: アプリは AI 使用の内訳を記録していない(analytics に
トークン/コストのイベントが無く、`totalCost` はワークスペースごとの単純な累計)。codex(カタログ上の
架空のドル)と Workers AI(実際のドル)を混ぜると `totalCost` は意味を失うので、**ワークスペースを分ける**こと。

### Kitesurf (2026-08-06 リリース、beta 無料)

OSS ではなくローカルには持ってこられないが、CDP を WebSocket で外部公開しており接続できる:
`wss://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/browser-run/devtools/browser?browser=kitesurf`
+ `Authorization: Bearer <API_TOKEN>`。chrome-devtools-mcp には `--wsEndpoint` と
`--wsHeaders '{"Authorization":"Bearer ..."}'` があるので、そのまま刺さるはず。
**WebGL / 動画再生 / ボット検出ハンドシェイク / 永続状態が要る長時間セッションは未対応**なので、
ログインが要る操作はローカル Chromium 側に残す使い分けになる。

### 正典の頭が切り詰められていた話 (2026-08-10)

**症状**: `docs/next-directions.md` の頭が 23,191 字まで膨れ、SessionStart の stdout が無言で
切り詰められていた。10,000 字を超えると先頭 2KB のプレビューだけが注入される
(anthropics/claude-code#70460 / #84021)。数セッション分、正典は「注入したつもりで届いていない」状態だった。

**なぜ気づけなかったか**: 当時の `session-start.sh` (v0.2.1) は**頭を全部出してから末尾に警告を
付ける**構造だった。切り詰めが起きた瞬間、末尾にある「切り詰められています」の警告が真っ先に消える。
**切り詰めを知らせる検知器が、切り詰めによって死ぬ。**

**直し方**: v0.7.0 は順序を「(1) 全部計測 → (2) 警告 → (3) 頭」に変えてある。警告は必ず先頭 2KB に
入るので、頭の後半が消えることは避けられなくても、**消えたことが分からない**状態は避けられる。
あわせて予算の単位が行から文字になった(行数は日本語率で 2 倍以上ぶれるため、複数リポジトリへ配る
予算の単位として成立しない)。

**この形の失敗は再発している**: 再起動検証が ssh 到達性しか見ず DNS 全滅を素通りしたのも同じ
(`DF-12`)。「確認した」と書くときは、確認手段自体が生きているかを別経路で疑うこと。
