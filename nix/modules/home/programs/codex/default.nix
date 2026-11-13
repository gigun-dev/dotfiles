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
  llmAgents,
  gigunPlugins,
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

    # 自作 plugin の取得元は全 host で再現可能にする。plugin の有効化は下の
    # syncCodexGigunPlugins が marketplace に合わせる。snapshot
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
  codexConfig = "${config.home.homeDirectory}/.codex/config.toml";
in
{
  # merge-config.nu に merge する理由を書いている。
  home.activation.writeCodexConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    $DRY_RUN_CMD ${lib.getExe pkgs.nushell} ${./merge-config.nu} \
      ${tomlFormat.generate "codex-config" settings} \
      "${config.home.homeDirectory}/.codex/config.toml"
  '';

  # gigun plugin を marketplace に合わせる (gigun-dev/claude-code todo 0070)。Codex は
  # [plugins."x@gigun"] enabled = true を書くだけでは plugin を入れず、`codex plugin add` が要る。
  # add は既存の enabled = false を true に戻すので、表がまだ無いものだけ add する
  # (GUI で切った値を残す)。marketplace から消えた plugin は remove する。
  # add / remove の失敗 (marketplace の snapshot が古い、外部 plugin の取得に失敗した等) は
  # switch を止めず警告に留める。snapshot の更新は `codex plugin marketplace upgrade gigun`。
  home.activation.syncCodexGigunPlugins = lib.mkIf (llmAgents ? codex) (
    lib.hm.dag.entryAfter [ "writeCodexConfig" ] ''
      codex=${lib.getExe llmAgents.codex}
      # 外部 Git source の plugin (visual-explainer など) は add の中で git clone する。
      # activation の PATH には git が無く "No such file or directory" で失敗した。
      export PATH="${lib.makeBinPath [ pkgs.git ]}:$PATH"
      config=${lib.escapeShellArg codexConfig}
      if [ -f "$config" ]; then
        for name in ${lib.escapeShellArgs gigunPlugins.autoEnable}; do
          if ! grep -qF "[plugins.\"$name@gigun\"]" "$config"; then
            $DRY_RUN_CMD "$codex" plugin add "$name@gigun" >/dev/null \
              || echo "codex: $name@gigun を add できなかった" >&2
          fi
        done
        for name in $(grep -o '^\[plugins\."[^"]*@gigun"\]' "$config" | sed 's/^\[plugins\."//; s/@gigun"\]$//'); do
          case " ${toString gigunPlugins.names} " in
            *" $name "*) ;;
            *)
              $DRY_RUN_CMD "$codex" plugin remove "$name@gigun" >/dev/null \
                || echo "codex: $name@gigun を remove できなかった" >&2
              ;;
          esac
        done
      fi
    ''
  );
}
