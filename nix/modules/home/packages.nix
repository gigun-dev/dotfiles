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
    # codex は OS 分岐: Mac は brew cask (prebuilt 高速)、Linux/WSL は llm-agents.codex
    # Mac Intel で Rust build 走らせると数十分かかる + Nixpkgs 26.05 が x86_64-darwin 最終 EOL のため
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
  ++ lib.optionals (!pkgs.stdenv.isDarwin) [
    llm-agents.codex # Linux/WSL のみ (Mac は brew cask、Rust build を回避)
    zed-editor       # WSL で WSLg 経由起動、開発環境ネイティブアクセス (Mac は brew cask)
  ]
  ++ [

    # Font
    nerd-fonts.jetbrains-mono

    # Editor
    neovim
  ];
}
