{ system, espDev }:
let
  # SDK と shell は上流が検証する nixpkgs で揃える。特に Python 依存と
  # Linux のバイナリ補正用ライブラリを dotfiles 側と混在させない。
  pkgs = import espDev.inputs.nixpkgs { inherit system; };
  # 先に実機用 PoC をビルドした 5.5.1 を維持。SDK のサブモジュールも
  # この hash に含まれ、tools.json が各 OS の compiler URL/hash を固定する。
  # hash は上流の 5.5.1 定義 (2090f261) と同一。
  sdk = espDev.packages.${system}.esp-idf-xtensa.override {
    rev = "v5.5.1";
    sha256 = "sha256-vZ/ZMrOYIgHq0fHnFSN5GLQfYREnf/0PcQI5QllxpTM=";
  };
in
pkgs.mkShell {
  name = "esp-idf-5.5.1-xtensa";
  # SDK の setup hook が IDF_PATH/Python/toolchain を設定する。
  # install.sh・pip install・ユーザー別 checkout は実行しない。
  packages = [ sdk ];
  ESP_IDF_ENV_VERSION = "5.5.1";
}
