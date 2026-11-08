{ pkgs, inputs }:
let
  inherit (pkgs) lib;
  config = inputs.self.nixosConfigurations.mini-vm.config;
  tokenFile = config.services.host-heartbeat.tokenFile;
  runtimeSecretFiles = config.dotfiles.runtimeSecretFiles;
  consumerSources = map builtins.readFile [
    ../modules/nixos/services/beszel.nix
    ../modules/nixos/services/langfuse.nix
    ../modules/nixos/services/uptime-kuma.nix
    ../modules/nixos/services/codex-mcp-login.nix
  ];
  backendSpecificTokens = [
    "config.age"
    "age.secrets"
    "/run/agenix"
  ];
in
assert config.sops.age.keyFile == "/var/lib/sops-nix/key.txt";
assert config.sops.age.generateKey;
assert config.sops.age.sshKeyPaths == [ ];
assert config.sops.gnupg.sshKeyPaths == [ ];
assert
  builtins.attrNames runtimeSecretFiles == [
    "barkEnv"
    "beszelEnv"
    "langfuseEnv"
    "uptimeKumaEnv"
  ];
assert lib.all (path: lib.hasPrefix "/" path && !(lib.hasPrefix "/nix/store/" path)) (
  lib.attrValues runtimeSecretFiles
);
assert lib.all (
  source: lib.all (token: !(lib.hasInfix token source)) backendSpecificTokens
) consumerSources;
assert runtimeSecretFiles.barkEnv == config.age.secrets.bark-env.path;
assert runtimeSecretFiles.beszelEnv == config.age.secrets.beszel-env.path;
assert runtimeSecretFiles.langfuseEnv == config.age.secrets.langfuse-env.path;
assert runtimeSecretFiles.uptimeKumaEnv == config.age.secrets.uptime-kuma-env.path;
assert config.systemd.services.beszel.serviceConfig.EnvironmentFile == runtimeSecretFiles.beszelEnv;
assert
  config.systemd.services.beszel-agent-bootstrap.serviceConfig.EnvironmentFile
  == runtimeSecretFiles.beszelEnv;
assert
  config.systemd.services.uptime-kuma-bootstrap.serviceConfig.EnvironmentFile
  == runtimeSecretFiles.uptimeKumaEnv;
assert
  config.systemd.services.codex-mcp-login-remind.serviceConfig.EnvironmentFile
  == "-${runtimeSecretFiles.barkEnv}";
assert config.systemd.services.bark-notify-smoke.wantedBy == [ ];
assert config.systemd.services.bark-notify-smoke.serviceConfig.Type == "oneshot";
assert
  config.systemd.services.bark-notify-smoke.serviceConfig.EnvironmentFile
  == runtimeSecretFiles.barkEnv;
assert tokenFile == config.age.secrets.host-heartbeat-vm.path;
assert lib.hasPrefix "/run/agenix/" tokenFile;
assert !(lib.hasPrefix "/nix/store/" tokenFile);
assert config.age.secrets.host-heartbeat-vm.mode == "0400";
assert config.age.secrets.host-heartbeat-vm.owner == "root";
assert config.age.secrets.beszel-env.owner == "beszel";
assert config.age.secrets.beszel-env.group == "beszel";
assert config.age.secrets.beszel-env.mode == "0400";
assert config.age.secrets.langfuse-env.owner == "gigun";
assert config.age.secrets.langfuse-env.group == "users";
assert config.age.secrets.langfuse-env.mode == "0400";
assert config.age.secrets.uptime-kuma-env.owner == "root";
assert config.age.secrets.uptime-kuma-env.group == "root";
assert config.age.secrets.uptime-kuma-env.mode == "0400";
pkgs.runCommand "sops-migration-config" { } ''
  touch "$out"
''
