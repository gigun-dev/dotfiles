# Separate pin: do not advance the host's shared lock or other packages.
let
  pkgs = import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/674a2028661e550a97400c1cc992b9cca9a668a1.tar.gz";
    sha256 = "sha256-T2+XBfNbf9pecLUWS4+RtuVNZ3W8K5taG5QdV71mWlk=";
  }) { system = "x86_64-linux"; };
in
(import ./linux.nix { inherit pkgs; }) // { inherit (pkgs) tailscale; }
