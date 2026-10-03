# Cloudflareとは別state。ネットワーク変更を通常のCloudflare applyに混ぜない。
provider "tailscale" {
  scopes = ["policy_file"]
}

variable "tailnet_owner" {
  type      = string
  sensitive = true
  nullable  = false
  validation {
    condition     = length(trimspace(var.tailnet_owner)) > 0
    error_message = "所有者IDは既存のage環境ファイルから指定する。"
  }
}

variable "ota_hosts" {
  type      = map(string)
  sensitive = true
  nullable  = false
}

resource "tailscale_acl" "policy" {
  # 既存ポリシーをimportするまで上書きできないprovider既定を維持する。
  # destroyでも既定の全許可ポリシーへ戻さない。
  acl = templatefile("${path.module}/policy.hujson.tftpl", {
    owner     = jsonencode(var.tailnet_owner)
    ota_hosts = jsonencode(var.ota_hosts)
  })
  lifecycle {
    prevent_destroy = true
  }
}
