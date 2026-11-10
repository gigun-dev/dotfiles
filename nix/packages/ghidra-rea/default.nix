{
  lib,
  stdenv,
  fetchurl,
  unzip,
  makeWrapper,
  openjdk21,
  coreutils,
}:

stdenv.mkDerivation {
  pname = "ghidra-rea";
  version = "12.1.4";

  # REA 6.8 only accepts Ghidra 12.1.x; nixpkgs currently supplies 12.2.
  src = fetchurl {
    url = "https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip";
    hash = "sha256-3axJ+QPanVusgz5cx5OVCYucM8/TJ5vl8xvQA4fS1Ns=";
  };

  nativeBuildInputs = [
    unzip
    makeWrapper
  ];
  dontConfigure = true;
  dontStrip = true;

  buildPhase = ''
    runHook preBuild
    make -j"$NIX_BUILD_CORES" \
      -C Ghidra/Features/Decompiler/src/decompile/cpp \
      ghidra_opt CXX="c++ -std=c++11" ARCH_TYPE="-arch arm64" OSDIR=mac_arm_64 ADDITIONAL_FLAGS="-w"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/ghidra" "$out/bin"
    cp -R . "$out/lib/ghidra/"
    rm -rf "$out/lib/ghidra/Ghidra/Features/Decompiler/src/decompile/cpp/ghi_opt"
    rm -f "$out/lib/ghidra/Ghidra/Features/Decompiler/src/decompile/cpp/ghidra_opt"
    install -Dm755 Ghidra/Features/Decompiler/src/decompile/cpp/ghidra_opt \
      "$out/lib/ghidra/Ghidra/Features/Decompiler/os/mac_arm_64/decompile"
    wrapProgram "$out/lib/ghidra/support/launch.sh" \
      --set JAVA_HOME "${openjdk21.home}" \
      --prefix PATH : "${lib.makeBinPath [ openjdk21 ]}"
    ln -s "$out/lib/ghidra/ghidraRun" "$out/bin/ghidra"
    makeWrapper "$out/lib/ghidra/support/analyzeHeadless" "$out/bin/ghidra-analyzeHeadless"
    # REA starts the JVM directly, so scope its engine/JDK environment to the command.
    makeWrapper "${coreutils}/bin/env" "$out/bin/with-ghidra" \
      --set GHIDRA_INSTALL_DIR "$out/lib/ghidra" \
      --set JAVA_HOME "${openjdk21.home}"
    runHook postInstall
  '';

  passthru.jdk = openjdk21;
  meta = {
    description = "Ghidra release compatible with the published REA bridge";
    homepage = "https://ghidra-sre.org/";
    license = lib.licenses.asl20;
    platforms = [ "aarch64-darwin" ];
    mainProgram = "ghidra";
  };
}
