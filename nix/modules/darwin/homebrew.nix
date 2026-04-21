{
  pkgs,
  lib,
  ...
}:
let
  isAarch64 = pkgs.stdenv.hostPlatform.isAarch64;
in
{
  homebrew = {
    enable = true;
    onActivation.cleanup = "zap";

    taps = [
      "k1LoW/tap"
      "manaflow-ai/cmux"
    ]
    ++ lib.optionals isAarch64 [
      "rudrankriyam/tap"
    ];

    brews = [
      "cloudflared"
      "k1LoW/tap/mo"
      "tailscale"
    ]
    ++ lib.optionals isAarch64 [
      "rudrankriyam/tap/afm"
    ];

    casks = [
      "aqua-voice"
      "azookey"
      "claude"
      "cmux"
      "codex" # Mac は brew cask (prebuilt、Rust build 回避)。Linux は packages.nix で nix install
      "discord"
      "figma"
      "fork"
      "google-chrome"
      "iterm2"
      "karabiner-elements"
      "monitorcontrol"
      "ollama-app"
      "postman"
      "proxyman"
      "slack"
      "tableplus"
      "zed"
    ];

    masApps = {
    };
  };
}
