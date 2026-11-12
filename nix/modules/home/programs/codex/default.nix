# ~/.codex/config.toml のうち、宣言したキーだけを merge する。
# 構成は ryoppippi/dotfiles (MIT) の nix/modules/home/programs/codex に寄せている。
# ~/.codex/AGENTS.md は bootstrap.sh と共用の生成スクリプトがあるので dotfiles.nix に残す。
# home 層は Pro / mini-vm / WSL で共有するため、機械ごとに違ってよいもの
# (model, model_reasoning_effort) と、まだ方針を決めていない sandbox_mode /
# approval_policy は宣言しない (todo.txt)。
{
  pkgs,
  lib,
  config,
  ...
}:
let
  tomlFormat = pkgs.formats.toml { };

  settings = {
    # CLAUDE.md しか置いていない repo でも project の指示を読ませる。
    project_doc_fallback_filenames = [ "CLAUDE.md" ];

    # agent の command に対話シェルと同じ PATH・環境変数を見せる (ryoppippi と同じ)。
    allow_login_shell = true;
    shell_environment_policy."inherit" = "all";

    # ryoppippi の web_search_request = true は 0.167 で "is ignored" になる。
    web_search = "live";

    features.memories = true;

    # 自作 plugin の取得元は全 host で再現可能にする。plugin の有効化は利用する
    # harness / host ごとに異なるため、ここでは一律に宣言しない。snapshot
    # refresh は network に依存するため activation では行わず、明示的な
    # `codex plugin marketplace upgrade gigun` に分離する。
    marketplaces.gigun = {
      # codex plugin marketplace add は owner/repo を HTTPS URL に直して保存するが、
      # config.toml に短縮形を直接書くと upgrade が git ls-remote にそのまま渡して失敗する。
      source = "https://github.com/gigun-dev/claude-code.git";
      source_type = "git";
      ref = "main";
    };
  };
in
{
  # merge-config.nu に merge する理由を書いている。
  home.activation.writeCodexConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    $DRY_RUN_CMD ${lib.getExe pkgs.nushell} ${./merge-config.nu} \
      ${tomlFormat.generate "codex-config" settings} \
      "${config.home.homeDirectory}/.codex/config.toml"
  '';
}
