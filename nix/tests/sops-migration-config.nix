{ pkgs, inputs }:
let
  inherit (pkgs) lib;
  config = inputs.self.nixosConfigurations.mini-vm.config;
  hostIdentityActivation = config.system.activationScripts.dotfiles-sops-host-identity;
  tokenFile = config.services.host-heartbeat.tokenFile;
  heartbeatDelivery = config.dotfiles.hostHeartbeatSecretDelivery;
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
assert lib.hasInfix config.sops.age.keyFile hostIdentityActivation;
assert lib.hasInfix "ensure-sops-host-identity" hostIdentityActivation;
assert !(lib.hasInfix "/etc/ssh/" hostIdentityActivation);
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
assert heartbeatDelivery.selector == "agenix-rollback";
assert heartbeatDelivery.selectedPath == heartbeatDelivery.paths.agenix-rollback;
assert heartbeatDelivery.paths.sops-current == "/run/secrets/host-heartbeat-vm-current";
assert heartbeatDelivery.paths.sops-next == "/run/secrets/host-heartbeat-vm-next";
assert config.systemd.services.host-heartbeat-sops-current-preflight.wantedBy == [ ];
assert config.systemd.services.host-heartbeat-sops-next-preflight.wantedBy == [ ];
assert lib.hasInfix heartbeatDelivery.paths.sops-current
  config.systemd.services.host-heartbeat-sops-current-preflight.serviceConfig.ExecStart;
assert lib.hasInfix heartbeatDelivery.paths.sops-next
  config.systemd.services.host-heartbeat-sops-next-preflight.serviceConfig.ExecStart;
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
