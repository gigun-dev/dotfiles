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
      "android-studio"
      "aqua-voice"
      "azookey"
      "claude"
      "cmux"
    ]
    ++ lib.optionals (!isAarch64) [
      "codex" # Intel Mac のみ brew cask (Rust build 回避)。aarch64 + Linux は packages.nix で nix install
    ]
    ++ [
      "discord"
      "figma"
      "fiji" # ImageJ ディストリ (Fiji Is Just ImageJ)。ARM ネイティブ。素の imagej cask は Gatekeeper 不通過で deprecated のため不採用
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
