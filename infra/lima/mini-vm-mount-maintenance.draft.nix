{ lib, ... }:
{
  # Use in both candidate and recovery generations; never import by default.
  systemd.timers.dotfiles-autoswitch.enable = lib.mkForce false;
  systemd.timers.dotfiles-lock-propose-fast.enable = lib.mkForce false;
  systemd.timers.dotfiles-lock-propose-slow.enable = lib.mkForce false;
}
