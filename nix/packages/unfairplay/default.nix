{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule (finalAttrs: {
  pname = "unfairplay";
  version = "0.4.0";

  src = fetchFromGitHub {
    owner = "DrWhax";
    repo = "unfairplay";
    rev = "d7503082a59e3dcfdd3ea7a70434dcecaaaf07df";
    hash = "sha256-nG9rtR20ydy8ugcPkVakziikxbmivXN+AMTwLYqY1Sk=";
  };

  vendorHash = "sha256-c7oQre88gWs8QEZllyoWtxVZH3jGS8Tb1XV4Pm9Co+Y=";
  subPackages = [ "cmd/unfairplay" ];
  env.CGO_ENABLED = "0";
  ldflags = [
    "-s"
    "-w"
    "-X main.version=v${finalAttrs.version}"
  ];

  postInstall = ''
    install -Dm644 -t "$out/share/doc/unfairplay" \
      LICENSE LICENSE-DARKPHOENIX.txt LICENSE-MACOSFAIRFREE.txt NOTICE
  '';

  meta = {
    description = "Recover a FairPlay enrollment model and decrypt personalized iOS IPAs";
    homepage = "https://github.com/DrWhax/unfairplay";
    license = [
      lib.licenses.mit
      lib.licenses.asl20
    ];
    platforms = [
      "aarch64-darwin"
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "unfairplay";
  };
})
