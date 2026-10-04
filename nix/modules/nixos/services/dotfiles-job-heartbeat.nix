{ config, lib, ... }:
let
  cfg = config.services.dotfiles-job-heartbeat;
  sources = [
    "mini-vm-autoswitch"
    "mini-vm-lock-fast"
    "mini-vm-lock-slow"
  ];
  validTokenFile =
    path:
    builtins.match "(/[A-Za-z0-9._-]+)+" path != null
    && path != "/nix/store"
    && !(lib.hasPrefix "/nix/store/" path)
    && !(lib.elem "." (lib.splitString "/" path))
    && !(lib.elem ".." (lib.splitString "/" path));
in
{
  options.services.dotfiles-job-heartbeat = {
    enable = lib.mkEnableOption "success receipts for the three mini-vm update jobs";
    endpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Public HTTPS /heartbeat endpoint, configured only after production acceptance.";
    };
    tokenFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Distinct private runtime credential paths with regular-file leaves, keyed by mini-vm-autoswitch,
        mini-vm-lock-fast and mini-vm-lock-slow. Use strings, never Nix paths or secret values.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion =
          cfg.endpoint == null
          || builtins.match "https://[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?([.][A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*/heartbeat" cfg.endpoint != null;
        message = "dotfiles-job-heartbeat endpoint must be a public HTTPS host with the /heartbeat path only.";
      }
      {
        assertion = lib.all (source: lib.elem source sources) (builtins.attrNames cfg.tokenFiles);
        message = "dotfiles-job-heartbeat tokenFiles accepts only the three mini-vm job sources.";
      }
      {
        assertion = lib.all validTokenFile (builtins.attrValues cfg.tokenFiles);
        message = "dotfiles-job-heartbeat tokenFiles must be safe absolute runtime paths outside the Nix store.";
      }
      {
        assertion =
          builtins.length (lib.unique (builtins.attrValues cfg.tokenFiles))
          == builtins.length (builtins.attrNames cfg.tokenFiles);
        message = "dotfiles-job-heartbeat requires a distinct credential path for each source.";
      }
      {
        assertion =
          !cfg.enable
          || (cfg.endpoint != null && builtins.attrNames cfg.tokenFiles == sources);
        message = "Enabling dotfiles-job-heartbeat requires an endpoint and all three source credential paths.";
      }
    ];
  };
}
