{ lib, ... }:
let
  runtimeSecretPath = lib.types.addCheck lib.types.str (
    path: lib.hasPrefix "/" path && !(lib.hasPrefix "/nix/store/" path)
  );
in
{
  options.dotfiles.runtimeSecretFiles = lib.mkOption {
    type = lib.types.attrsOf runtimeSecretPath;
    default = { };
    description = ''
      Runtime paths supplied by the host's secret delivery backend. Consumers
      depend on these paths instead of a specific backend such as agenix or
      sops-nix. Every path must be absolute and outside the Nix store.
    '';
  };
}
