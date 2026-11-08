{
  config,
  pkgs,
  lib,
  shellLinksManagedByAnsible ? false,
  ...
}:
let
  dotfilesPath = "${config.home.homeDirectory}/ghq/github.com/gigun-dev/dotfiles";
  mkLink = path: config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/${path}";
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
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

  # SF Symbols の CLI は自分の実行ファイルパスから親の .app を遡ってリソース
  # (Contents/Resources) を読むため、bundle の外へ symlink を張ると
  # "could not find an SF Symbols.app to load resources from" で落ちる。
  # exec で実体パスを叩けば argv[0] が bundle 内に戻るので、中身のある wrapper
  # を挟む (リンク先そのものは store で構わない)。
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
  # 宣言から消したキーは live から自動では消えない。消すときは live も手で直す。
  # schema 検証 (check-jsonschema) は $schema の取得にネットワークが要り、同梱するとスキーマが
  # 古びて誤検知するため入れず、JSON として壊れていないことだけ確認する。
  # home 層は WSL / mini-vm と共有で、正本には Mac 固有のパスが含まれるため Darwin 限定。
  home.activation.configureClaudeSettings = lib.mkIf isDarwin (
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      CLAUDE_DIR="${config.home.homeDirectory}/.claude"
      SETTINGS_FILE="$CLAUDE_DIR/settings.json"
      SOURCE_FILE="${../../../claude/settings.json}"
      $DRY_RUN_CMD mkdir -p "$CLAUDE_DIR"
      if [ -L "$SETTINGS_FILE" ]; then
        # 旧運用の symlink は実体の内容を引き継いで通常ファイルにする
        LINK_COPY="$(mktemp "$CLAUDE_DIR/.settings.json.XXXXXX")"
        cp "$SETTINGS_FILE" "$LINK_COPY" && $DRY_RUN_CMD mv "$LINK_COPY" "$SETTINGS_FILE" || rm -f "$LINK_COPY"
      fi
      if [ -f "$SETTINGS_FILE" ]; then
        TEMP_FILE="$(mktemp "$CLAUDE_DIR/.settings.json.XXXXXX")"
        if ! ${lib.getExe pkgs.jq} -s '.[0] * .[1]' "$SETTINGS_FILE" "$SOURCE_FILE" > "$TEMP_FILE"; then
          rm -f "$TEMP_FILE"
          echo "claude settings: merge failed; $SETTINGS_FILE is unchanged" >&2
          exit 1
        fi
        $DRY_RUN_CMD chmod 644 "$TEMP_FILE"
        $DRY_RUN_CMD mv "$TEMP_FILE" "$SETTINGS_FILE"
      else
        ${lib.getExe pkgs.jq} . "$SOURCE_FILE" > "$SETTINGS_FILE"
        chmod 644 "$SETTINGS_FILE"
      fi
    ''
  );

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
    $DRY_RUN_CMD mkdir -p "${config.home.homeDirectory}/.claude"
    link_force "${dotfilesPath}/claude/CLAUDE.md" "${config.home.homeDirectory}/.claude/CLAUDE.md"
    # Global instructions must survive setup on a new host, not only manual edits.
    $DRY_RUN_CMD mkdir -p "${config.home.homeDirectory}/.codex"
    link_force "${dotfilesPath}/codex/AGENTS.md" "${config.home.homeDirectory}/.codex/AGENTS.md"
    # settings.json は下の configureClaudeSettings が merge する (symlink にはしない)。
    link_force "${dotfilesPath}/claude/hooks" "${config.home.homeDirectory}/.claude/hooks"
    link_force "${dotfilesPath}/claude/commands" "${config.home.homeDirectory}/.claude/commands"
    # 2026-07-12 から手で張られていて、新マシンでは再現しなかった
    link_force "${dotfilesPath}/claude/agents" "${config.home.homeDirectory}/.claude/agents"
  '');

  # iTerm2 plist の同期は system.defaults.CustomUserPreferences."com.googlecode.iterm2"
  # で `LoadPrefsFromCustomFolder = true` + `PrefsCustomFolder = repo path` を宣言済み。
  # iTerm2 自身が repo 内 plist を source of truth として読み書きするため、
  # 旧 restore-on-missing ロジックは不要 (system.nix を参照)。
}
