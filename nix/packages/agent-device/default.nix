# agent-device: iOS/Android の Simulator・実機を CLI から操作するエージェント向けツール (Callstack)。
# 実機 iOS は端末上の XCTest ランナーで tap・snapshot を行う。nixpkgs にも llm-agents.nix にも
# 無いので npm の tarball をそのまま包む (依存なし、Node 22.12 以上)。llm-agents に入ったら移す。
# ランナーのビルド成果物と状態は ~/.agent-device、Swift の補助ビルドは $TMPDIR に書くので、
# パッケージ本体が読み取り専用の store にあっても動く。
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  nodejs,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "agent-device";
  version = "0.21.36";

  src = fetchurl {
    url = "https://registry.npmjs.org/agent-device/-/agent-device-${finalAttrs.version}.tgz";
    hash = "sha256-Cq2Ia0fQal7KjlTTKpdmmF8jKD9JrcHFBFUJoZG8pco=";
  };

  nativeBuildInputs = [ makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/agent-device
    cp -r . $out/lib/agent-device
    makeWrapper ${lib.getExe nodejs} $out/bin/agent-device \
      --add-flags $out/lib/agent-device/bin/agent-device.mjs
    runHook postInstall
  '';

  meta = {
    description = "CLI for AI agents to drive iOS and Android simulators and devices";
    homepage = "https://github.com/callstackincubator/agent-device";
    license = lib.licenses.mit;
    mainProgram = "agent-device";
    platforms = lib.platforms.unix;
  };
})
