{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.host-heartbeat;
  script = ../../../../scripts/host-heartbeat.py;
in
{
  imports = [ ../../host-heartbeat-options.nix ];
  config = lib.mkIf cfg.enable {
    age.secrets.host-heartbeat-vm = {
      file = ../../../../secrets/host-heartbeat-vm.age;
      mode = "0400";
      owner = "root";
    };
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.tokenFile && !(lib.hasPrefix "/nix/store/" cfg.tokenFile);
        message = "host-heartbeat tokenFile must be an absolute runtime secret path.";
      }
    ];
    systemd.services.host-heartbeat = {
      description = "Independent VM heartbeat (hub owns incident decisions)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        # A system service reports VM boot without depending on a user login.
        ExecStart = lib.escapeShellArgs [
          "${pkgs.python3}/bin/python3"
          "${script}"
          "--source"
          cfg.source
          "--endpoint"
          cfg.endpoint
          "--token-file"
          cfg.tokenFile
          "--snapshot"
          "/var/lib/host-heartbeat/latest.json"
        ];
        StateDirectory = "host-heartbeat";
        StateDirectoryMode = "0700";
        UMask = "0077";
        TimeoutStartSec = 45;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };
    systemd.timers.host-heartbeat = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15s";
        # Liveness reports use observation time, not H1b fixed-grid job slots.
        OnUnitActiveSec = "60s";
        AccuracySec = "1s";
      };
    };
  };
}
