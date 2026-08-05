{
  config,
  pkgs,
  lib,
  ...
}:
let
  version = "1.2.0";
  installerPkg = pkgs.fetchurl {
    url = "https://github.com/apple/container/releases/download/${version}/container-${version}-installer-signed.pkg";
    hash = "sha256-0UDUB2/wWT1rT3xYcicXsqvofXVFLP4KIDeSun9I8Hw=";
  };
  user = config.system.primaryUser;
in
{
  # apple/container は Homebrew にも nixpkgs にも無く、公式の署名済み .pkg のみ。
  # Virtualization.framework の entitlement 付き署名バイナリなので nix store からは
  # 動かせず、/usr/local への installer 実行が唯一の導入経路になる。
  #
  # 手作業で入れると新規 Mac のセットアップが再現できなくなるため、pkg 自体は
  # nix で hash 固定して取得し、activation で冪等に流し込む (Xcode CLT と同じ流儀)。
  # 更新は同梱の update-container.sh を使わず version と hash を上げること。
  # self-update させると宣言と実体が乖離する。
  #
  # Apple Silicon 専用 (macOS 26 以降)。Intel Mac には入れない。
  system.activationScripts.postActivation.text = lib.optionalString pkgs.stdenv.hostPlatform.isAarch64 ''
    if ! /usr/local/bin/container --version 2>/dev/null | grep -q "${version}"; then
      echo "installing apple/container ${version}..."
      installer -pkg ${installerPkg} -target / >/dev/null
    fi

    # apiserver の launchd 登録とカーネル設定は ~/Library/Application Support 配下を
    # 触るのでユーザー権限で実行する (activation は root で走る。nix-darwin の
    # postUserActivation は廃止されたため sudo -u で降りる)。
    # `kernel set --recommended` は再実行すると "File exists" で失敗するので、
    # 設定済みかどうかを見て丸ごとスキップし冪等にする。
    containerKernel="/Users/${user}/Library/Application Support/com.apple.container/kernels/default.kernel-arm64"
    if [ ! -e "$containerKernel" ]; then
      echo "initializing apple/container..."
      # カーネル未設定だと start が対話プロンプトを出して失敗するが、
      # apiserver の起動と launchd 登録自体は完了するので続行してよい
      sudo -u ${user} /usr/local/bin/container system start </dev/null >/dev/null 2>&1 || true
      sudo -u ${user} /usr/local/bin/container system kernel set --recommended
    fi
  '';
}
