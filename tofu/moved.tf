# NetdataからBeszelへの監視基盤の置き換え。既存のDNS recordとAccess applicationを
# 更新して使い、削除・再作成による一時的な認証境界の消失を避ける。
moved {
  from = cloudflare_dns_record.netdata
  to   = cloudflare_dns_record.beszel
}

moved {
  from = cloudflare_zero_trust_access_application.netdata
  to   = cloudflare_zero_trust_access_application.beszel
}
