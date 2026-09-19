# uvx の版は nix の外で日次追従させ、autoswitch と分離する

Date: 2026-09-19

`codex-openai-bridge` が動かす `openai-api-server-via-codex` は nixpkgs に無く `uvx` で実行時に取るため ADR 0003 の lock 提案 PR と required CI の経路に乗らず、版が上がる契機が「`pkgs.uv` の store パスが動いた日」という偶然に委ねられていた (実測: 再起動は 09-05 / 09-06 / 09-07 / 09-13 と不規則)。加えて plain な `uvx <pkg>` は uv の HTTP キャッシュが fresh な間 PyPI を照会しない (`DEBUG Found fresh response for: https://pypi.org/simple/openai-api-server-via-codex/`) ので、再起動しても古い版のまま上がり得た。そこで `ExecStart` を `<pkg>@latest` にして起動ごとの再解決を保証し (`DEBUG Sending revalidation request for: ...`)、日次 timer が PyPI の最新と稼働版を比べて**ずれているときだけ**再起動する `codex-openai-bridge-refresh` を置く。稼働版は refresh 側ではなく `ExecStartPost` が `/run/codex-bridge/version` へ記録する —— 手動 `systemctl restart` や `Restart = "always"` による再起動でも記録が実体から外れないのは、実際に立ち上がったプロセスから読み直す側だけだから。

この更新レーンを `dotfiles-autoswitch` に相乗りさせないことが、この ADR の本体である。健全性ゲートは `codex-openai-bridge` の稼働を見ているので、uvx の版だけが原因でゲートが落ちると**健全な nix generation の方が rollback される**。しかも nix の世代に uvx の版は含まれないので rollback しても直らず、autoswitch は毎晩 rollback と失敗を繰り返す。nix generation の更新 (ADR 0003 の経路) と uvx の版上げ (この ADR の経路) は失敗ドメインを分ける。

Rejected:

- **nix で版を pin し、lock 提案 PR の経路に乗せる** —— 却下。上流に追従したいという既存の判断 (`nix/modules/nixos/mini-vm.nix` の `codex-openai-bridge` のコメント) を覆すことになる。実際 v0.2.0 で Python/FastAPI から Go 実装へ全面置換された際も CLI と config.toml のキーは据え置きで unit は無変更で通っており、pin して手で上げる作業を増やす方が、放置して codex バックエンドの仕様変更に取り残されるリスクより高くつく。
- **週次のカレンダー起動で無条件に再起動する** —— 却下。更新の遅れ (最大 7 日) と破壊的変更を踏む頻度を交換しただけで、版差分で起動を決めれば両方取れる。平常時の無駄な再起動もゼロになる (利用者の裁定)。
- **`RuntimeMaxSec = "7d"` で周期的に落とす** —— 却下。unit 1 行で済むが再起動時刻が前回起動からの相対で漂い日中に落ち得る上、再起動後の疎通確認を挟む場所が無い。
- **`try-restart` の終了コードだけで成否を判定する** —— 却下。プロセスは上がって API が壊れている状態を見逃す。`/v1/models` が **401** を返すまで待つ (config.toml に api_key があるため無認証の呼び出しは常に 401 で、200 はこの経路では来ない)。ADR 0003 の健全性ゲートと同じ「到達性ではなく機能を見る」型。

Consequences:

- PyPI から版が直接降ってくる経路なので、required CI もロールバックも通らない。逃げ道は `ExecStart` を `<pkg>@X.Y.Z` に書き換えて switch すること。
- 版検出は uv のキャッシュレイアウト (`archive-v0`) に依存する。壊れると版は `unknown` に落ち、毎日 PyPI 最新と不一致になって `try-restart` を打ち続ける (`todo.txt` の `id:0046`)。
- refresh の成否は Bark 通知だけで担保し、健全性ゲートには含めていない (`todo.txt` の `id:0045`)。
