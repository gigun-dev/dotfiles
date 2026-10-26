# Official archives using the caller’s existing compatible toolchain.
{ pkgs }:
let
  arm = pkgs.stdenv.hostPlatform.isAarch64;
  nodePlatform = if arm then "arm64" else "x64";
  bunPlatform = if arm then "aarch64" else "x64-baseline";
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
        url = "https://nodejs.org/dist/v24.22.1/node-v24.22.1-darwin-${nodePlatform}.tar.gz";
        sha256 =
          if arm then
            "89c682593d76cd44233fa53b1563264e7de9cbb189cad169135c5b4fadfbc0a7"
          else
            "d132557e7ee2b85af08b0c8c34338e65c6430f2238d01f727728ef42dc83b035";
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
        url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.4/bun-darwin-${bunPlatform}.zip";
        sha256 =
          if arm then
            "c240d7f0ccb90c263a849fcdb09b7ee62630d921348ed6aafda86b9d577bc510"
          else
            "d4a155adfbfd09155eb3ba05c9e3a544f39297d7a68616d3c7759f67ab5c47dc";
      };
      installPhase = "mkdir -p $out/bin; cp bun $out/bin/bun; ln -s bun $out/bin/bunx";
    }
  );
}
