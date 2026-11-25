# gigun-dev/claude-code の flake が版を固定してビルドした外部 plugin (今は REA) を、
# 各ホストが読む場所へ置く (claude-code の ADR 0007)。版・node・MCP の起動コマンドは
# パッケージ側が持ち、ここは置き場所と、consumer が決める解析エンジンの環境だけを持つ。
#   Claude → ~/.claude/skills/<plugin>  (.claude-plugin/plugin.json を持つので
#                                        <plugin>@skills-dir として MCP ごと読む)
#   Codex  → config.toml の [mcp_servers.<server>] と ~/.agents/skills/<skill>
#   agy    → ~/.gemini/config/plugins.json の 2 つ目の entry
# Why not marketplace の上流 plugin 参照: 写しの中身と node がホストの導入時刻と PATH で
# 決まり、Codex は plugin の MCP に環境変数を渡さないので Ghidra が見えなかった。
# Why not rea setup: Nix の外に状態を書き、起動パスと store path を実行時の値で焼き込む。
#
# option を作らない理由: 使うのはこの home 構成 1 つで、ホスト差は platform から決まる。
# ryoppippi/dotfiles の home module と同じく let に置く。
{
  config,
  options,
  pkgs,
  lib,
  gigunPlugins,
  ...
}:
let
  home = config.home.homeDirectory;

  # Apple Silicon の Mac だけ Nix 版 Ghidra を REA に渡す (nix/packages/ghidra-rea の platforms)。
  # REA は Ghidra の launcher を通さず JVM を直接起動するので、with-ghidra と同じ値を
  # MCP の起動コマンドに焼き込む。Linux では Ghidra 無しの REA がそのまま入る。
  hasGhidraRea = pkgs.stdenv.hostPlatform.isDarwin && pkgs.stdenv.hostPlatform.isAarch64;
  ghidraRea = pkgs.callPackage ../../packages/ghidra-rea { };
  externalPlugins = pkgs.external-plugins.override {
    mcpEnv = lib.optionalAttrs hasGhidraRea {
      rea.rea = {
        GHIDRA_INSTALL_DIR = "${ghidraRea}/lib/ghidra";
        JAVA_HOME = "${ghidraRea.passthru.jdk.home}";
      };
    };
  };
  inherit (externalPlugins.passthru) plugins agy;

  mcpServers = lib.concatMapAttrs (_: p: p.mcpServers) plugins;
  skills = lib.concatMapAttrs (_: p: p.skills) plugins;

  # Codex の tool 呼び出しの待ち時間 (秒)。REA の解析は Codex の既定より長くかかる。
  # 420 は暫定設定 (2026-11) から引き継いだ値で、上限を測って決めたものではない。
  codexServerSettings.rea.tool_timeout_sec = 420;

  # agy (Antigravity CLI) に gigun marketplace の plugin を読ませる。Claude で有効にしている
  # gigun plugin を同じ正本から導き、host 間・harness 間で有効な plugin がずれないようにする。
  # agy-mcp は agy 自身を呼ぶ MCP、telemetry は Claude / Codex のセッションログを読むものなので
  # agy には渡さない。macOS 専用の MCP (tableplus-mcp・xcode-mcp) は Claude 側で無効か未登録
  # なので、Linux 向けに別の除外は要らない。
  # Why not agy plugin install / import: plugin のコピーを作るので claude-code の更新が届かない。
  agyPlugins = lib.subtractLists [ "agy-mcp" "telemetry" ] gigunPlugins.autoEnable;
  # agy.names は npm の外部 plugin (marketplace に無く、全ホストに置く) と、agy 版を
  # ビルドした Git source の marketplace plugin (visual-explainer) を含む。後者は上の
  # 選択に従う。claude-code/plugins には Git source の実体が無いので、1 つ目の entry から外す。
  # 以前は passthru.sources (npm だけ) で分けていたので、visual-explainer は 1 つ目の entry に
  # 入って実体が無く飛ばされ、agy 版は読まれていなかった。
  agyExternal = builtins.filter (
    n: !(builtins.elem n gigunPlugins.names) || builtins.elem n agyPlugins
  ) agy.names;
in
{
  assertions = [
    {
      assertion = lib.all (s: mcpServers ? ${s}) (lib.attrNames codexServerSettings);
      message = "agent-plugins: codexServerSettings names an MCP server that external-plugins does not build: ${toString (lib.subtractLists (lib.attrNames mcpServers) (lib.attrNames codexServerSettings))}";
    }
  ];

  # GUI の ghidra と、REA 以外から Nix 版 Ghidra を使う with-ghidra。
  home.packages = lib.optional hasGhidraRea ghidraRea;

  home.file =
    lib.mapAttrs' (name: p: lib.nameValuePair ".claude/skills/${name}" { source = p.dir; }) plugins
    # Codex は skill のディレクトリごとの symlink を読む (agent-skills.nix の agents target と同じ形)。
    // lib.mapAttrs' (skill: dir: lib.nameValuePair ".agents/skills/${skill}" { source = dir; }) skills
    // {
      # agy は plugins.json を読むだけで書き換えない (plugin の install 状態は config.json 側)。
      # path は絶対パスで書く。agy 1.5.5 は文書と違って `~/` を展開せず、その entry を
      # "must be an absolute path" で飛ばす (2026-11-12 実測)。
      ".gemini/config/plugins.json".text = builtins.toJSON {
        entries = [
          {
            path = "${home}/ghq/github.com/gigun-dev/claude-code/plugins";
            include_only = lib.subtractLists agy.names agyPlugins;
          }
          {
            path = agy.dir;
            include_only = agyExternal;
          }
        ];
      };
    };

  # ~/.agents/skills は agent-skills-nix が rsync --delete で丸ごと持つ。上の link を
  # 消されないよう、その skill 名だけ同期から外す (既定の /.system は残す)。
  # 新しいホストでは同期 (agent-skills) が linkGeneration より先に走って marker を作るので、
  # link だけが先に入ったディレクトリを同期が「管理外」と拒む順にはならない
  # (2026-11-25 にビルドした activate の順序で確認。DAG の同順位を名前順で並べた結果)。
  programs.agent-skills.excludePatterns =
    options.programs.agent-skills.excludePatterns.default
    ++ map (skill: "/${skill}") (lib.attrNames skills);

  # command はパッケージの実行ファイル (固定した node と mcpEnv を焼き込み済み)。Codex は
  # config の MCP に親の環境を渡さないので、環境は実行ファイル側に持たせる。
  # merge-config.nu は宣言した server の表を丸ごと置き換えるので、暫定設定の
  # `# BEGIN dotfiles Codex REA` ブロック (command = "/bin/bash" と launcher の args) も
  # 最初の switch で消える。
  dotfiles.codex.settings.mcp_servers = lib.mapAttrs (
    server: command: { inherit command; } // codexServerSettings.${server} or { }
  ) mcpServers;
}
