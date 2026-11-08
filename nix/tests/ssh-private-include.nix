{
  pkgs,
  system,
  inputs,
}:
let
  inherit (pkgs) lib;
  privateInclude = "~/.ssh/config.d/*";
  includes =
    if pkgs.stdenv.hostPlatform.isDarwin then
      inputs.self.darwinConfigurations."gigun-${system}".config.home-manager.users.gigun.programs.ssh.includes
    else
      inputs.self.homeConfigurations.gigun-x86_64-linux.config.programs.ssh.includes;
in
assert builtins.head includes == privateInclude;
assert lib.elem privateInclude includes;
assert pkgs.stdenv.hostPlatform.isDarwin || includes == [ privateInclude ];
pkgs.runCommand "ssh-private-include" { } ''
  touch "$out"
''
