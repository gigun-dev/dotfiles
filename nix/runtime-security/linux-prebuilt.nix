# Targeted to hosts with an already configured nix-ld, verified on mini-vm.
# Preserve the signed upstream ELF; autoPatchelf causes startup SIGSEGV here.
{ pkgs }:
pkgs.stdenvNoCC.mkDerivation {
  pname = "nodejs-security";
  version = "24.22.1";
  src = pkgs.fetchurl {
    url = "https://nodejs.org/dist/v24.22.1/node-v24.22.1-linux-x64.tar.xz";
    sha256 = "6c172a9ab6718f7b801fb5a7bd486af2ee5e32758086a04b84fcce2aa77095e6";
  };
  dontBuild = true;
  dontFixup = true;
  installPhase = "mkdir -p $out; cp -R . $out/";
}
