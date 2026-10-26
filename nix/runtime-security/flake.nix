{
  description = "Isolated official patched runtimes; no host activation";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/674a2028661e550a97400c1cc992b9cca9a668a1";
  outputs = { self, nixpkgs }: {
    packages = nixpkgs.lib.genAttrs [ "aarch64-darwin" "x86_64-linux" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        linux = system == "x86_64-linux";
        platform = if linux then "linux-x64" else "darwin-arm64";
        bunPlatform = if linux then "linux-x64-baseline" else "darwin-aarch64";
        base = {
          nativeBuildInputs = [ pkgs.unzip ] ++ pkgs.lib.optionals linux [ pkgs.autoPatchelfHook ];
          buildInputs = pkgs.lib.optionals linux [ pkgs.stdenv.cc.cc.lib ];
          dontBuild = true;
        };
      in {
        node = pkgs.stdenvNoCC.mkDerivation (base // {
          pname = "nodejs-security";
          version = "24.22.1";
          src = pkgs.fetchurl {
            url = "https://nodejs.org/dist/v24.22.1/node-v24.22.1-${platform}.tar.${if linux then "xz" else "gz"}";
            sha256 = if linux then "6c172a9ab6718f7b801fb5a7bd486af2ee5e32758086a04b84fcce2aa77095e6" else "89c682593d76cd44233fa53b1563264e7de9cbb189cad169135c5b4fadfbc0a7";
          };
          installPhase = "mkdir -p $out; cp -R . $out/";
        });
        bun = pkgs.stdenvNoCC.mkDerivation (base // {
          pname = "bun-security";
          version = "1.4.4";
          src = pkgs.fetchurl {
            url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.4/bun-${bunPlatform}.zip";
            sha256 = if linux then "e0446eb55995772eb9894bebae9a6be368d985a8b9271ee124486f9946eedd76" else "c240d7f0ccb90c263a849fcdb09b7ee62630d921348ed6aafda86b9d577bc510";
          };
          installPhase = "mkdir -p $out/bin; cp bun $out/bin/bun; ln -s bun $out/bin/bunx";
        });
      });
  };
}
