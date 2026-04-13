{
  config,
  pkgs,
  lib,
  ...
}:
{
  home.packages = with pkgs; [
    # JS / Python runtime
    nodejs
    bun
    deno
    pnpm
    uv

    # AI
    claude-code # ← claude-code-overlay (ryoppippi)
    # codex は brew cask で管理（Rust ビルドが重いため）
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
    sheldon
    vivid

    # Dev
    cocoapods
    mise
    ffmpeg

    # Font
    nerd-fonts.jetbrains-mono

    # Editor
    neovim
  ];
}
