# T3 Code (GUI) の settings.json を宣言する。アプリ本体は homebrew cask (darwin/homebrew.nix)。
# home 層は WSL / mini-vm と共有なので、Darwin 以外では丸ごと no-op にする。
{
  pkgs,
  lib,
  config,
  llmAgents, # inputs.llm-agents.packages.${system} (flake.nix の extraSpecialArgs)
  ...
}:
let
  t3codeStateDir = "$HOME/.t3/userdata";
  jq = lib.getExe pkgs.jq;

  settings = {
    # agent を nix の実体に固定する。PATH 解決だと ~/.local/bin の自己更新版などに負ける。
    # driver が欠けた instance があると T3 Code は settings.json 全体を拒否するため全件で明示する。
    # displayName も固定: 未指定だと解決済み binary path がラベルに永続化され、
    # UI に store パスが出て、下の merge でも残り続ける。
    providerInstances =
      lib.mapAttrs
        (
          id: instance:
          {
            driver = id;
            enabled = true;
          }
          // instance
        )
        {
          claudeAgent = {
            displayName = "Claude";
            config.binaryPath = lib.getExe pkgs.claude-code;
          };
          codex = {
            displayName = "Codex";
            config.binaryPath = lib.getExe llmAgents.codex;
          };
          opencode = {
            displayName = "OpenCode";
            config.binaryPath = lib.getExe llmAgents.opencode;
          };
          pi = {
            displayName = "Pi";
            config.binaryPath = lib.getExe llmAgents.pi;
          };
        };

    # agent は nix で固定しているので、上流の更新通知はノイズ。
    enableProviderUpdateChecks = false;

    # ghq で ~/ghq 配下に clone する運用に合わせる。
    addProjectBaseDirectory = "${config.home.homeDirectory}/ghq";
    ghqCloneLayout = true;
  };

  # symlink ではなく merge: T3 Code は UI 操作のたびに atomic rename で書き直すため、
  # store への symlink は通常ファイルに置換されて次回 switch で壊れる。
  # 宣言したキーが勝ち、それ以外は既存ファイルのまま残す。
  mergeJson = name: value: ''
    SETTINGS_FILE="$SETTINGS_DIR/${name}"
    SOURCE_FILE="${pkgs.writeText "t3code-${name}" (builtins.toJSON value)}"
    if [ -f "$SETTINGS_FILE" ]; then
      TEMP_FILE="$(mktemp "$SETTINGS_DIR/.${name}.XXXXXX")"
      if ! ${jq} -s '.[0] * .[1]' "$SETTINGS_FILE" "$SOURCE_FILE" > "$TEMP_FILE"; then
        rm -f "$TEMP_FILE"
        exit 1
      fi
      chmod 644 "$TEMP_FILE"
      mv "$TEMP_FILE" "$SETTINGS_FILE"
    else
      ${jq} . "$SOURCE_FILE" > "$SETTINGS_FILE"
    fi
  '';
in
lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
  home.activation.configureT3codeSettings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    SETTINGS_DIR="${t3codeStateDir}"
    mkdir -p "$SETTINGS_DIR"

    ${mergeJson "settings.json" settings}
  '';
}
