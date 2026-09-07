{ pkgs }:
let
  indexes = ./esp32drop;
  # Index の更新を既存インストールへ混ぜない。配布 archive の SHA-256 は
  # Arduino CLI が各 index の checksum と照合する。
  lock = builtins.hashString "sha256" (
    builtins.readFile (indexes + /package_index.json)
    + builtins.readFile (indexes + /package_m5stack_index.json)
    + builtins.readFile (indexes + /library_index.json)
    + pkgs.arduino-cli.version
  );
  setup = pkgs.writeShellScriptBin "esp32drop-setup" ''
    set -euo pipefail
    mkdir -p "$ESP32DROP_ENV_ROOT/data" "$ESP32DROP_ENV_ROOT/user" "$ESP32DROP_ENV_ROOT/downloads"
    for index in package_index.json package_m5stack_index.json library_index.json; do
      install -m 644 "${indexes}/$index" "$ESP32DROP_ENV_ROOT/data/$index"
    done
    # mutable な世界の index update は呼ばない。選択版とその依存だけの
    # snapshot を使い、通常の Arduino15 / Documents/Arduino を汚さない。
    ${pkgs.arduino-cli}/bin/arduino-cli --config-file "$ESP32DROP_CONFIG" core install m5stack:esp32@3.3.8
    ${pkgs.arduino-cli}/bin/arduino-cli --config-file "$ESP32DROP_CONFIG" lib install --no-deps M5GFX@0.2.28 M5Unified@0.2.21
  '';
  build = pkgs.writeShellScriptBin "esp32drop-build" ''
    set -euo pipefail
    repo=$(cd "''${1:?usage: esp32drop-build /path/to/ESP32Drop}" && pwd)
    fqbn="''${FQBN:-m5stack:esp32:m5stack_stopwatch:PartitionScheme=huge_app,PSRAM=opi,DebugLevel=error,USBMode=default,CDCOnBoot=cdc,UploadMode=cdc}"
    board=$(printf '%s' "$fqbn" | cut -d: -f3)
    output="$ESP32DROP_ENV_ROOT/build/$(basename "$repo")/$board"
    mkdir -p "$output"
    # upstream の common.sh は Arduino15 と repo 内 build に固定するため
    # 同じ compile 引数をここで組み立て、成果物とログは専用 cache に置く。
    shift
    if [ "$#" -eq 0 ]; then
      set -- PrintReceivedFiles ShowReceivedImage GreetingCard
    fi
    for name in "$@"; do
      case "$name" in
        PrintReceivedFiles|ShowReceivedImage|GreetingCard) ;;
        *) echo "Unknown example: $name" >&2; exit 2 ;;
      esac
      echo "Building $name ($fqbn)"
      ${pkgs.arduino-cli}/bin/arduino-cli --config-file "$ESP32DROP_CONFIG" compile \
        --fqbn "$fqbn" --library "$repo/ESP32Drop" --warnings all --clean \
        --build-property compiler.cpp.extra_flags=-Wshadow \
        --build-path "$output/$name" "$repo/ESP32Drop/examples/$name" \
        > "$output/$name.log" 2>&1 || { tail -50 "$output/$name.log"; exit 1; }
      tail -5 "$output/$name.log"
    done
    echo "Build logs: $output"
  '';
in
pkgs.mkShell {
  name = "esp32drop-arduino-3.3.8";
  packages = [
    pkgs.arduino-cli
    setup
    build
    pkgs.python3
  ];
  shellHook = ''
        # 上流バイナリ index は macOS 用。Linux に入れて build 済みとは言わない。
        if [ "${pkgs.stdenv.hostPlatform.system}" != aarch64-darwin ]; then
          echo "esp32drop currently supports aarch64-darwin only" >&2
          exit 1
        fi
    export ESP32DROP_ENV_ROOT="''${XDG_CACHE_HOME:-$HOME/.cache}/esp32drop/${pkgs.stdenv.hostPlatform.system}/${lock}"
        export ESP32DROP_CONFIG="$ESP32DROP_ENV_ROOT/arduino-cli.yaml"
        mkdir -p "$ESP32DROP_ENV_ROOT"
        cat > "$ESP32DROP_CONFIG" <<YAML
    directories:
      data: $ESP32DROP_ENV_ROOT/data
      user: $ESP32DROP_ENV_ROOT/user
      downloads: $ESP32DROP_ENV_ROOT/downloads
    board_manager:
      additional_urls:
        - https://static-cdn.m5stack.com/resource/arduino/package_m5stack_index.json
    build_cache:
      path: $ESP32DROP_ENV_ROOT/build-cache
    YAML
  '';
}
