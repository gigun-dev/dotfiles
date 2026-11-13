{
  config,
  pkgs,
  lib,
  shellLinksManagedByAnsible ? false,
  gigunPlugins,
  ...
}:
let
  dotfilesPath = "${config.home.homeDirectory}/ghq/github.com/gigun-dev/dotfiles";
  mkLink = path: config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/${path}";
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  agySettings.toolPermission = "always-proceed";
  claudeSettings = builtins.fromJSON (builtins.readFile ../../../claude/settings.json);
  # Linux hosts need the shared plugin registry, but not Darwin-only permissions,
  # hooks or prose carrying /Users paths. Keep the subset derived from the same
  # source so enabled plugins cannot silently drift between Pro and mini-vm.
  linuxClaudeSettings = {
    inherit (claudeSettings) enabledPlugins extraKnownMarketplaces;
  }
  // {
    extraKnownMarketplaces = claudeSettings.extraKnownMarketplaces // {
      gigun = claudeSettings.extraKnownMarketplaces.gigun // {
        source = claudeSettings.extraKnownMarketplaces.gigun.source // {
          path = "${config.home.homeDirectory}/ghq/github.com/gigun-dev/claude-code";
        };
      };
    };
  };
  claudeSettingsSource =
    if isDarwin then
      ../../../claude/settings.json
    else
      builtins.toFile "claude-settings-linux.json" (builtins.toJSON linuxClaudeSettings);
  uvActivationInputs = builtins.path {
    path = ../../../uv;
    name = "uv-activation-inputs";
    filter =
      path: _:
      builtins.elem path (
        map toString [
          ../../../uv
          ../../../uv/sync-tools.sh
          ../../../uv/tools.txt
          ../../../uv/uv.toml
        ]
      );
  };

  # launchd は StandardOutPath の親ディレクトリを作らないので、既存の ~/Library/Logs 直下に置く。
  uvUpgradeLog = "${config.home.homeDirectory}/Library/Logs/uv-tool-upgrade.log";
  # launchd の PATH は /usr/bin:/bin 程度なので、bark-notify.sh が使う age / jq を store から渡す。
  # xxd・openssl・curl・readlink は macOS 標準のものを使う。
  uvToolUpgrade = pkgs.writeShellScript "uv-tool-upgrade" ''
    set -u
    export PATH=${
      lib.makeBinPath [
        pkgs.age
        pkgs.jq
      ]
    }:/usr/bin:/bin
    date
    out=$(UV_BIN=${pkgs.uv}/bin/uv ${pkgs.bash}/bin/bash "${uvActivationInputs}/sync-tools.sh" --upgrade 2>&1)
    status=$?
    printf '%s\n' "$out"
    [ "$status" != 0 ] || exit 0
    body=$(printf '%s\n' "$out" | grep -E 'upgrade に失敗|Takumi Guard|error' | tail -n 3)
    jq -n --arg message "''${body:-exit $status}"$'\n'"詳細: ${uvUpgradeLog}" --arg cwd "${dotfilesPath}" \
      '{title: "uv tool upgrade 失敗", message: $message, cwd: $cwd}' \
      | "${dotfilesPath}/claude/hooks/bark-notify.sh" --job || true
    exit "$status"
  '';

  # SF Symbols の CLI は自分の実行ファイルパスから親の .app を遡ってリソース
  # (Contents/Resources) を読むため、bundle の外へ symlink を張ると
  # "could not find an SF Symbols.app to load resources from" で落ちる。
  # exec で実体パスを叩けば argv[0] が bundle 内に戻るので、中身のある wrapper
  # を挟む (リンク先そのものは store で構わない)。
  # ~/.codex/AGENTS.md の中身。bootstrap.sh と同じスクリプトで作る (nix は呼ぶだけ)。
  codexAgentsMd = pkgs.runCommand "codex-agents-md" { } ''
    sh ${../../../agents/codex-agents-md.sh} ${../../../agents} > $out
  '';

  # agy (Antigravity CLI) に gigun marketplace の plugin を読ませる。Claude で有効にしている
  # gigun plugin を同じ正本から導き、host 間・harness 間で有効な plugin がずれないようにする。
  # agy-mcp は agy 自身を呼ぶ MCP、telemetry は Claude / Codex のセッションログを読むものなので
  # agy には渡さない。macOS 専用の MCP (tableplus-mcp・xcode-mcp) は Claude 側で無効か未登録
  # なので、Linux 向けに別の除外は要らない。外部 npm plugin (rea) は下の agyExternalPlugins
  # の entry で読ませ、Git source の外部 plugin は agy 版が無いので agy が黙って飛ばす。
  # Why not agy plugin install / import: plugin のコピーを作るので claude-code の更新が届かない。
  # path は絶対パスで書く。agy 1.5.5 は文書と違って `~/` を展開せず、その entry を
  # "must be an absolute path" で飛ばす (2026-11-12 実測)。
  agyPlugins = lib.subtractLists [ "agy-mcp" "telemetry" ] gigunPlugins.autoEnable;

  # marketplace の外部 npm plugin (rea) は claude-code/plugins に実体が無いので、
  # gigun-plugins の flake が包んだ agy 版を別 entry で読ませる。node と skill の分割は
  # パッケージ側が持ち、ここは解析エンジンの環境だけを渡す (with-ghidra と同じ値)。
  # Why not rea setup: ~/.gemini/config/ に書き、起動パスと Ghidra の store path を
  # 実行時の値で焼き込むので、switch で動かせない。
  ghidraRea = pkgs.callPackage ../../packages/ghidra-rea { };
  hasGhidraRea = pkgs.stdenv.hostPlatform.isDarwin && pkgs.stdenv.hostPlatform.isAarch64;
  agyExternalPlugins = pkgs.agy-external-plugins.override {
    mcpEnv = lib.optionalAttrs hasGhidraRea {
      rea.rea = {
        GHIDRA_INSTALL_DIR = "${ghidraRea}/lib/ghidra";
        JAVA_HOME = "${ghidraRea.passthru.jdk.home}";
      };
    };
  };
  agyExternalNames = lib.attrNames agyExternalPlugins.passthru.sources;

  # gigun plugin は claude/settings.json に書かず、marketplace を正本にして live へ反映する
  # (gigun-dev/claude-code todo 0070)。未記載のものだけ true で足し、GUI で切り替えた値は
  # 残す。marketplace から消えたものは落とす。deep merge は宣言から消したキーを live に
  # 残すので、harness・workers-fetch が消えた後も true のまま残っていた。
  claudeGigunFilter = pkgs.writeText "claude-gigun-plugins.jq" ''
    .enabledPlugins = (
      (.enabledPlugins // {})
      | with_entries(select(
          (.key | endswith("@gigun") | not)
          or ((.key | rtrimstr("@gigun")) as $n | $names | any(. == $n))
        ))
      | reduce $auto[] as $n (.; if has($n + "@gigun") then . else .[$n + "@gigun"] = true end)
    )
  '';
  gigunJqArgs = "--argjson names ${lib.escapeShellArg (builtins.toJSON gigunPlugins.names)} --argjson auto ${lib.escapeShellArg (builtins.toJSON gigunPlugins.autoEnable)}";

  sfsymbolsWrapper = pkgs.writeShellScript "sfsymbols" ''
    exec "/Applications/SF Symbols.app/Contents/Executables/sfsymbols" "$@"
  '';
in
{
  xdg.configFile = {
    "ccstatusline".source = mkLink "ccstatusline";
    "mise".source = mkLink "mise";
    # global ignore。programs.git.ignores だと store 経由で nix なしの環境と中身を共有できない
    "git/ignore".source = mkLink "git/ignore";
    # Langfuse の非秘密接続先。鍵は ~/.config/claude-code/langfuse.env に分離する。
    "claude-code/langfuse-endpoints.env".text =
      builtins.readFile ../../../claude/langfuse-endpoints.env;
  }
  // lib.optionalAttrs (!shellLinksManagedByAnsible) {
    "sheldon".source = mkLink "sheldon";
    "zeno".source = mkLink "zeno";
    "zsh/functions".source = mkLink "zsh/functions";
  }
  // lib.optionalAttrs isDarwin {
    "karabiner".source = mkLink "karabiner";
    # Zed keymap (Pattern A: Mac は brew cask zed、Win は DSC で別途 symlink、
    # Linux/WSL は Zed 入れない)
    "zed/keymap.json".source = mkLink "zed/keymap.json";
  };

  # login 専用の PATH 追加も repository を正本にする（既存 .zprofile は HM が退避）。
  home.file.".zprofile".text = builtins.readFile ../../../zsh/.zprofile;

  # agy は plugins.json を読むだけで書き換えない (plugin の install 状態は config.json 側)。
  home.file.".gemini/config/plugins.json".text = builtins.toJSON {
    entries = [
      {
        path = "${config.home.homeDirectory}/ghq/github.com/gigun-dev/claude-code/plugins";
        include_only = lib.subtractLists agyExternalNames agyPlugins;
      }
      {
        path = "${agyExternalPlugins}";
        include_only = lib.intersectLists agyExternalNames agyPlugins;
      }
    ];
  };

  # agy の承認方針を Pro と mini-vm で揃える。always-proceed は terminal コマンドに加えて
  # MCP の tool 呼び出しも確認なしで通す (agy 1.5.x の changelog)。T3 Code の Antigravity
  # セッション (`agy acp`) もこの値に従う。既定の request-review だと REA などの MCP を
  # 呼ぶたびに承認待ちで止まり、T3 から任せた作業が進まない。
  # Why not Auto モード: 安全なコマンドは通すが、MCP の呼び出しは毎回確認する (mini-vm の
  # agy acp で確認)。Why not mcp(...) の許可ルール: 特定の server だけでなく agy 全体を
  # 確認なしで動かしたい。
  # merge の理由は上の Claude settings と同じ: agy も /config の操作で settings.json を
  # 書き直すので、宣言したキーだけを入れ、他のキー (trustedWorkspaces 等) は残す。
  home.activation.configureAgySettings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    AGY_DIR="${config.home.homeDirectory}/.gemini/antigravity-cli"
    SETTINGS_FILE="$AGY_DIR/settings.json"
    SOURCE_FILE="${pkgs.writeText "agy-settings.json" (builtins.toJSON agySettings)}"
    if [ -n "''${DRY_RUN_CMD:-}" ]; then
      echo "would merge declarative agy settings into $SETTINGS_FILE"
    else
      mkdir -p "$AGY_DIR"
      TEMP_FILE="$(mktemp "$AGY_DIR/.settings.json.XXXXXX")"
      if [ -f "$SETTINGS_FILE" ]; then
        MERGE_INPUT=("$SETTINGS_FILE" "$SOURCE_FILE")
      else
        MERGE_INPUT=("$SOURCE_FILE")
      fi
      if ! ${lib.getExe pkgs.jq} -s 'reduce .[] as $x ({}; . * $x)' "''${MERGE_INPUT[@]}" > "$TEMP_FILE"; then
        rm -f "$TEMP_FILE"
        echo "agy settings: merge failed; $SETTINGS_FILE is unchanged" >&2
        exit 1
      fi
      chmod 600 "$TEMP_FILE"
      mv "$TEMP_FILE" "$SETTINGS_FILE"
    fi
  '';

  # launchd-ui: unsigned app — download from GitHub Releases
  # https://github.com/azu/launchd-ui
  home.activation.installLaunchdUI = lib.mkIf isDarwin (
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      app="/Applications/launchd-ui.app"
      if [ ! -d "$app" ]; then
        arch="$(uname -m)"
        if [ "$arch" = "arm64" ]; then slug="aarch64"; else slug="x64"; fi
        url="https://github.com/azu/launchd-ui/releases/latest/download/launchd-ui_''${slug}.app.tar.gz"
        echo "Installing launchd-ui ($slug) ..."
        $DRY_RUN_CMD /usr/bin/curl -fsSL "$url" | /usr/bin/tar xz -C /Applications
        $DRY_RUN_CMD /usr/bin/xattr -cr "$app"
      fi
    ''
  );

  # SF Symbols.app 同梱の CLI (search/export) をエージェントから叩けるようにする。
  # cask 化しない: brew cask の公開版は 8.0 系で、手元に手で入れた 27.x を上書き
  # すると CLI ごと downgrade する恐れがある (2026-09-15 時点で cask 版に CLI が
  # 入っているか未確認)。~/.local/bin 経由にする理由: アプリパスに空白
  # (`SF Symbols.app`) を含み、エージェントが直接パスを叩くと引用符の扱いで壊れる。
  # 実体への直リンクにしない理由は sfsymbolsWrapper のコメント参照。
  home.activation.linkSfSymbolsCLI = lib.mkIf isDarwin (
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      sfsymbols_bin="/Applications/SF Symbols.app/Contents/Executables/sfsymbols"
      sfsymbols_wrapper="${config.home.homeDirectory}/.local/bin/sfsymbols"
      if [ -x "$sfsymbols_bin" ]; then
        $DRY_RUN_CMD mkdir -p "${config.home.homeDirectory}/.local/bin"
        $DRY_RUN_CMD ln -sf "${sfsymbolsWrapper}" "$sfsymbols_wrapper"
      elif [ -e "$sfsymbols_wrapper" ] || [ -L "$sfsymbols_wrapper" ]; then
        # アプリを消した後に、起動できない wrapper が PATH に残らないように掃除
        $DRY_RUN_CMD rm -f "$sfsymbols_wrapper"
      fi
    ''
  );

  # Linux: bash ログイン時に zsh へ exec (chsh 不要で宣言的に zsh デフォルト化)
  # Mac 側は nix-darwin の users.users.${username}.shell = pkgs.zsh で設定済み
  programs.bash = lib.mkIf (!isDarwin) {
    enable = true;
    initExtra = ''
      # Interactive shell で zsh があれば自動で exec
      if [[ $- == *i* && -z "$ZSH_VERSION" && -x "$HOME/.nix-profile/bin/zsh" ]]; then
        exec "$HOME/.nix-profile/bin/zsh" -l
      fi
    '';
  };

  # uv: Python ランタイムを uv 管理に統一 (system python は 3.9 で古い)
  home.activation.installUvPython = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    if command -v uv &>/dev/null; then
      $DRY_RUN_CMD uv python install 3.13 2>/dev/null || true
    fi
  '';

  # uv/tools.txt に宣言した uv tool の未導入分を入れる (bootstrap.sh と同じ uv/sync-tools.sh)。
  # 失敗しても switch は止めない: tool 1 つの PyPI 障害で system 適用全体を巻き戻す理由が無い。
  home.activation.syncUvTools = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    UV_BIN=${pkgs.uv}/bin/uv $DRY_RUN_CMD ${pkgs.bash}/bin/bash "${uvActivationInputs}/sync-tools.sh" || true
  '';

  # uv tool の更新は activation から外し (オフラインで軽く保つ)、週 1 回ここで回す。
  # 失敗は Claude hook と同じ Bark 経路 (bark-notify.sh --job) で知らせ、詳細は uvUpgradeLog に残す。
  # Darwin だけ: mini-vm の uv tool は google-colab-cli 1 つで、Bark の秘密は system の
  # agenix (root 管理) にあり home の unit から読めない。WSL は常時起動していない。
  launchd.agents.uv-tool-upgrade = lib.mkIf isDarwin {
    enable = true;
    config = {
      ProgramArguments = [ "${uvToolUpgrade}" ];
      # 月曜 12:00。寝ていた回は起床時に 1 回だけ走る (launchd が取りこぼしをまとめる)。
      StartCalendarInterval = [
        {
          Weekday = 1;
          Hour = 12;
          Minute = 0;
        }
      ];
      ProcessType = "Background";
      LowPriorityIO = true;
      StandardOutPath = uvUpgradeLog;
      StandardErrorPath = uvUpgradeLog;
    };
  };

  # dotfiles リポの git hooks を有効化。pre-commit は nix fmt 自動適用 (CI fmt 失敗防止)、
  # post-merge/post-rewrite/post-checkout は pull した Nix 構成の自動 switch。
  # core.hooksPath は clone ごとの .git/config にしか入らないので毎 switch で宣言し直す。
  home.activation.installDotfilesHooks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    if [ -d "${dotfilesPath}/.git" ]; then
      $DRY_RUN_CMD chmod +x "${dotfilesPath}/git/hooks/"* 2>/dev/null || true
      $DRY_RUN_CMD ${pkgs.git}/bin/git -C "${dotfilesPath}" config --local core.hooksPath git/hooks
    fi
  '';

  # zsh/functions の permission を 755 に固定 (compinit insecure 対策)
  # 777 (world-writable) だと compinit が insecure 判定で全補完スキップになる。
  # git は permission を完全管理できないので home-manager apply 時に毎回修正。
  home.activation.fixZshFnPerms = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    if [ -d "${dotfilesPath}/zsh/functions" ]; then
      $DRY_RUN_CMD chmod -R go-w "${dotfilesPath}/zsh/functions" 2>/dev/null || true
    fi
  '';

  # 古い compdump tempfile 残骸を掃除 (compinit が atomic rename 直前で kill
  # された場合に残る .zcompdump.HOST.local.<pid>)。compinit 自体は interactive
  # shell の zsh-defer に委譲し、activation では残骸の掃除だけを行う。
  home.activation.cleanCompdumpStale = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    $DRY_RUN_CMD ${pkgs.findutils}/bin/find "${config.home.homeDirectory}" -maxdepth 1 \
      \( -name '.zcompdump.*.local.*' -o -name '.zcompdump-*' \) \
      -mtime +1 -delete 2>/dev/null || true
  '';

  # claude/settings.json を正本として ~/.claude/settings.json へ deep merge する
  # (ryoppippi/dotfiles の claude-code module / t3code module と同じ方式)。
  # symlink にしない理由: Claude Code は /plugin や /model などの操作のたびに atomic rename で
  # settings.json を書き直すので、repo への symlink は通常ファイルに置換されて次回 switch で壊れる。
  # コピーだけでも UI/CLI が足したキーを switch が消してしまう。
  # merge なら宣言したキーが勝ち、宣言していないキーと書き込みは残る。object (enabledPlugins 等) は
  # キー単位で merge、配列 (permissions.allow, hooks 等) は正本のもので丸ごと置き換わる。
  # 宣言から消したキーは live から自動では消えない。消すときは live も手で直す
  # (gigun plugin だけは下の claudeGigunFilter が marketplace に合わせて足し引きする)。
  # schema 検証 (check-jsonschema) は $schema の取得にネットワークが要り、同梱するとスキーマが
  # 古びて誤検知するため入れず、JSON として壊れていないことだけ確認する。
  # Linux / mini-vm は Mac 固有のpermissions・hooks・proseを除き、plugin宣言とmarketplaceだけを
  # 同じ正本から導出する。これにより端末固有設定を持ち込まずpluginの導入状態を揃える。
  home.activation.configureClaudeSettings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    CLAUDE_DIR="${config.home.homeDirectory}/.claude"
    SETTINGS_FILE="$CLAUDE_DIR/settings.json"
    SOURCE_FILE="${claudeSettingsSource}"
    if [ -n "''${DRY_RUN_CMD:-}" ]; then
      echo "would merge declarative Claude settings into $SETTINGS_FILE"
    else
      mkdir -p "$CLAUDE_DIR"
      if [ -L "$SETTINGS_FILE" ]; then
        # 旧運用の symlink は実体の内容を引き継いで通常ファイルにする
        LINK_COPY="$(mktemp "$CLAUDE_DIR/.settings.json.XXXXXX")"
        cp "$SETTINGS_FILE" "$LINK_COPY" && mv "$LINK_COPY" "$SETTINGS_FILE" || rm -f "$LINK_COPY"
      fi
      if [ -f "$SETTINGS_FILE" ]; then
        TEMP_FILE="$(mktemp "$CLAUDE_DIR/.settings.json.XXXXXX")"
        if ! ${lib.getExe pkgs.jq} -s '.[0] * .[1]' "$SETTINGS_FILE" "$SOURCE_FILE" \
          | ${lib.getExe pkgs.jq} ${gigunJqArgs} -f ${claudeGigunFilter} > "$TEMP_FILE"; then
          rm -f "$TEMP_FILE"
          echo "claude settings: merge failed; $SETTINGS_FILE is unchanged" >&2
          exit 1
        fi
        chmod 600 "$TEMP_FILE"
        mv "$TEMP_FILE" "$SETTINGS_FILE"
      else
        TEMP_FILE="$(mktemp "$CLAUDE_DIR/.settings.json.XXXXXX")"
        if ! ${lib.getExe pkgs.jq} ${gigunJqArgs} -f ${claudeGigunFilter} "$SOURCE_FILE" > "$TEMP_FILE"; then
          rm -f "$TEMP_FILE"
          echo "claude settings: initialization failed; $SETTINGS_FILE was not created" >&2
          exit 1
        fi
        chmod 600 "$TEMP_FILE"
        mv "$TEMP_FILE" "$SETTINGS_FILE"
      fi
    fi
  '';

  # enabledPlugins から落とすだけでは install の記録が残り、Claude は cache を孤立扱い
  # (.orphaned_at、14 日後に削除) にしない。2026-11-13 に移行した 11 個の cache が残った。
  # marketplace に無い @gigun の記録は uninstall する。失敗は switch を止めず警告にする。
  home.activation.uninstallStaleClaudeGigunPlugins =
    lib.hm.dag.entryAfter [ "configureClaudeSettings" ]
      ''
        INSTALLED="${config.home.homeDirectory}/.claude/plugins/installed_plugins.json"
        if [ -f "$INSTALLED" ]; then
          for plugin in $(${lib.getExe pkgs.jq} -r ${gigunJqArgs} \
            '.plugins // {} | keys[] | select(endswith("@gigun")) | select((rtrimstr("@gigun")) as $n | $names | any(. == $n) | not)' \
            "$INSTALLED"); do
            $DRY_RUN_CMD ${lib.getExe pkgs.claude-code} plugin uninstall "$plugin" >/dev/null \
              || echo "claude: $plugin を uninstall できなかった" >&2
          done
        fi
      '';

  # .zshrc は programs.zsh が管理するため home.file ではなく
  # home.activation で強制シンボリックリンク (ryoppippi パターン)
  home.activation.linkDotfiles = lib.hm.dag.entryAfter [ "linkGeneration" ] (''
    link_force() {
      local src="$1" dst="$2"
      [ -L "$dst" ] && rm "$dst"
      [ -e "$dst" ] && mv "$dst" "$dst.backup"
      ln -sf "$src" "$dst"
    }
    ${lib.optionalString (!shellLinksManagedByAnsible) ''
      link_force "${dotfilesPath}/zsh/.zshrc" "${config.home.homeDirectory}/.zshrc"
      link_force "${dotfilesPath}/zsh/.zshenv" "${config.home.homeDirectory}/.zshenv"
    ''}

    # Claude Code (~/.claude/ は memory/log 等があるので個別リンク)
    # 指示の正本は agents/。Claude は AGENTS.md の `@~/.claude/shared/*.md` で断片を読むので、
    # 両方を out-of-store で張り、編集が switch なしで届くようにする。
    $DRY_RUN_CMD mkdir -p "${config.home.homeDirectory}/.claude"
    link_force "${dotfilesPath}/agents/AGENTS.md" "${config.home.homeDirectory}/.claude/CLAUDE.md"
    link_force "${dotfilesPath}/agents/shared" "${config.home.homeDirectory}/.claude/shared"
    # Codex には import が無いので断片を連結した生成物を置く (agents/codex-agents-md.sh)。
    # 生成物なので symlink でなく実ファイル。断片の編集は次の switch で届く。
    $DRY_RUN_CMD mkdir -p "${config.home.homeDirectory}/.codex"
    if [ -L "${config.home.homeDirectory}/.codex/AGENTS.md" ]; then
      $DRY_RUN_CMD rm "${config.home.homeDirectory}/.codex/AGENTS.md"
    fi
    $DRY_RUN_CMD install -m 644 "${codexAgentsMd}" "${config.home.homeDirectory}/.codex/AGENTS.md"
    # settings.json は下の configureClaudeSettings が merge する (symlink にはしない)。
    link_force "${dotfilesPath}/claude/hooks" "${config.home.homeDirectory}/.claude/hooks"
    link_force "${dotfilesPath}/claude/commands" "${config.home.homeDirectory}/.claude/commands"
    # カスタム subagent は 2026-11-08 に廃止した (agents/shared/delegate-work.md)。
    # 以前 claude/agents へ張っていた symlink はリンク先が消えて宙吊りになるので外す。
    # 別の中身を指すもの (手で置いた定義) には触らない。
    if [ "$(readlink "${config.home.homeDirectory}/.claude/agents" 2>/dev/null)" = "${dotfilesPath}/claude/agents" ]; then
      $DRY_RUN_CMD rm "${config.home.homeDirectory}/.claude/agents"
    fi
  '');

  # iTerm2 plist の同期は system.defaults.CustomUserPreferences."com.googlecode.iterm2"
  # で `LoadPrefsFromCustomFolder = true` + `PrefsCustomFolder = repo path` を宣言済み。
  # iTerm2 自身が repo 内 plist を source of truth として読み書きするため、
  # 旧 restore-on-missing ロジックは不要 (system.nix を参照)。
}
