{
  description = "Isolated patched runtimes; no host activation";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/674a2028661e550a97400c1cc992b9cca9a668a1";
  outputs = { self, nixpkgs }: {
    packages = {
      aarch64-darwin = import ./darwin.nix {
        pkgs = nixpkgs.legacyPackages.aarch64-darwin;
      };
      # Intel uses its frozen compatible toolchain, not current nixpkgs.
      x86_64-darwin = import ./intel.nix { };
      x86_64-linux = import ./linux.nix { pkgs = nixpkgs.legacyPackages.x86_64-linux; };
    };
  };
}
