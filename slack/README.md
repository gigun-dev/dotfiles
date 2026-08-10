# Slack アプリ (Cloudflare OS 用)

`manifest.json` は Cloudflare OS の `gatekeeper-slack` が使う Slack アプリの宣言。
JSON にはコメントが書けないので、非自明な判断はここに置く。

## 現物

| 項目 | 値 |
|---|---|
| App ID | `A0BNY2BC3C3` |
| ワークスペース | realbind-production (`T04DYN3T4RJ`) |
| 作成日 | 2026-08-10 |

Client ID / Secret は agenix の `secrets/cloudflare-os-env.age` に
`SLACK_CLIENT_ID` / `SLACK_CLIENT_SECRET` として入っている。
mini-vm の systemd が `EnvironmentFile` で読み、`run-dev-server.js` の
`SHARED_GATEKEEPER_CREDS` が `gatekeeper-slack` の `CLIENT_ID` / `CLIENT_SECRET` へ流す。

## なぜこの形か

- **`scopes.bot` ではなく `scopes.user`**: `gatekeeper-slack` はユーザートークン (`xoxp-`) を
  `user_scope` で要求する設計。「接続した人が見えるものだけをエージェントに見せる」ため
  (プライベートチャンネル・DM・検索が含まれる)。bot トークンでは要件を満たさない。
- **読み取り専用**: `chat:write` は入れていない。`gatekeeper-slack` の README が
  "This gatekeeper is read-only and never sends or modifies Slack data" と明言しており、
  書き込みスコープを足しても gatekeeper 側が使わないので無意味に権限が広がるだけ。
  Slack への投稿が要るなら別の gatekeeper が要る (→ `docs/next-directions.md` の `DF-31`)。
- **`token_rotation_enabled: true`**: トークンが約 12 時間で失効し
  `oauth.v2.access?grant_type=refresh_token` で更新される。gatekeeper 側が対応済み
  (非ローテーションもフォールバックとして動くが、有効が推奨)。
- **redirect URL は `<BASE_URL>/oauth`**: `BASE_URL` は mini-vm.nix の ExecStartPre が
  `https://os.097969.xyz/gatekeeper/slack` を生成している。**ここがずれると OAuth が
  redirect_uri 不一致で落ちる**ので、公開 URL を変えたら両方直すこと。
- **bot user / slash command / socket mode を持たない**: Bolt のテンプレートには入っているが、
  この用途では Slack 側からイベントを受ける必要がまったく無い。攻撃面を減らすため削った。

## 適用

`slack manifest sync` は「プロジェクトディレクトリ」を要求するため、この `manifest.json` を
単体で push することはできない。やり直すときは Slack CLI でプロジェクトを作り、生成された
`manifest.json` をこれで置き換えてから同期する:

```sh
slack create <name> -t slack-samples/bolt-js-starter-template -f
cp slack/manifest.json <name>/manifest.json
cd <name>
slack manifest validate --team T04DYN3T4RJ
slack app install --team T04DYN3T4RJ --environment deployed   # 新規作成もこれ
# 既存アプリの更新なら:
slack manifest sync --team T04DYN3T4RJ --experiment manifest-sync --force
```

**`manifest sync` は `--experiment manifest-sync` が要る** (v4.6.0 時点で実験扱い)。
付けないと `experiment_required` で落ちる。

**Client Secret は CLI では取得できない。** `slack app settings` はブラウザを開くだけで、
認証情報を出すサブコマンドは存在しない。作成後に
<https://api.slack.com/apps/A0BNY2BC3C3> の Basic Information から 1 回だけ手でコピーする。
