{
  config,
  pkgs,
  lib,
  ...
}:
let
  dotfilesPath = "${config.home.homeDirectory}/ghq/github.com/gigun-dev/dotfiles";
  mkLink = path: config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/${path}";
  isDarwin = pkgs.stdenv.isDarwin;
in
{
  xdg.configFile = {
    "sheldon".source = mkLink "sheldon";
    "zeno".source = mkLink "zeno";
    "zsh/functions".source = mkLink "zsh/functions";
    "ccstatusline".source = mkLink "ccstatusline";
    "mise".source = mkLink "mise";
  }
  // lib.optionalAttrs isDarwin {
    "karabiner".source = mkLink "karabiner";
    # Zed keymap (Pattern A: Mac は brew cask zed、Win は DSC で別途 symlink、
    # Linux/WSL は Zed 入れない)
    "zed/keymap.json".source = mkLink "zed/keymap.json";
  };

  # NotchBar: 開発ビルドをログイン時に自動起動 (darwin only)
  launchd.agents = lib.optionalAttrs isDarwin {
    notchbar = {
      enable = true;
      config = {
        Label = "com.github.gigun-dev.NotchBar";
        Program = "${config.home.homeDirectory}/ghq/github.com/gigun-dev/notchbar/.build/debug/NotchBar";
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "/tmp/notchbar.log";
        StandardErrorPath = "/tmp/notchbar.log";
      };
    };
  };

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

  # dotfiles リポの git pre-commit hook を有効化 (nix fmt 自動適用、CI fmt 失敗防止)
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
  # shell の zsh-defer に委譲する (非対話 zsh でも compdump 内 $(typeset +fm)
  # の SIGCHLD race を踏むため activation で warm すると hook が固まる)。
  home.activation.cleanCompdumpStale = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    $DRY_RUN_CMD ${pkgs.findutils}/bin/find "${config.home.homeDirectory}" -maxdepth 1 \
      \( -name '.zcompdump.*.local.*' -o -name '.zcompdump-*' \) \
      -mtime +1 -delete 2>/dev/null || true
  '';

  # .zshrc は programs.zsh が管理するため home.file ではなく
  # home.activation で強制シンボリックリンク (ryoppippi パターン)
  home.activation.linkDotfiles = lib.hm.dag.entryAfter [ "linkGeneration" ] (
    ''
      link_force() {
        local src="$1" dst="$2"
        [ -L "$dst" ] && rm "$dst"
        [ -e "$dst" ] && mv "$dst" "$dst.backup"
        ln -sf "$src" "$dst"
      }
      link_force "${dotfilesPath}/zsh/.zshrc" "${config.home.homeDirectory}/.zshrc"

      # Claude Code (~/.claude/ は memory/log 等があるので個別リンク)
      $DRY_RUN_CMD mkdir -p "${config.home.homeDirectory}/.claude"
      link_force "${dotfilesPath}/claude/settings.json" "${config.home.homeDirectory}/.claude/settings.json"
      link_force "${dotfilesPath}/claude/hooks" "${config.home.homeDirectory}/.claude/hooks"
      link_force "${dotfilesPath}/claude/commands" "${config.home.homeDirectory}/.claude/commands"
      link_force "${dotfilesPath}/claude/skills" "${config.home.homeDirectory}/.claude/skills"

      # agent-browser (~/.agent-browser/ は browsers/sessions 等があるので config のみ)
      $DRY_RUN_CMD mkdir -p "${config.home.homeDirectory}/.agent-browser"
      link_force "${dotfilesPath}/agent-browser/config.json" "${config.home.homeDirectory}/.agent-browser/config.json"
    ''
    + lib.optionalString isDarwin ''

      # iTerm2 plist リストア
      # brew zap で plist が消えた場合、dotfiles のバックアップから復元する
      # バックアップは手動で `cp ~/Library/Preferences/com.googlecode.iterm2.plist iterm2/` する
      # (自動バックアップするとウィンドウ位置等の一時的な差分が混入するため)
      iterm_plist="${config.home.homeDirectory}/Library/Preferences/com.googlecode.iterm2.plist"
      iterm_backup="${dotfilesPath}/iterm2/com.googlecode.iterm2.plist"
      if [ ! -f "$iterm_plist" ] && [ -f "$iterm_backup" ]; then
        echo "Restoring iTerm2 plist from dotfiles backup..."
        $DRY_RUN_CMD cp "$iterm_backup" "$iterm_plist"
      fi
    ''
  );
}
