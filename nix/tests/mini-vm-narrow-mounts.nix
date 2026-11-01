{ pkgs, inputs }:
let
  base = inputs.self.nixosConfigurations.mini-vm;
  recovery = base.extendModules {
    modules = [ ../../infra/lima/mini-vm-mount-maintenance.draft.nix ];
  };
  timerNames = [
    "dotfiles-autoswitch"
    "dotfiles-lock-propose-fast"
    "dotfiles-lock-propose-slow"
  ];
  draft = base.extendModules {
    modules = [
      ../../infra/lima/mini-vm-narrow-mounts.draft.nix
      ../../infra/lima/mini-vm-mount-maintenance.draft.nix
    ];
  };
in
# The draft must remain inert in the actual production configuration.
assert inputs.self.nixosConfigurations.mini-vm.config.fileSystems ? "/Users/gigun";
assert !(draft.config.fileSystems ? "/Users/gigun");
assert draft.config.fileSystems == builtins.removeAttrs base.config.fileSystems [ "/Users/gigun" ];
assert recovery.config.fileSystems == base.config.fileSystems;
assert builtins.all (name: base.config.systemd.timers.${name}.enable) timerNames;
assert builtins.all (name: !draft.config.systemd.units."${name}.timer".enable) timerNames;
assert builtins.all (name: !recovery.config.systemd.units."${name}.timer".enable) timerNames;
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
