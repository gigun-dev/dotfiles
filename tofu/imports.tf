# 既存リソースの取り込み。
#
# ここにあるものは**すべてダッシュボードで手作業で作ったもの**で、コードとしての記録が
# どこにも無かった。DF-20 の目的は「新しく何かを作る」ことではなく、**いまある状態を
# そのままコードに書き起こす**こと。したがって取り込み直後の `tofu plan` が
# `No changes` になるのが唯一の正解で、差分が出たら .tf の方を現物に合わせて直す
# (Cloudflare 側を .tf に合わせるのではない)。
#
# `tofu import` コマンドではなく `import` ブロックを使っている理由:
#   - 宣言的に git に残る。誰が何をいつ取り込んだかがコードとして読める。
#   - `tofu plan -generate-config-out=FILE` で HCL を自動生成できる。provider v5 の
#     スキーマを手で当てずに済む (属性名の推測ミスを防げる)。
#
# 取り込まないもの:
#   - **Cloudflare トンネル本体** — `cloudflare_zero_trust_tunnel_cloudflared` は
#     `tunnel_secret` を state に平文で保持する。state は R2 にあり暗号化していないので、
#     秘密を持ち込まない。トンネルはダッシュボード + agenix (cloudflared-*.json.age) の
#     ままにする。将来管理したくなったら OpenTofu の state encryption を先に入れること。
#   - **os / codex 以外の DNS レコード** — このゾーンには nextcloud / vikunja / supabase /
#     kurrier / trmnl / forwardemail の MX・SPF・DKIM・DMARC など 22 件が同居している。
#     どれも別プロジェクトのもので、うっかりゾーン全体を宣言すると apply が消しにかかる。
#     state に入れたものしか触られないという性質に頼って、明示した 2 件だけを管理する。
#   - **Warp Login App** — Cloudflare が WARP 用に自動生成するアプリ。手で作っていないので
#     コード化する意味が無く、消えると WARP のログインが壊れる。

locals {
  account_id = "4b00d8d779cdc4e8fbc1840248d21722" # gigun-dev
  zone_id    = "06a3b7695130629893828da708479572" # 097969.xyz

  # mini-vm の named tunnel。トンネル本体は上記のとおり管理対象外 (tunnel_secret が
  # state に平文で入るため) だが、DNS レコードの向き先として ID は必要なのでここに置く。
  #
  # **この ID を public repo に置いてよい根拠** (2026-08-11 に実測して訂正):
  # 以前ここには「cfargotunnel.com のホスト名として公開 DNS に出ているから秘密ではない」と
  # 書いていたが**それは誤り**だった。レコードは proxied なので、公開 DNS が返すのは
  # Cloudflare の anycast IP だけで `<uuid>.cfargotunnel.com` は外から見えない
  # (`dig os.097969.xyz CNAME` は空。A は 104.21.x / 172.67.x)。
  #
  # 正しい根拠は「ID だけでは何もできない」こと。トンネルへ接続するコネクタを名乗るには
  # tunnel_secret を含む認証情報 JSON が要り、それは agenix
  # (secrets/cloudflared-cloudflare-os.json.age) にしか無い。UUID は宛先の名前であって
  # 鍵ではない。とはいえ「見えない情報を晒す必要も無い」ので、積極的に公開する価値は無く、
  # ここに書いているのは DNS レコードを宣言するのに不可欠だから、という消極的な理由。
  tunnel_id = "5b8ec787-4730-4b2b-87b8-e86acbd3954b"
}

# --- DNS -------------------------------------------------------------------
# どちらも同一トンネル (5b8ec787-…) を指す CNAME。cfargotunnel.com は Cloudflare の
# エッジがトンネルへ転送するための特殊ホスト名で、実 IP は出てこない。

import {
  to = cloudflare_dns_record.os
  id = "${local.zone_id}/5e0c0283b13923af315bb936116c3a2d"
}

import {
  to = cloudflare_dns_record.codex
  id = "${local.zone_id}/34540583c77cb83a1decfae9671620bb"
}

# --- Zero Trust Access -----------------------------------------------------
# os.097969.xyz の前段に立つエッジ認証。ポリシーは reusable=false のアプリ専用ポリシー
# なので、アプリのリソースに内包される (別リソースとして import しない)。

import {
  to = cloudflare_zero_trust_access_application.cloudflare_os
  id = "accounts/${local.account_id}/75530ac8-ca3d-4904-a75b-7da5b1055ed7"
}

# Cloudflare 自身を IdP にする設定 (type = "cloudflare")。これがあるおかげで
# メールに OTP を送らずに「Cloudflare にログイン済みならそのまま通す」ができている。
# restrict_to_account_members = true が実質の認可条件。
import {
  to = cloudflare_zero_trust_access_identity_provider.cloudflare
  id = "accounts/${local.account_id}/e7de224f-5cf9-4e8e-9e43-0b1f3219195e"
}

# --- AI Gateway ------------------------------------------------------------
# cloudflare-os 用のゲートウェイ。いまは cloudflare-os から実際には通していない
# (CF_AI_GATEWAY を設定すると全モデルがゲートウェイ経由になり codex ブリッジの
# apiUrl が無視されるため) が、作ってあるのでコード化はしておく。
# import ID の形式が Access 系と違う (`accounts/` の接頭辞が付かない)。provider v5 は
# リソースごとに ID の組み立て方がバラバラで、間違えると `invalid ID` で plan ごと落ちる。
# 迷ったら import ブロックだけ書いて plan を回し、エラーメッセージに期待形式を吐かせるのが早い。
import {
  to = cloudflare_ai_gateway.cloudflare_os
  id = "${local.account_id}/cloudflare-os"
}
