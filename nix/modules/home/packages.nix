{
  config,
  pkgs,
  lib,
  ...
}:
{
  home.packages =
    with pkgs;
    [
      # JS / Python runtime
      nodejs
      bun
      # deno は nixpkgs だと rusty-v8 フルビルドで重いため mise に移譲
      pnpm
      uv

      # AI
      claude-code # ← claude-code-overlay (ryoppippi)
      llm-agents.opencode
      llm-agents.ccstatusline
      llm-agents.agent-browser

      # Git
      gh
      ghq

      # Search / files
      ripgrep
      fd
      fzf
      eza
      bat
      zoxide
      jq

      # Shell
      zsh
      sheldon
      vivid

      # Dev
      mise
      ffmpeg
    ]
    ++ lib.optionals pkgs.stdenv.isDarwin [
      cocoapods # iOS 開発 — darwin 限定
    ]
    ++ lib.optionals (!(pkgs.stdenv.isDarwin && pkgs.stdenv.isx86_64)) [
      llm-agents.codex # Intel Mac のみ brew cask (Rust build 回避)、それ以外は nix
    ]
    ++ [

      # Font
      nerd-fonts.jetbrains-mono

      # Editor
      neovim
    ];
}
