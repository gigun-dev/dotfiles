{ lib, ... }:
{
  options.services.host-heartbeat = {
    enable = lib.mkEnableOption "independent host heartbeat to hub";
    localVmChecks = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Observe VM edge readiness and local service health; functional stays unknown.";
    };
    tunnelUnit = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Declared cloudflared unit associated with the fixed loopback readiness endpoint.";
    };
    source = lib.mkOption {
      type = lib.types.str;
      description = "hub authenticated source; use distinct Mac and VM credentials.";
    };
    endpoint = lib.mkOption {
      type = lib.types.str;
      description = "Existing hub HTTPS /uptime/heartbeat endpoint, after production acceptance.";
    };
    tokenFile = lib.mkOption {
      type = lib.types.str;
      description = "Private runtime token file (agenix path on NixOS); never a store path.";
    };
  };
}
