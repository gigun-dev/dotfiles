# Cloudflare 側の現状をコード化したもの。
#
# 元は `tofu plan -generate-config-out=generated.tf` の出力。生成物は provider の
# 全属性を `null` 込みで列挙してくるので、意味のあるものだけ残して整理してある。
# `null` は「未設定」と等価なので落として問題ないが、**落とすたびに plan を回して
# 差分が出ないことを確認する**こと (computed 属性は落とすと逆に差分が出ることがある)。

# --- Cloudflare Tunnel ------------------------------------------------------
# mini-vm の named tunnel。下の DNS レコード 2 件の向き先で、公開経路の実体。
#
# **`tunnel_secret` は宣言しない**。optional かつ computed ではないので、書かなければ
# state に載らない (import 直後の値も null)。コネクタの認証情報は agenix
# (secrets/cloudflared-cloudflare-os.json.age) が持ったままで、ここが管理するのは
# 「トンネルという入れ物が存在すること」だけ。
#
# 2026-09-06 に取り込んだ。それまで管理外だったのは、state が平文の R2 にあり
# tunnel_secret を持ち込みたくなかったため。state 暗号化 (versions.tf) で前提が消えた。
# 取り込みには API トークンへ `Cloudflare Tunnel Write` の追加が要った (401 で判明)。
# ダッシュボードの編集画面では `Argo Tunnel (Legacy)` と表示されるが、確認画面と
# 公式ドキュメントでは `Cloudflare Tunnel` で、同一の権限グループ。
#
# ingress の定義はここではなく mini-vm.nix 側 (`config_src = "local"` なので
# cloudflared が読む設定ファイルが真実)。Cloudflare 側の管理画面には無い。
resource "cloudflare_zero_trust_tunnel_cloudflared" "mini_vm" {
  account_id = local.account_id
  name       = "cloudflare-os"
  config_src = "local"
}

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

  # ポリシーは独立リソースとして定義し、ここでは id 参照だけにする (下の
  # cloudflare_zero_trust_access_policy.account_members のコメントに経緯)。
  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.account_members.id
      precedence = 1
    },
  ]
}

# 「gigun-dev アカウントのメンバーなら通す」ポリシー。
#
# **なぜアプリの policies ブロックに直接書かないのか** (2026-08-10 に実測して判明):
# provider v5.23.0 の `cloudflare_zero_trust_access_application` は、内蔵 policies の
# include に `cloudflare_account_member` を**持っていない**。独立リソースである
# `cloudflare_zero_trust_access_policy` と `..._access_group` には存在するのに、
# 内蔵版のスキーマからだけ抜け落ちている (provider 側の実装漏れ)。
# `tofu providers schema -json` で include のメンバー一覧を突き合わせて確認した。
#
# 内蔵に書こうとすると 2 段階で失敗する:
#   1. id と include を併記 → `Invalid Attribute Combination` (排他)
#   2. id を外して include だけ → plan は通るが apply が API に空の include を送り、
#      `access.api.error.invalid_request: include field should not be empty` で落ちる
#      (スキーマに無い属性が静かに捨てられるため)
#
# 元はダッシュボードが作った reusable = false のアプリ専用ポリシーで、その形だと
# 独立リソースとして import できず id 参照しか書けなかった = ポリシーを消したら
# コードから復元できなかった。ここで**再利用可能ポリシーとして作り直す**ことで、
# 中身がコードに載り DF-20 の完了条件 (アカウントを作り直しても再現できる) を満たす。
resource "cloudflare_zero_trust_access_policy" "account_members" {
  account_id = local.account_id
  name       = "gigun-dev account members"
  decision   = "allow"

  # これ 1 つが実質の認可条件。gigun-dev のアカウントメンバーであること。
  # Cloudflare IdP の restrict_to_account_members = true と二重にかけている
  # (IdP 側で手前で弾き、ここで最終判定する)。
  include = [
    { cloudflare_account_member = {} },
  ]

  # 明示しないと provider が既定値の "24h" を入れる。ポリシー側の session_duration は
  # アプリ側 (168h) を上書きするので、黙って再認証が 7 日 → 1 日に縮む。
  # 元のアプリ専用ポリシーはこの項目を持っていなかった (= アプリ側が効いていた) ので、
  # 実効の挙動を変えないためにアプリと同じ 168h を明示する。
  session_duration = "168h"
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
