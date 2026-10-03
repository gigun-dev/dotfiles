# ページは本人のAccessログインで保護する。iOSのインストーラーはSafariの
# Cookieを引き継ぐ前提にできないため、署名済みdownload URLだけ別アプリにする。
# download側の認可はWorkerが期限・署名・対象パスを検証する。Bypassだけでは
# ファイルを公開しないよう、Workerの署名検証を配備してから利用を開始する。
locals {
  ota_hostname = "install.097969.xyz"
}

resource "cloudflare_zero_trust_access_application" "ota" {
  account_id = local.account_id
  name       = "OTA app distribution"
  type       = "self_hosted"
  domain     = local.ota_hostname

  destinations               = [{ type = "public", uri = local.ota_hostname }]
  allowed_idps               = [cloudflare_zero_trust_access_identity_provider.cloudflare.id]
  auto_redirect_to_identity  = true
  session_duration           = "168h"
  app_launcher_visible       = true
  enable_binding_cookie      = false
  http_only_cookie_attribute = true
  options_preflight_bypass   = false

  # 現在のアカウントメンバーは本人1名。チーム配布を始めるときはこの管理者用
  # selectorを流用せず、OTA専用のemail/group selectorに切り替える。
  policies = [{ id = cloudflare_zero_trust_access_policy.account_members.id, precedence = 1 }]
}

resource "cloudflare_zero_trust_access_policy" "ota_signed_download" {
  account_id = local.account_id
  name       = "OTA signed downloads - Worker authorization"
  decision   = "bypass"
  include    = [{ everyone = {} }]
}

resource "cloudflare_zero_trust_access_application" "ota_signed_download" {
  account_id = local.account_id
  name       = "OTA signed download transport"
  type       = "self_hosted"
  domain     = "${local.ota_hostname}/download/*"

  # Accessはより具体的なpathアプリを優先する。例外はこのpathに閉じ、ページや
  # 署名URLを発行するendpointを同じBypassアプリへ含めない。
  destinations               = [{ type = "public", uri = "${local.ota_hostname}/download/*" }]
  app_launcher_visible       = false
  enable_binding_cookie      = false
  http_only_cookie_attribute = true
  options_preflight_bypass   = false
  policies                   = [{ id = cloudflare_zero_trust_access_policy.ota_signed_download.id, precedence = 1 }]
}

output "ota_access_audience" {
  description = "OTA Workerが検証するCloudflare Access JWT audience"
  value       = cloudflare_zero_trust_access_application.ota.aud
}

output "ota_distribution_url" {
  value = "https://${local.ota_hostname}/"
}
