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
      description = "Existing hub HTTPS /heartbeat endpoint, after production acceptance.";
    };
    tokenFile = lib.mkOption {
      type = lib.types.str;
      description = "Private runtime token file (agenix path on NixOS); never a store path.";
    };
    periodMs = lib.mkOption {
      type = lib.types.ints.between 60000 604800000;
      default = 60000;
      description = "UTC fixed-grid period; must match hub registration.";
    };
    anchorMs = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = "UTC epoch millisecond grid anchor; must match hub registration.";
    };
  };
}
