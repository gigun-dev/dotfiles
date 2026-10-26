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
      x86_64-linux = let pkgs = nixpkgs.legacyPackages.x86_64-linux; in {
        # The auto-patched upstream ELF segfaults on mini-vm. Build from source
        # through the standard nixpkgs derivation with fixed bundled Brotli.
        node = import ./linux-prebuilt.nix { inherit pkgs; };
        bun = pkgs.stdenvNoCC.mkDerivation {
          pname = "bun-security";
          version = "1.4.4";
          src = pkgs.fetchurl {
            url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.4/bun-linux-x64-baseline.zip";
            sha256 = "e0446eb55995772eb9894bebae9a6be368d985a8b9271ee124486f9946eedd76";
          };
          nativeBuildInputs = [ pkgs.unzip pkgs.autoPatchelfHook ];
          buildInputs = [ pkgs.stdenv.cc.cc.lib ];
          dontBuild = true;
          installPhase = "mkdir -p $out/bin; cp bun $out/bin/bun; ln -s bun $out/bin/bunx";
        };
      };
    };
  };
}
