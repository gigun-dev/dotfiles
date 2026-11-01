{ bridgeVersion }:
assert
  builtins.isString bridgeVersion
  && builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+([.-][0-9A-Za-z.-]+)?" bridgeVersion != null;
{ lib, pkgs, ... }:
{
  # A recorded working version is required in both generations; never import by default.
  systemd.timers.dotfiles-autoswitch.enable = lib.mkForce false;
  systemd.timers.dotfiles-lock-propose-fast.enable = lib.mkForce false;
  systemd.timers.dotfiles-lock-propose-slow.enable = lib.mkForce false;
  systemd.timers.codex-openai-bridge-refresh.enable = lib.mkForce false;
  systemd.timers.langfuse-update-propose.enable = lib.mkForce false;

  # Disabling refresh alone does not stop @latest from changing on the required boot.
  systemd.services.codex-openai-bridge.serviceConfig.ExecStart = lib.mkForce (
    "${pkgs.uv}/bin/uvx openai-api-server-via-codex@${bridgeVersion} serve"
    + " --config /var/lib/codex-bridge/config.toml"
    + " --host 127.0.0.1 --port 18080"
    + " --auth-json /home/gigun/.codex/auth.json"
  );
}
