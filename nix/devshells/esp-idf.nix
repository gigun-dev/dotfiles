{ system, espDev }:
let
  # SDK と shell は上流が検証する nixpkgs で揃える。特に interpreter と
  # Linux のバイナリ補正用ライブラリを dotfiles 側と混在させない。
  pkgs = import espDev.inputs.nixpkgs { inherit system; };
  # 2026-09-05 時点の公式 stable。上流 Nix 定義の既定版には追従せず、
  # SDK の tag/submodule hash と tools.json の compiler hash を使う。
  # Python パッケージは上流の 5.5 用セットを使わず、下の uv.lock で管理する。
  sdk = espDev.packages.${system}.esp-idf-xtensa.override {
    rev = "v6.1";
    sha256 = "sha256-6+mPhof81Yrre8CFar33ufzmPHedSnVfTG5G9A6MbYM=";
    python3 = pkgs.python3 // {
      withPackages = _: pkgs.python3;
    };
  };
  pythonProject = ./esp-idf-python;
  # lock が変わった環境を実行中の旧プロセスと共有しない。
  pythonLock = builtins.hashString "sha256" (builtins.readFile (pythonProject + /uv.lock));
  # Nix が SDK の shebang を裸の Python に固定するため、CLI の起動だけは
  # uv 環境の interpreter を明示する。SDK本体を再パッチする必要はない。
  idfCli = pkgs.writeShellScriptBin "idf.py" ''
    exec "$IDF_PYTHON_ENV_PATH/bin/python" ${sdk}/tools/idf.py "$@"
  '';
in
pkgs.mkShell {
  name = "esp-idf-6.1-xtensa";
  packages = [
    sdk
    pkgs.uv
  ];
  ESP_IDF_ENV_VERSION = "6.1";
  # export.sh を使わないため component-manager が読む SDK 版もここで設定。
  ESP_IDF_VERSION = "6.1";
  # Nix は interpreter/native tools、uv は Python の依存解決と配置を担当。
  # SDK の旧 Python hook が作る PYTHONPATH を混ぜない。uv は通常起動時に
  # lock を更新せず、端末固有 cache 内へ同期する（初回のみ download）。
  shellHook = ''
    unset PYTHONPATH
    ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
      # PyPI manylinux wheel が参照する標準 C++/zlib を NixOS でも見つける。
      export LD_LIBRARY_PATH="${
        pkgs.lib.makeLibraryPath [
          pkgs.stdenv.cc.cc.lib
          pkgs.zlib
        ]
      }''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    ''}
    export UV_PROJECT_ENVIRONMENT="''${XDG_CACHE_HOME:-$HOME/.cache}/esp-idf/6.1/${system}/${pythonLock}/venv"
    uv sync --project ${pythonProject} --locked --no-dev \
      --python ${pkgs.python3.interpreter} --no-python-downloads || exit $?
    export VIRTUAL_ENV="$UV_PROJECT_ENVIRONMENT"
    export IDF_PYTHON_ENV_PATH="$VIRTUAL_ENV"
    export PATH="${idfCli}/bin:$VIRTUAL_ENV/bin:$PATH"
    # 上流 hook の constraints 無効化に頼らず、保存した公式条件を明示検査。
    # IDF_TOOLS_PATH の読み取り専用 store に constraints を取得させない。
    python "$IDF_PATH/tools/check_python_dependencies.py" \
      -r "$IDF_PATH/tools/requirements/requirements.core.txt" \
      -c ${pythonProject}/espidf.constraints.v6.1.txt || exit $?
  '';
}
