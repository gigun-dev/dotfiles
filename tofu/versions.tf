# OpenTofu の土台。Terraform ではなく OpenTofu を使う理由:
#   - nixpkgs の `terraform` は BUSL 1.1 (2023-08 に HashiCorp が変更) のため unfree で、
#     `allowUnfree` を darwin 構成へ足さないと入らない。`opentofu` は MPL 2.0 で free。
#   - OpenTofu は Linux Foundation 配下のフォークで、provider レジストリも互換。
#     Cloudflare provider はそのまま使える。
terraform {
  required_version = ">= 1.9"

  required_providers {
    cloudflare = {
      source = "cloudflare/cloudflare"
      # v5 で大規模なリソース名変更があった (cloudflare_record → cloudflare_dns_record,
      # cloudflare_access_* → cloudflare_zero_trust_access_*)。v4 の記事が大量に残って
      # いるので、ネットの例をコピーするときは必ず v5 のドキュメントで確認すること。
      version = "~> 5.0"
    }
  }

  # state は R2 に置く。ローカルファイルにしない理由は 2 つ:
  #   1. Mac と mini-vm の両方から `tofu plan` を打ちたい。ローカルだと食い違う。
  #   2. state を失うと import からやり直しになる (リソース自体は無事だが、
  #      「何を管理しているか」の台帳が消える)。
  #
  # R2 は S3 互換なので `s3` バックエンドをそのまま使う。ただし本物の AWS 前提の
  # 検証がいくつも走るので、下の skip_* で全部黙らせる必要がある。これを外すと
  # 「リージョンが不正」「STS に到達できない」等で init が通らない。
  backend "s3" {
    bucket = "tofu-state"
    key    = "dotfiles/cloudflare.tfstate"

    # R2 にリージョンの概念は無いが、S3 バックエンドは必須項目として要求する。
    # `auto` は R2 側が受け入れる特別扱いの値。
    region = "auto"

    endpoints = {
      # アカウント ID 固有のエンドポイント。gigun-dev のもの。
      s3 = "https://4b00d8d779cdc4e8fbc1840248d21722.r2.cloudflarestorage.com"
    }

    # --- ここから下はすべて「AWS ではないので検証を飛ばす」ためのフラグ ---
    skip_credentials_validation = true # STS の GetCallerIdentity を叩かない
    skip_metadata_api_check     = true # EC2 のインスタンスメタデータを探しに行かない
    skip_region_validation      = true # `auto` は AWS のリージョン名ではない
    skip_requesting_account_id  = true # AWS アカウント ID を引きに行かない
    skip_s3_checksum            = true # R2 が未対応のチェックサムヘッダを送らせない
    use_path_style              = true # バケット名をホスト名ではなくパスに置く

    # state のロック。以前は DynamoDB テーブルが必要だったが、OpenTofu 1.10 以降は
    # S3 の条件付き書き込み (If-None-Match) だけでロックできる。R2 も条件付き書き込みに
    # 対応しているのでこれで足りる。複数マシンから触る前提なので有効にしておく。
    use_lockfile = true
  }
}

# 認証情報は `nix run .#tofu` のラッパが secrets/tofu-env.age を復号して環境変数に
# 流し込む (CLOUDFLARE_API_TOKEN / AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)。
# ここに書かないのはもちろん、シェルの rc ファイルにも置かないための仕組み。
# 直接 `tofu` を叩くと必ず認証エラーになる — それは意図した挙動。
provider "cloudflare" {}
