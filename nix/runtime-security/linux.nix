{ pkgs }:
{
  node = import ./linux-prebuilt.nix { inherit pkgs; };
  bun = pkgs.stdenvNoCC.mkDerivation {
    pname = "bun-security";
    version = "1.4.4";
    src = pkgs.fetchurl {
      url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.4/bun-linux-x64-baseline.zip";
      sha256 = "e0446eb55995772eb9894bebae9a6be368d985a8b9271ee124486f9946eedd76";
    };
    nativeBuildInputs = [
      pkgs.unzip
      pkgs.autoPatchelfHook
    ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib ];
    dontBuild = true;
    installPhase = "mkdir -p $out/bin; cp bun $out/bin/bun; ln -s bun $out/bin/bunx";
  };
}
