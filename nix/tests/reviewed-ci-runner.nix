{ pkgs, inputs }:
let
  evaluate =
    enabled: token:
    (inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ../../ci/linux-runner/mini-runner.nix
        {
          system.stateVersion = "26.05";
          dotfiles.reviewedCiRunner = {
            enable = enabled;
            registrationTokenFile = token;
          };
        }
      ];
    }).config;
  disabled = evaluate false null;
  enabled = evaluate true "/run/keys/dotfiles-ci-test-token";
  service = enabled.systemd.services.github-runner-dotfiles-ci;
  settings = service.serviceConfig;
in
assert !(disabled.systemd.services ? github-runner-dotfiles-ci);
assert service.wantedBy == [ ];
assert settings.User == "dotfiles-ci" && settings.Group == "dotfiles-ci";
assert enabled.users.users.dotfiles-ci.extraGroups == [ ];
assert !(builtins.elem "dotfiles-ci" enabled.nix.settings.trusted-users);
assert settings.NoNewPrivileges && settings.ProtectHome && settings.ProtectSystem == "strict";
assert settings.Restart == "no" && settings.RestartForceExitStatus == [ ];
assert enabled.services.github-runners.dotfiles-ci.ephemeral;
assert
  settings.BindReadOnlyPaths == [
    "${pkgs.coreutils}/bin/mv:/bin/mv"
    "${pkgs.coreutils}/bin/dirname:/usr/bin/dirname"
    "${pkgs.gnutar}/bin/tar:/usr/bin/tar"
  ];
assert builtins.all (path: builtins.elem path settings.InaccessiblePaths) [
  "-/run/docker.sock"
  "-/run/agenix"
  "-/run/agenix.d"
  "-/run/secrets"
  "-/run/tailscale"
];
pkgs.runCommand "reviewed-ci-runner-config" { } ''
  touch "$out"
''
