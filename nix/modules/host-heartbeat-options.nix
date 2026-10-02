{ lib, ... }:
{
  options.services.host-heartbeat = {
    enable = lib.mkEnableOption "independent host heartbeat to hub";
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
