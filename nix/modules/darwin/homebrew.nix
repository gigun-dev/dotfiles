{ ... }:
{
  homebrew = {
    enable = true;
    onActivation.cleanup = "zap";

    taps = [
      "k1LoW/tap"
      "manaflow-ai/cmux"
    ];

    brews = [
      "cloudflared"
      "k1LoW/tap/mo"
    ];

    casks = [
      "aqua-voice"
      "azookey"
      "claude"
      "cmux"
      "codex"
      "discord"
      "figma"
      "google-chrome"
      "iterm2"
      "karabiner-elements"
      "monitorcontrol"
      "ollama-app"
      "postman"
      "proxyman"
      "slack"
      "tableplus"
      "tailscale-app"
      "zed"
    ];

    masApps = {
    };
  };
}
