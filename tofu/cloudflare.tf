# Cloudflare 側の現状をコード化したもの。
#
# 元は `tofu plan -generate-config-out=generated.tf` の出力。生成物は provider の
# 全属性を `null` 込みで列挙してくるので、意味のあるものだけ残して整理してある。
# `null` は「未設定」と等価なので落として問題ないが、**落とすたびに plan を回して
# 差分が出ないことを確認する**こと (computed 属性は落とすと逆に差分が出ることがある)。

# --- DNS -------------------------------------------------------------------
# どちらも mini-vm の named tunnel (5b8ec787-…) を指す CNAME。
# `<uuid>.cfargotunnel.com` は Cloudflare エッジがトンネルへ転送するための特殊ホスト名で、
# 実体の IP は世に出ない。だから mini-vm をポート開放せずに公開できている。
#
# ttl = 1 は「自動」の意味 (秒数ではない)。proxied = true のレコードでは TTL を
# 自分で決められないので、Cloudflare 側が常に 1 を返す。手で 300 等に変えると差分が
# 出続けるので触らないこと。

resource "cloudflare_dns_record" "os" {
  zone_id = local.zone_id
  name    = "os.097969.xyz"
  type    = "CNAME"
  content = "${local.tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Cloudflare OS on mini-vm (named tunnel)"
}

resource "cloudflare_dns_record" "codex" {
  zone_id = local.zone_id
  name    = "codex.097969.xyz"
  type    = "CNAME"
  content = "${local.tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  # os と違って Access を噛ませていない。codex ブリッジは OpenAI 互換 API で、
  # ブラウザからのログインが挟まると API クライアントが使えなくなるため。
  # 代わりにブリッジ自身の api_key で守っている (agenix: codex-bridge-config.toml.age)。
  comment = "codex bridge (OpenAI-compatible) on mini-vm — protected by the bridge's own api_key, no Access"
}

# --- Zero Trust Access -----------------------------------------------------
# os.097969.xyz の前段に立つエッジ認証。cloudflare-os 自体は認証を持たないので、
# 「公開 URL に出す」ことと「自分だけが入れる」ことをここで両立させている。

resource "cloudflare_zero_trust_access_application" "cloudflare_os" {
  account_id = local.account_id
  name       = "Cloudflare OS (mini-vm)"
  type       = "self_hosted"
  domain     = "os.097969.xyz"

  destinations = [
    {
      type = "public"
      uri  = "os.097969.xyz"
    },
  ]

  # Cloudflare IdP だけを許可する。これを絞らないと onetimepin (メール OTP) も
  # 選択肢に出てしまい、「Cloudflare アカウントでログイン」という体験にならない。
  allowed_idps = [cloudflare_zero_trust_access_identity_provider.cloudflare.id]

  # IdP が 1 つしか無いので選択画面を出さず直行させる。上の allowed_idps と対で意味を持つ。
  auto_redirect_to_identity = true

  # 168h = 7 日。cloudflare-os は常用するので毎日再認証させたくない。
  session_duration = "168h"

  app_launcher_visible       = true
  enable_binding_cookie      = false
  http_only_cookie_attribute = true
  options_preflight_bypass   = false

  # このアプリ専用ポリシー (reusable = false)。**中身が id 参照だけなのは意図的ではなく
  # provider の制約**: 非 reusable ポリシーは独立した cloudflare_zero_trust_access_policy
  # として import できず、ここでは id でしか指せない。
  # 実際の中身は「decision = allow / include = [cloudflare_account_member]」つまり
  # gigun-dev アカウントのメンバーなら通す、というもの。
  # → このポリシーを誤って消すと、コードからは復元できない。DF-20 の残課題。
  policies = [
    {
      id         = "10ac8b2d-171c-424f-b76a-1ef2fa271a95"
      precedence = 1
    },
  ]
}

# Cloudflare 自身を IdP にする設定。type = "cloudflare" がこれ。
# これがあるおかげでメール OTP を経由せず「Cloudflare にログイン済みならそのまま通す」に
# なっている。restrict_to_account_members = true が実質の認可条件で、これを外すと
# 任意の Cloudflare アカウント保有者が IdP を通過してしまう (最終的には上の
# ポリシーで弾かれるが、防御は手前で効かせる)。
resource "cloudflare_zero_trust_access_identity_provider" "cloudflare" {
  account_id = local.account_id
  name       = "Cloudflare"
  type       = "cloudflare"

  config = {
    restrict_to_account_members = true
  }
}

# --- AI Gateway ------------------------------------------------------------
# cloudflare-os 用に作ったゲートウェイ。**現在は実際には経由していない** —
# cloudflare-os は CF_AI_GATEWAY を設定すると全モデルをゲートウェイ経由にしてしまい、
# codex ブリッジ向けの apiUrl が無視される (両立しない)。codex を使う限り無効のまま。
# Workers AI 専用のワークスペースに寄せるなら有効化する余地がある。
resource "cloudflare_ai_gateway" "cloudflare_os" {
  account_id = local.account_id
  id         = "cloudflare-os"

  # 60 秒あたり 120 リクエストのスライディングウィンドウ。個人利用の暴走 (エージェントの
  # 無限ループ等) を止めるための上限で、性能要件から出た数字ではない。
  rate_limiting_interval  = 60
  rate_limiting_limit     = 120
  rate_limiting_technique = "sliding"

  # cache_ttl = 0 はキャッシュ無効。エージェントの応答が使い回されると挙動が読めなくなる。
  cache_ttl                  = 0
  cache_invalidate_on_update = false

  # ログは 1000 万件で頭打ちにして古いものから消す (無制限だと課金対象になりうる)。
  collect_logs            = true
  log_management          = 10000000
  log_management_strategy = "DELETE_OLDEST"

  authentication = false
  logpush        = false
  zdr            = false
  store_id       = ""

  # postpaid = Workers Paid の従量課金。prepaid にすると事前購入した AI Gateway
  # クレジットから引かれる。$5 の Workers Paid 枠で回している現状は postpaid が正。
  workers_ai_billing_mode = "postpaid"
}
