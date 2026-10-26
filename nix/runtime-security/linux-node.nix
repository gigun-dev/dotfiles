# Standard source build, retaining nixpkgs platform integration and tests.
# Use the fixed upstream Brotli sources bundled by Node 24.22.1 rather than
# the pinned nixpkgs shared Brotli, whose version alone is not a fix guarantee.
{ pkgs }:
pkgs.nodejs-slim_24.overrideAttrs (old: {
  version = "24.22.1";
  src = pkgs.fetchurl {
    url = "https://nodejs.org/dist/v24.22.1/node-v24.22.1.tar.xz";
    sha256 = "4f5379796280cdaeb0c2f358fd04b6a16cc4fb7dfa83b5a8c91a9d963b435231";
  };
  configureFlags = builtins.filter (flag: !(pkgs.lib.hasPrefix "--shared-brotli" flag)) old.configureFlags;
})
