# Opt-in example, not imported by mini-vm.nix. Review and test before importing.
{ config, lib, ... }:
let
  cfg = config.dotfiles.reviewedCiRunner;
in
{
  options.dotfiles.reviewedCiRunner = {
    enable = lib.mkEnableOption "reviewed-code CI runner";
    registrationTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Absolute path to a short-lived registration token outside the Nix store.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.registrationTokenFile != null && lib.hasPrefix "/run/" cfg.registrationTokenFile;
        message = "A short-lived registration token file under /run is required.";
      }
    ];
    users.groups.dotfiles-ci = { };
    users.users.dotfiles-ci = {
      isSystemUser = true;
      group = "dotfiles-ci";
      extraGroups = [ ];
    };
    services.github-runners.dotfiles-ci = {
      enable = true;
      url = "https://github.com/gigun-dev/dotfiles";
      tokenFile = cfg.registrationTokenFile;
      tokenType = "registration";
      user = "dotfiles-ci";
      group = "dotfiles-ci";
      ephemeral = true;
      extraLabels = [ "dotfiles-reviewed" ];
      serviceOverrides = {
        Restart = lib.mkForce "no";
        RestartForceExitStatus = lib.mkForce [ ];
        MemoryMax = "4G";
        CPUQuota = "200%";
        InaccessiblePaths = lib.mkAfter [
          "-/run/docker.sock"
          "-/var/run/docker.sock"
          "-/run/agenix"
          "-/run/agenix.d"
          "-/run/secrets"
          "-/run/secrets.d"
          "-/run/tailscale"
        ];
      };
    };
    # No boot-time runner; an operator explicitly starts each registration.
    systemd.services.github-runner-dotfiles-ci.wantedBy = lib.mkForce [ ];
  };
}
