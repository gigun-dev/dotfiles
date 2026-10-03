terraform {
  required_version = ">= 1.10"
  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.29.2"
    }
  }
  backend "s3" {
    bucket = "tofu-state"
    key    = "dotfiles/tailscale.tfstate"

    region = "auto"

    endpoints = {
      s3 = "https://4b00d8d779cdc4e8fbc1840248d21722.r2.cloudflarestorage.com"
    }

    skip_credentials_validation = true # STS の GetCallerIdentity を叩かない
    skip_metadata_api_check     = true # EC2 のインスタンスメタデータを探しに行かない
    skip_region_validation      = true # `auto` は AWS のリージョン名ではない
    skip_requesting_account_id  = true # AWS アカウント ID を引きに行かない
    skip_s3_checksum            = true # R2 が未対応のチェックサムヘッダを送らせない
    use_path_style              = true # バケット名をホスト名ではなくパスに置く

    use_lockfile = true
  }
}

variable "passphrase" {
  description = "state 暗号化のパスフレーズ。tofu ラッパが TF_VAR_passphrase で渡す"
  type        = string
  sensitive   = true
}

terraform {
  encryption {
    key_provider "pbkdf2" "main" {
      passphrase = var.passphrase
    }

    method "aes_gcm" "main" {
      keys = key_provider.pbkdf2.main
    }

    state {
      method   = method.aes_gcm.main
      enforced = true
    }

    plan {
      method   = method.aes_gcm.main
      enforced = true
    }
  }
}
