# Isolated packages for the frozen Intel host; never activates a generation.
# Pin matches /run/current-system/darwin-version.json on that host.
{
  pkgs ? import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/456e8a9468b9d46bd8c9524425026c00745bc4d2.tar.gz";
    sha256 = "sha256-9O9gNidrdzcb7vgKGtff7QiLtr0IsVaCi0pAXm8anhQ=";
  }) { system = "x86_64-darwin"; },
}:
let
  base = {
    dontBuild = true;
    dontStrip = true; # Preserve upstream Mach-O/V8 image and signature integrity.
    dontPatchShebangs = true;
  };
in
{
  node = pkgs.stdenvNoCC.mkDerivation (
    base
    // {
      pname = "nodejs-security";
      version = "24.22.1";
      src = pkgs.fetchurl {
        url = "https://nodejs.org/dist/v24.22.1/node-v24.22.1-darwin-x64.tar.gz";
        sha256 = "d132557e7ee2b85af08b0c8c34338e65c6430f2238d01f727728ef42dc83b035";
      };
      installPhase = "mkdir -p $out; cp -R . $out/";
    }
  );
  bun = pkgs.stdenvNoCC.mkDerivation (
    base
    // {
      pname = "bun-security";
      version = "1.4.4";
      nativeBuildInputs = [ pkgs.unzip ];
      src = pkgs.fetchurl {
        url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.4/bun-darwin-x64-baseline.zip";
        sha256 = "d4a155adfbfd09155eb3ba05c9e3a544f39297d7a68616d3c7759f67ab5c47dc";
      };
      installPhase = "mkdir -p $out/bin; cp bun $out/bin/bun; ln -s bun $out/bin/bunx";
    }
  );
}
