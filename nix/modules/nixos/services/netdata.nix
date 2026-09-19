{ ... }:
{
  # cloudflared is the only public ingress. Loopback binding keeps the native
  # Netdata port off both the LAN and tailnet if Access is misconfigured.
  services.netdata = {
    enable = true;
    enableAnalyticsReporting = false;
    config.web."bind to" = "127.0.0.1:19999";
  };
}
