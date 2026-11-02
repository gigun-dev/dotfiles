{ pkgs, inputs }:
let
  base = inputs.self.nixosConfigurations.mini-vm;
  # Synthetic version; this check never installs or starts the bridge.
  bridgeVersion = "0.0.0";
  maintenance = import ../../infra/lima/mini-vm-mount-maintenance.draft.nix {
    inherit bridgeVersion;
  };
  recovery = base.extendModules {
    modules = [
      maintenance
      ({ ... }: {
        fileSystems."/Users/gigun" = {
          device = "lima-87931a4782a6b63c";
          fsType = "virtiofs";
          options = [
            "ro"
            "nofail"
          ];
        };
      })
    ];
  };
  timerNames = [
    "dotfiles-autoswitch"
    "dotfiles-lock-propose-fast"
    "dotfiles-lock-propose-slow"
    "codex-openai-bridge-refresh"
    "langfuse-update-propose"
  ];
  draft = base.extendModules {
    modules = [
      ../../infra/lima/mini-vm-narrow-mounts.draft.nix
      maintenance
    ];
  };
in
# The accepted production policy excludes host home; recovery explicitly restores it.
assert !(base.config.fileSystems ? "/Users/gigun");
assert !(draft.config.fileSystems ? "/Users/gigun");
assert draft.config.fileSystems == builtins.removeAttrs base.config.fileSystems [ "/Users/gigun" ];
assert recovery.config.fileSystems ? "/Users/gigun";
assert
  builtins.removeAttrs recovery.config.fileSystems [ "/Users/gigun" ] == base.config.fileSystems;
assert !(inputs.nixpkgs.lib.hasInfix "/Users/gigun" base.config.environment.etc.fstab.text);
assert builtins.all (name: base.config.systemd.timers.${name}.enable) timerNames;
assert builtins.all (name: !draft.config.systemd.units."${name}.timer".enable) timerNames;
assert builtins.all (name: !recovery.config.systemd.units."${name}.timer".enable) timerNames;
assert base.config.systemd.timers.codex-openai-bridge-refresh.timerConfig.Persistent;
assert base.config.systemd.timers.langfuse-update-propose.timerConfig.Persistent;
assert inputs.nixpkgs.lib.hasInfix "openai-api-server-via-codex@latest"
  base.config.systemd.services.codex-openai-bridge.serviceConfig.ExecStart;
assert builtins.all
  (
    candidate:
    candidate.config.systemd.services.codex-openai-bridge.serviceConfig.ExecStart
    == inputs.nixpkgs.lib.replaceStrings
      [ "openai-api-server-via-codex@latest" ]
      [ "openai-api-server-via-codex@${bridgeVersion}" ]
      base.config.systemd.services.codex-openai-bridge.serviceConfig.ExecStart
  )
  [
    draft
    recovery
  ];
assert builtins.all
  (
    bridgeVersion:
    !(builtins.tryEval (
      import ../../infra/lima/mini-vm-mount-maintenance.draft.nix {
        inherit bridgeVersion;
      }
    )).success
  )
  [
    "latest"
    ""
    "1.2.3 --config other"
    null
  ];
assert !(inputs.nixpkgs.lib.hasInfix "/Users/gigun" draft.config.environment.etc.fstab.text);
pkgs.runCommand "mini-vm-narrow-mounts-draft"
  {
    TMP_MOUNT_DEVICE = base.config.fileSystems."/tmp/lima".device;
    nativeBuildInputs = [
      pkgs.yq-go
      pkgs.python3
    ];
  }
  ''
    yq -o=json ${../../infra/lima/mini-vm-mounts.draft.yaml} > mounts.json
    python3 -I -S -B - <<'PY'
    import hashlib, json, os
    with open("mounts.json") as handle:
        plan = json.load(handle)
    assert set(plan) == {"mountType", "mounts"}
    assert plan["mountType"] == "virtiofs"
    assert plan["mounts"] == [{"location": "/tmp/lima", "mountPoint": "/tmp/lima", "writable": True}]
    tag = "lima-" + hashlib.sha256(b"/tmp/lima:/tmp/lima").hexdigest()[:16]
    assert tag == os.environ["TMP_MOUNT_DEVICE"]
    PY
    touch "$out"
  ''
