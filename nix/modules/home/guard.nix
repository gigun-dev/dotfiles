{ lib, pkgs, ... }:
let
  # Copy contents into the generation: changing a checkout must not change Guard.
  npm = builtins.readFile ../../../npm/npmrc;
  bun = builtins.readFile ../../../bun/bunfig.toml;
  pip = builtins.readFile ../../../pip/pip.conf;
  uv = builtins.readFile ../../../uv/uv.toml;
in
{
  home.file = {
    ".npmrc".text = npm;
    ".bunfig.toml".text = bun;
  }
  // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
    # pip on macOS prefers this directory if it exists, even without XDG env.
    "Library/Application Support/pip/pip.conf".text = pip;
  };
  xdg.configFile = {
    "uv/uv.toml".text = uv;
    "pip/pip.conf".text = pip;
    # Bun uses XDG_CONFIG_HOME instead of HOME when it is set.
    ".bunfig.toml".text = bun;
  };
}
