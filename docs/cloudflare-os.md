# Cloudflare OS の自前ホスト

> 旧 `docs/next-directions.md`(2026-09-10 に廃止)の棚卸し(2026-09-08)で正典から降ろした。決着済みの経緯。

## Cloudflare OS を mini-vm に置いた話 (2026-08-09)

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

## Cloudflare OS の AI プロバイダ (2026-08-09〜10 調査)

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

## タスクの調査メモ

旧 `docs/next-directions.md`(2026-09-10 に廃止)の「着手順から降ろした詳細」節から、
Cloudflare OS 関連のタスク調査メモを移した。

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
  単価表は上記「Cloudflare OS の AI プロバイダ」節。
- **`DF-30` (gatekeeper-mcp)** — 動的クライアント登録 (RFC 7591) しか対応しておらず、事前登録
  必須の認可サーバー (Slack MCP など) に 502 で繋がらない。
- **`DF-31` (Slack 書き込み)** — PR #95 (approval-gated Google Drive/Sheets writes) が唯一の
  設計手本。2026-08-10 時点で draft・conflicting・レビュー 0 件・CLA 未署名で停滞中。

### Kitesurf (2026-08-06 リリース、beta 無料)

OSS ではなくローカルには持ってこられないが、CDP を WebSocket で外部公開しており接続できる:
`wss://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/browser-run/devtools/browser?browser=kitesurf`
+ `Authorization: Bearer <API_TOKEN>`。chrome-devtools-mcp には `--wsEndpoint` と
`--wsHeaders '{"Authorization":"Bearer ..."}'` があるので、そのまま刺さるはず。
**WebGL / 動画再生 / ボット検出ハンドシェイク / 永続状態が要る長時間セッションは未対応**なので、
ログインが要る操作はローカル Chromium 側に残す使い分けになる。
