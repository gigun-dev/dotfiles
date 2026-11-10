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

    # 自作 plugin の登録は全 host で再現可能にする。marketplace の snapshot
    # refresh は network に依存するため activation では行わず、明示的な
    # `codex plugin marketplace upgrade gigun` に分離する。
    marketplaces.gigun = {
      source = "gigun-dev/claude-code";
      source_type = "git";
      ref = "main";
    };
    plugins = {
      "t3@gigun".enabled = true;
      "todo@gigun".enabled = true;
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
