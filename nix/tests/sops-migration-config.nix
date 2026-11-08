{ pkgs, inputs }:
let
  inherit (pkgs) lib;
  config = inputs.self.nixosConfigurations.mini-vm.config;
  tokenFile = config.services.host-heartbeat.tokenFile;
in
assert config.sops.age.keyFile == "/var/lib/sops-nix/key.txt";
assert config.sops.age.generateKey;
assert config.sops.age.sshKeyPaths == [ ];
assert config.sops.gnupg.sshKeyPaths == [ ];
assert tokenFile == config.age.secrets.host-heartbeat-vm.path;
assert lib.hasPrefix "/run/agenix/" tokenFile;
assert !(lib.hasPrefix "/nix/store/" tokenFile);
assert config.age.secrets.host-heartbeat-vm.mode == "0400";
assert config.age.secrets.host-heartbeat-vm.owner == "root";
pkgs.runCommand "sops-migration-config" { } ''
  touch "$out"
''
