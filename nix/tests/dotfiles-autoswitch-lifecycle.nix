{ pkgs, service }:
pkgs.testers.runNixOSTest {
  name = "dotfiles-autoswitch-self-update";
  nodes.machine =
    { config, lib, ... }:
    let
      version = config.autoswitchFixtureVersion;
      updater = pkgs.writeShellScript "autoswitch-${version}" ''
        set -eu
        echo "$INVOCATION_ID $$ ${version}" > /tmp/coordinator
        if [ "${version}" = old ]; then
          /run/current-system/specialisation/updated/bin/switch-to-configuration test
        fi
        exec /run/current-system/etc/autoswitch-post-apply
      '';
      helper = pkgs.writeShellScript "autoswitch-post-${version}" ''
        echo "$INVOCATION_ID $$ ${version}" > /tmp/post-apply
      '';
    in
    {
      options.autoswitchFixtureVersion = lib.mkOption {
        type = lib.types.str;
        default = "old";
      };
      config = {
        system.stateVersion = "26.05";
        environment.etc.autoswitch-post-apply.source = helper;
        systemd.services.dotfiles-autoswitch = {
          inherit (service) restartIfChanged;
          unitConfig.X-StopOnRemoval = service.unitConfig.X-StopOnRemoval;
          serviceConfig = {
            Type = service.serviceConfig.Type;
            ExecStart = updater;
          };
        };
        systemd.timers.dotfiles-autoswitch = {
          wantedBy = [ "timers.target" ];
          timerConfig.OnCalendar = "*-*-* 23:59:59";
        };
        specialisation.updated.configuration.autoswitchFixtureVersion = lib.mkForce "new";
      };
    };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    before = machine.succeed("systemctl show dotfiles-autoswitch -p ExecStart --value")
    machine.succeed("systemctl start dotfiles-autoswitch")
    after = machine.succeed("systemctl show dotfiles-autoswitch -p ExecStart --value")
    assert before != after, "Regression must change the installed updater ExecStart"
    invocation, pid, version = machine.succeed("cat /tmp/coordinator").split()
    new_invocation, new_pid, new_version = machine.succeed("cat /tmp/post-apply").split()
    assert version == "old" and new_version == "new"
    assert invocation == new_invocation and pid == new_pid
    assert machine.succeed("systemctl show dotfiles-autoswitch -p Result --value").strip() == "success"
    assert machine.succeed("systemctl show dotfiles-autoswitch -p ActiveState --value").strip() == "inactive"
    assert machine.succeed("systemctl show dotfiles-autoswitch.timer -p SubState --value").strip() == "waiting"
    journal = machine.succeed("journalctl -u dotfiles-autoswitch --no-pager")
    assert "status=15/TERM" not in journal
    assert "already loaded or has a fragment file" not in journal
  '';
}
