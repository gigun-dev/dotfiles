{
  lib,
  buildGoModule,
  libfido2,
  writableTmpDirAsHomeHook,
}:

buildGoModule {
  pname = "ipatool-security-key";
  version = "0-unstable-2026-11-14";

  # Fetch with the invoking user's SSH agent, never with a token in the derivation.
  # Linux outputs do not select this Darwin-only package.
  src = builtins.fetchGit {
    url = "ssh://git@github.com/gigun-dev/ipatool.git";
    ref = "main";
    rev = "f6ef5b63ceadab8428cbca4490b7c68c7a2e098b";
  };
  vendorHash = "sha256-Fb5Zufd/K8a0why62V8ShQR65P/FefRFfde5tYVB4JQ=";
  proxyVendor = true;
  subPackages = [ "." ];
  nativeBuildInputs = [ writableTmpDirAsHomeHook ];
  postPatch = ''
    substituteInPlace internal/securitykey/fido_darwin.go \
      --replace-fail '"/opt/homebrew/lib/libfido2.dylib", "/usr/local/lib/libfido2.dylib"' \
        '"${libfido2}/lib/libfido2.dylib"' \
      --replace-fail 'install it with brew install libfido2' 'rebuild the Nix package with libfido2'
    cp ${./library_test.go} internal/securitykey/nix_library_test.go
  '';

  ldflags = [
    "-s"
    "-w"
    "-X github.com/majd/ipatool/v2/cmd.version=security-key-f6ef5b6"
  ];

  checkPhase = ''
    runHook preCheck
    go generate ./...
    go test ./internal/securitykey/... ./internal/storeauth ./pkg/http ./pkg/appstore ./cmd ./internal/store/emulator
    runHook postCheck
  '';

  postInstall = ''
    mv "$out/bin/ipatool" "$out/bin/ipatool-security-key"
    install -Dm644 docs/apple-security-keys.md "$out/share/doc/ipatool-security-key/apple-security-keys.md"
    install -Dm644 LICENSE "$out/share/doc/ipatool-security-key/LICENSE"
  '';

  meta = {
    description = "Private ipatool downstream with USB security-key authentication";
    homepage = "https://github.com/gigun-dev/ipatool";
    license = lib.licenses.mit;
    platforms = [ "aarch64-darwin" ];
    mainProgram = "ipatool-security-key";
  };
}
