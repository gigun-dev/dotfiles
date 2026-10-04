{ pkgs, nixos }:
let
  inherit (pkgs) lib;
  valid = {
    enable = true;
    endpoint = "https://hub.example/heartbeat";
    tokenFiles = {
      mini-vm-autoswitch = "/run/agenix/job-autoswitch";
      mini-vm-lock-fast = "/run/agenix/job-lock-fast";
      mini-vm-lock-slow = "/run/agenix/job-lock-slow";
    };
  };
  moduleDefaults =
    (lib.evalModules {
      modules = [
        ../modules/nixos/services/dotfiles-job-heartbeat.nix
        {
          options.assertions = lib.mkOption {
            type = lib.types.listOf lib.types.raw;
            default = [ ];
          };
        }
      ];
    }).config;
  evaluate =
    settings:
    (nixos.extendModules {
      modules = [
        {
          services.dotfiles-job-heartbeat = {
            enable = lib.mkForce (settings.enable or false);
            endpoint = lib.mkForce (settings.endpoint or null);
            tokenFiles = lib.mkForce (settings.tokenFiles or { });
          };
        }
      ];
    }).config;
  disabled = evaluate { };
  configuredOff = evaluate (valid // { enable = false; });
  enabled = evaluate valid;
  accepts =
    settings:
    let
      config = evaluate settings;
      result = builtins.tryEval (lib.all (item: item.assertion) config.assertions);
    in
    result.success && result.value;
  invalid = [
    { enable = true; }
    (valid // { endpoint = null; })
    (valid // { tokenFiles = builtins.removeAttrs valid.tokenFiles [ "mini-vm-lock-slow" ]; })
    (
      valid
      // {
        tokenFiles = valid.tokenFiles // {
          other = "/run/agenix/other";
        };
      }
    )
    (
      valid
      // {
        tokenFiles = valid.tokenFiles // {
          mini-vm-lock-slow = valid.tokenFiles.mini-vm-lock-fast;
        };
      }
    )
  ]
  ++ map (endpoint: valid // { inherit endpoint; }) [
    "http://hub.example/heartbeat"
    "https://hub..example/heartbeat"
    "https://-hub.example/heartbeat"
    "https://user:secret@hub.example/heartbeat"
    "https://hub.example/heartbeat?token=value"
    "https://hub.example/heartbeat#fragment"
    "https://hub.example/uptime/heartbeat"
    "https://hub.example/heartbeat\nInjected=value"
    "https://hub.example/heartbeat\r"
    "https://hub.example/heart beat"
    "https://hub.example/%s"
  ]
  ++
    map
      (
        path:
        valid
        // {
          tokenFiles = valid.tokenFiles // {
            mini-vm-autoswitch = path;
          };
        }
      )
      [
        "relative/token"
        "/nix/store/token"
        "/nix/store"
        "/run/agenix/../token"
        "/run/agenix/./token"
        "/run/agenix/token\nInjected=value"
        "/run/agenix/token:other"
        "/run/agenix/%i"
        "/run/agenix/token with spaces"
        ""
        ./job-heartbeat-config.nix
      ];
  unchangedUnit =
    name:
    let
      before = disabled.systemd.services.${name};
      after = enabled.systemd.services.${name};
    in
    before.unitConfig == after.unitConfig
    && before.restartIfChanged == after.restartIfChanged
    && before.serviceConfig.User == after.serviceConfig.User
    && before.serviceConfig.TimeoutStartSec == after.serviceConfig.TimeoutStartSec
    && !(after.serviceConfig ? LoadCredential)
    && !(after.serviceConfig ? SetCredential);
in
assert !moduleDefaults.services.dotfiles-job-heartbeat.enable;
assert moduleDefaults.services.dotfiles-job-heartbeat.endpoint == null;
assert moduleDefaults.services.dotfiles-job-heartbeat.tokenFiles == { };
assert lib.all (item: item.assertion) moduleDefaults.assertions;
assert !disabled.services.dotfiles-job-heartbeat.enable;
assert disabled.services.dotfiles-job-heartbeat.endpoint == null;
assert disabled.services.dotfiles-job-heartbeat.tokenFiles == { };
assert !configuredOff.services.dotfiles-job-heartbeat.enable;
assert accepts valid;
assert lib.all (settings: !(accepts settings)) invalid;
assert lib.all unchangedUnit [
  "dotfiles-autoswitch"
  "dotfiles-lock-propose@"
];
assert !(enabled.systemd.services ? "dotfiles-lock-propose@fast");
assert !(enabled.systemd.services ? "dotfiles-lock-propose@slow");
assert lib.all
  (name: disabled.systemd.timers.${name}.timerConfig == enabled.systemd.timers.${name}.timerConfig)
  [
    "dotfiles-autoswitch"
    "dotfiles-lock-propose-fast"
    "dotfiles-lock-propose-slow"
  ];
pkgs.runCommand "job-heartbeat-config-tests" { } ''
  touch "$out"
''
