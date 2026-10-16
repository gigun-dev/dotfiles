# codex の MCP OAuth は Cloudflare Access 越しの入口から通知のタップで張り直す

Date: 2026-10-16

mini-vm の codex (0.163.0) が使う MCP server `cloudflare` (https://mcp.cloudflare.com/mcp) の OAuth grant は、refresh の有無にかかわらずログインから 30 日で切れる (cloudflare/mcp の `refreshTokenTTL` 2592000 秒、idle TTL なし)。2026-09-08 のログインは 10 月に切れ、journal には `OAuth refresh token was rejected ... invalid_grant: Grant not found` が並んでいた。張り直しは ssh して `codex mcp login cloudflare --no-browser` を打ち、callback URL を貼る手作業で、月 1 回の作業としては重い。そこで **mini-vm の既存 named tunnel に新しいホスト名 `mcp-login.097969.xyz` を足し、Cloudflare Access (ADR 0009 と同じ account member ポリシー) で守った入口** から、スマホだけで張り直せるようにする。

- **入口はタップされてから login を始める。** `codex-mcp-login` (常駐、User=gigun、127.0.0.1:18790) が `/start` で `codex mcp login <server> --no-browser --oauth-client-registration DCR -c mcp_oauth_callback_port=18791 -c mcp_oauth_callback_url="https://mcp-login.097969.xyz/callback"` を起動し、stdout の認可 URL へ 302 する。codex が callback を待つ 300 秒は、タップ後から数え始める。
- **callback も同じホスト名で受け、入口が loopback で codex の listener へ中継する。** cloudflared の ingress はホスト名ごとに 1 規則なので、パスで振り分けられない。中継すると codex の終了まで待って成否を画面に出せる。同意後の遷移はトップレベルのナビゲーションなので、`/start` で付いた Access cookie がそのまま効く。
- **入口自身も `Cf-Access-Jwt-Assertion` を検証する。** 監視 UI と違い、ここを通った人の Cloudflare アカウントが mini-vm の codex の MCP 資格情報になる。Access の設定が消えたときに素通しにしないための二枚目 (cloudflared 側の `originRequest.access` は NixOS モジュールに無い)。
- **リマインダはログイン成功時に記録した時刻から 27 日目に鳴らす。** `~/.codex/.credentials.json` の mtime は refresh のたびに進むので、ログインからの日数の代わりにならない。`codex-mcp-login-remind` (毎時) が、27 日以降は毎朝 9 時台に 1 回、journal に refresh 拒否 (server 名は問わない) が出たら時刻を問わず 1 回、タップで `/start` を開く Bark を送る。ssh の手動ログインは `codex-mcp-relogin` ラッパが同じ記録を残す。

Rejected:

- **Tailscale Serve で callback を受ける** —— 却下。tailnet に居ないと使えず、利用者は tailnet に依存しない経路を求めた (ADR 0009 と同じく認証境界は Cloudflare Access に置く)。
- **従来の callback URL 貼り付け (`--no-browser`) のまま運用する** —— 却下。ssh と URL のコピーが毎月要る。障害時の手段としては残す。
- **通知に認可 URL を直接載せる** —— 却下。login は通知を送った時点で始まり、codex は 300 秒で callback を諦める。通知に気づくのが遅れると URL は無効になっている。

Consequences:

- インターネットから引けるホスト名が 1 つ増え、守りは Cloudflare Access と origin の JWT 検証だけになる。どちらかを外すときは、この入口を止めてから。
- codex は callback URL が loopback でないと listener を `0.0.0.0` に bind する (`callback_bind_host`)。tailscaled の `ts-input` が tailscale0 を filter 表の nixos-fw より前に ACCEPT するので、raw 表の PREROUTING で 18791 への loopback 以外を落としている。firewall を nftables へ移すときはこの規則も移す。
- DCR で毎回新しい OAuth client が登録される。Cloudflare 側の DCR client は 90 日使われないと失効するが、毎月張り直すので実害は無い。
- 実行中の codex-remote-control が新しい資格情報へ切り替わるかは、refresh 時に保存先を読み直す実装 (`refresh_transaction`) に依存する。切り替わらなければ `systemctl restart codex-remote-control` が要る (2026-10-16 時点で実機未確認)。
- `accessAud` は既定 null で、team の署名・iss・exp だけを見る。tofu apply 後に Access アプリの AUD を設定すると、他アプリの JWT を拒否できる。
