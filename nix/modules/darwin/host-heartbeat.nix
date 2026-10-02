{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.host-heartbeat;
in
{
  imports = [ ../host-heartbeat-options.nix ];
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.tokenFile && !(lib.hasPrefix "/nix/store/" cfg.tokenFile);
        message = "host-heartbeat tokenFile must be an absolute runtime secret path.";
      }
    ];
    system.activationScripts.postActivation.text = ''
      install -d -m 700 /var/lib/host-heartbeat
    '';
    # The Mac reports itself, even when Lima is down. No VM status is inferred here.
    launchd.daemons.host-heartbeat.serviceConfig = {
      Label = "dev.gigun.host-heartbeat";
      ProgramArguments = [
        "${pkgs.python3}/bin/python3"
        "${../../../scripts/host-heartbeat.py}"
        "--source"
        cfg.source
        "--endpoint"
        cfg.endpoint
        "--token-file"
        cfg.tokenFile
        "--period-ms"
        (toString cfg.periodMs)
        "--anchor-ms"
        (toString cfg.anchorMs)
        "--snapshot"
        "/var/lib/host-heartbeat/latest.json"
      ];
      RunAtLoad = true;
      StartInterval = 30;
      ProcessType = "Background";
    };
  };
}
