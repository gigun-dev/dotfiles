# T3 Code の settings.json / client-settings.json / keybindings.json を宣言する。
# Darwin: アプリ本体は homebrew cask (darwin/homebrew.nix)。3 ファイルとも merge する。
# NixOS (mini-vm): server は nixos/mini-vm.nix の systemd.services.t3code。デスクトップ専用の
#   client-settings.json / keybindings.json は要らないので settings.json だけ merge する。
# 構成は ryoppippi/dotfiles (MIT) の nix/modules/home/programs/t3code/default.nix に寄せている。
# ryoppippi は Mac のデスクトップ側だけで、Linux server の分岐は gigun 固有。
# home 層は WSL と共有 (T3 は Windows native 側にある) なので、Linux では /etc/NIXOS が
# あるときだけ書く。それ以外は no-op。
{
  pkgs,
  lib,
  config,
  llmAgents, # inputs.llm-agents.packages.${system} (flake.nix の extraSpecialArgs)
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin isLinux;
  t3codeStateDir = "$HOME/.t3/userdata";
  jq = lib.getExe pkgs.jq;

  settings = {
    # このマシンの Claude instance は claudeAgent の 1 つだけ。
    defaultModelSelection = {
      instanceId = "claudeAgent";
      model = "claude-opus-5-5";
      options = [
        {
          id = "effort";
          value = "medium";
        }
      ];
    };
    fallbackModelSelection = {
      instanceId = "claudeAgent";
      model = "claude-opus-5-5";
    };
    defaultRuntimeMode = "auto";

    # この Mac にだけ残り T3 Code は同期しない。merge は list を丸ごと置き換えるので、
    # UI で足したお気に入りはここにも記録する。
    favorites = [
      {
        provider = "claudeAgent";
        model = "claude-opus-5-5";
      }
      {
        provider = "claudeAgent";
        model = "claude-sonnet-5-5";
      }
      {
        provider = "codex";
        model = "gpt-6-astra";
      }
      {
        provider = "codex";
        model = "gpt-6.1-sol";
      }
      {
        provider = "codex";
        model = "gpt-6-luna";
      }
    ];

    idleCompaction = "beforeCacheExpires";

    # worktree は常に ~/.t3/worktrees/<repo>/<branch> に作られる (T3 Code に場所の設定は無い)。
    defaultThreadEnvMode = "worktree";
    branchNamingMode = "semantic";
    branchNamePrefix = "gigun";
    removeAgentCreditsOnMerge = true;
    defaultAutoPull = true;
    reviewGuidesEnabled = true;

    # storageCleanup は設定 UI が編集する全体ポリシー。トップレベルの worktreeCleanup は
    # それを丸ごと上書きするので、正本を 1 つにするため null で消す。
    storageCleanup = {
      worktreeKeepWhen = "uncommitted-changes";
      worktreeAfterDays = 14;
      worktreeOnMerge = true;
      worktreeOnDelete = true;
      worktreeUnchanged = true;
      browserArtifactsAfterDays = 30;
      logsAfterDays = 30;
    };
    worktreeCleanup = null;

    enableDeviceSupport = true;
    enableAgentDeviceAccess = true;
    cursorKeychainUsageEnabled = true;

    # Labs の beta。端末ごとに持ち、リンクは両端で linkedEnvironmentsEnabled が要る。
    guestSharingEnabled = true;
    linkedEnvironmentsEnabled = true;

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

  # デスクトップ専用の設定は server 設定と別ファイル。
  clientSettings = {
    confirmQuit = "direct";
    notificationMode = "notifications-and-sound";
    inAppNotificationsEnabled = true;
    sidebarWorkingShelfEnabled = true;
    boringSidebarMultilineRows = true;
  };

  # 既定と違う binding だけ宣言する。コマンドにユーザー rule があると、そのコマンドの
  # 既定 binding は全て置き換わり、他コマンドの既定は起動時に T3 Code が補完する。
  # unbind 構文は無いので `when = "false"` で無効化する。mod+enter は composer の
  # 送信 (turn 実行中は steer) に残す。
  keybindings =
    map
      (command: {
        key = "mod+alt+enter";
        inherit command;
        when = "false";
      })
      [
        "composer.sendBackground"
        "composer.sendAndNewThread"
      ];

  # symlink ではなく merge: T3 Code は UI 操作のたびに atomic rename で書き直すため、
  # store への symlink は通常ファイルに置換されて次回 switch で壊れる。
  # 宣言したキーが勝ち、それ以外は既存ファイルのまま残す。(ryoppippi/dotfiles の mergeJson)
  mergeJson = filter: name: value: ''
    SETTINGS_FILE="$SETTINGS_DIR/${name}"
    SOURCE_FILE="${pkgs.writeText "t3code-${name}" (builtins.toJSON value)}"
    if [ -f "$SETTINGS_FILE" ]; then
      TEMP_FILE="$(mktemp "$SETTINGS_DIR/.${name}.XXXXXX")"
      if ! ${jq} -s '${filter}' "$SETTINGS_FILE" "$SOURCE_FILE" > "$TEMP_FILE"; then
        rm -f "$TEMP_FILE"
        exit 1
      fi
      chmod 644 "$TEMP_FILE"
      mv "$TEMP_FILE" "$SETTINGS_FILE"
    else
      ${jq} . "$SOURCE_FILE" > "$SETTINGS_FILE"
    fi
  '';
  mergeSettings = mergeJson ".[0] * .[1]";
  # 宣言したコマンドの既存 rule を捨てて置き換える (T3 Code の user rule が
  # そのコマンドの既定を shadow する挙動に合わせる)。
  mergeKeybindings = mergeJson "(.[1] | map(.command)) as $declared | [.[0][] | select(.command as $c | $declared | index($c) | not)] + .[1]";
in
lib.mkIf (isDarwin || isLinux) {
  # T3 Code が `t3` CLI を置く場所。.zshenv が hm-session-vars.sh を読むので PATH に届く。
  # Linux の t3 は nixpkgs の t3code (systemd service が参照) なので ~/.t3/bin は使わない。
  home.sessionPath = lib.mkIf isDarwin [ "$HOME/.t3/bin" ];

  home.activation.configureT3codeSettings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    ${lib.optionalString isLinux "if [ -e /etc/NIXOS ]; then"}
    SETTINGS_DIR="${t3codeStateDir}"
    mkdir -p "$SETTINGS_DIR"

    ${mergeSettings "settings.json" settings}
    ${lib.optionalString isDarwin ''
      ${mergeSettings "client-settings.json" clientSettings}
      ${mergeKeybindings "keybindings.json" keybindings}
    ''}
    ${lib.optionalString isLinux "fi"}
  '';
}
