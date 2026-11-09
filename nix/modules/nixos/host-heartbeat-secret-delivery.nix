{
  config,
  lib,
  pkgs,
  ...
}:
let
  runtimeSecretPath = lib.types.addCheck lib.types.str (
    path: lib.hasPrefix "/" path && !(lib.hasPrefix "/nix/store/" path)
  );
  cfg = config.dotfiles.hostHeartbeatSecretDelivery;
  heartbeatScript = ../../../scripts/host-heartbeat.py;
  preflightService = generation: {
    description = "Value-free host heartbeat ${generation} token preflight";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.escapeShellArgs [
        "${pkgs.python3}/bin/python3"
        "${heartbeatScript}"
        "--check-token-file"
        cfg.paths.${generation}
      ];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };
in
{
  options.dotfiles.hostHeartbeatSecretDelivery = {
    selector = lib.mkOption {
      type = lib.types.enum [
        "agenix-rollback"
        "sops-current"
        "sops-next"
      ];
      default = "agenix-rollback";
      description = ''
        Fixed heartbeat credential generation selected by the Nix
        configuration. Selection never follows a mutable alias and is never
        promoted automatically after a preflight or receipt.
      '';
    };
    paths = lib.mkOption {
      type = lib.types.submodule {
        options = {
          agenix-rollback = lib.mkOption { type = runtimeSecretPath; };
          sops-current = lib.mkOption {
            type = runtimeSecretPath;
            default = "/run/secrets/host-heartbeat-vm-current";
          };
          sops-next = lib.mkOption {
            type = runtimeSecretPath;
            default = "/run/secrets/host-heartbeat-vm-next";
          };
        };
      };
      description = "Immutable runtime paths for each staged heartbeat credential.";
    };
    selectedPath = lib.mkOption {
      type = runtimeSecretPath;
      readOnly = true;
      default = cfg.paths.${cfg.selector};
      description = "Runtime token path selected from the fixed generation.";
    };
  };

  config = {
    services.host-heartbeat.tokenFile = cfg.selectedPath;
    # These units only validate explicitly staged candidates. They have no
    # wantedBy and cannot change the selector or promote a credential.
    systemd.services.host-heartbeat-sops-current-preflight = preflightService "sops-current";
    systemd.services.host-heartbeat-sops-next-preflight = preflightService "sops-next";
  };
}
