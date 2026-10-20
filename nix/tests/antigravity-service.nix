{ pkgs, nixos }:
let
  inherit (pkgs) lib;
  service = nixos.config.systemd.services.antigravity-remote-control;
  environment = service.environment;
  required = with pkgs; [
    bash
    git
    ghq
    gh
    openssh
  ];
in
assert lib.all (package: lib.elem "${package}/bin" (lib.splitString ":" environment.PATH)) required;
assert environment.HOME == "/home/gigun";
assert environment.SSL_CERT_FILE == "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
assert environment.AGY_CLI_DISABLE_AUTO_UPDATE == "1";
assert service.serviceConfig.User == "gigun";
assert service.serviceConfig.WorkingDirectory == environment.HOME;
assert service.restartIfChanged;
pkgs.runCommand "antigravity-service-tests" { } ''
  # Start with only the evaluated service environment, without a login profile or
  # the builder's PATH. No daemon, credentials, or network access is needed.
  ${pkgs.coreutils}/bin/env -i \
    ${lib.escapeShellArgs (lib.mapAttrsToList (name: value: "${name}=${value}") environment)} \
    bash --noprofile --norc -eu -c '
      for command in bash git ghq gh ssh; do
        command -v "$command"
      done
      bash --version
      git --version
      ghq --version
      gh --version
      ssh -V
      test "$HOME" = /home/gigun
      test "$AGY_CLI_DISABLE_AUTO_UPDATE" = 1
      test -r "$SSL_CERT_FILE"
    '
  touch "$out"
''
