# agy (Antigravity CLI) の設定とグローバル MCP サーバーを宣言する。
# 構成は ryoppippi/dotfiles (MIT) の nix/modules/home/programs/* に揃えている。
# ~/.gemini/config/plugins.json は Claude / Codex と正本を共有するため agent-plugins.nix が持ち、
# T3 Code の隔離プロファイルからの symlink は programs/t3code/default.nix が持つ。
{
  config,
  pkgs,
  lib,
  ...
}:
let
  home = config.home.homeDirectory;
  jq = lib.getExe pkgs.jq;

  settings = {
    toolPermission = "always-proceed";
  };

  # Claude / Codex は各クラウド側で Figma MCP を設定済みのため agy のみ宣言する。
  mcpConfig = {
    mcpServers.figma.serverUrl = "https://mcp.figma.com/mcp";
  };

  # symlink ではなく deep merge: agy は /config や `agy mcp add/remove` でこれらのファイルを
  # 書き直すため、宣言したキーだけを入れ、既存キー (trustedWorkspaces や手動追加 MCP 等) は残す。
  mergeJson = name: target: value: ''
    TARGET_FILE="${target}"
    TARGET_DIR="$(dirname "$TARGET_FILE")"
    SOURCE_FILE="${pkgs.writeText "agy-${name}" (builtins.toJSON value)}"
    if [ -n "''${DRY_RUN_CMD:-}" ]; then
      echo "would merge declarative agy ${name} into $TARGET_FILE"
    else
      mkdir -p "$TARGET_DIR"
      TEMP_FILE="$(mktemp "$TARGET_DIR/.${name}.XXXXXX")"
      if [ -s "$TARGET_FILE" ]; then
        MERGE_INPUT=("$TARGET_FILE" "$SOURCE_FILE")
      else
        MERGE_INPUT=("$SOURCE_FILE")
      fi
      if ! ${jq} -s 'reduce .[] as $x ({}; . * $x)' "''${MERGE_INPUT[@]}" > "$TEMP_FILE"; then
        rm -f "$TEMP_FILE"
        echo "agy ${name}: merge failed; $TARGET_FILE is unchanged" >&2
        exit 1
      fi
      chmod 600 "$TEMP_FILE"
      mv "$TEMP_FILE" "$TARGET_FILE"
    fi
  '';
in
{
  # agy (antigravity-cli) は既定でバックグラウンド自己更新するが nix store は read-only。
  # 更新は `nix run .#update-ai-tools` に一本化する。
  # 同じ理由で `agy install` (PATH / shell 設定の書き換え) も実行しないこと。
  home.sessionVariables.AGY_CLI_DISABLE_AUTO_UPDATE = "1";

  # agy の承認方針を Pro と mini-vm で揃える。always-proceed は terminal コマンドに加えて
  # MCP の tool 呼び出しも確認なしで通す (agy 1.5.x の changelog)。T3 Code の Antigravity
  # セッション (`agy acp`) もこの値に従う。既定の request-review だと REA などの MCP を
  # 呼ぶたびに承認待ちで止まり、T3 から任せた作業が進まない。
  # Why not Auto モード: 安全なコマンドは通すが、MCP の呼び出しは毎回確認する (mini-vm の
  # agy acp で確認)。Why not mcp(...) の許可ルール: 特定の server だけでなく agy 全体を
  # 確認なしで動かしたい。
  home.activation.configureAgySettings = lib.hm.dag.entryAfter [ "linkGeneration" ] (
    mergeJson "settings.json" "${home}/.gemini/antigravity-cli/settings.json" settings
  );

  # agy のグローバル MCP サーバー設定。正本は ~/.gemini/config/mcp_config.json に一本化し、
  # T3 Code の隔離プロファイルからの参照は programs/t3code/default.nix 側で symlink する。
  home.activation.configureAgyMcpConfig = lib.hm.dag.entryAfter [ "linkGeneration" ] (
    mergeJson "mcp_config.json" "${home}/.gemini/config/mcp_config.json" mcpConfig
  );
}
