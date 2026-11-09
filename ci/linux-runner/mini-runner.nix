# Opt-in module. mini-vm imports it disabled; enabling still requires an explicit
# short-lived token path under /run and a separately reviewed system activation.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.reviewedCiRunner;
  macosPortableCommandBinds = [
    "${pkgs.coreutils}/bin/mv:/bin/mv"
    "${pkgs.coreutils}/bin/dirname:/usr/bin/dirname"
    "${pkgs.gnutar}/bin/tar:/usr/bin/tar"
  ];
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
      # GitHub-hosted Ubuntu provides Python implicitly.  The fzf recipe job
      # invokes unittest directly, so declare the reviewed runner toolchain
      # instead of inheriting whatever happens to be installed on mini-vm.
      extraPackages = [ pkgs.python3 ];
      serviceOverrides = {
        Restart = lib.mkForce "no";
        RestartForceExitStatus = lib.mkForce [ ];
        MemoryMax = "4G";
        CPUQuota = "200%";
        # The portable mini-macos fixtures exercise the absolute command paths
        # used by the real macOS target.  Expose only those commands inside the
        # runner's mount namespace instead of adding an FHS layer to mini-vm.
        BindReadOnlyPaths = macosPortableCommandBinds;
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
