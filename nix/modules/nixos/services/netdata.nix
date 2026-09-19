{ lib, pkgs, ... }:
{
  # Only the bundled dashboard carries NCUL. Keep the exception scoped to
  # Netdata instead of enabling every unfree package for the VM.
  nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "netdata";

  # cloudflared is the only public ingress. Loopback binding keeps the native
  # Netdata port off both the LAN and tailnet if Access is misconfigured.
  services.netdata = {
    enable = true;
    # nixpkgs disables the Netdata dashboard by default because its UI has a
    # separate NCUL license. Without this flag the API works, but `/` returns
    # "File does not exist" because share/netdata/web has no index.html.
    package = pkgs.netdata.override { withCloudUi = true; };
    enableAnalyticsReporting = false;
    config.web."bind to" = "127.0.0.1:19999";
  };
}
