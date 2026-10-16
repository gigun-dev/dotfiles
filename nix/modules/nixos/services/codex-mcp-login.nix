# codex の MCP OAuth をスマホの通知から張り直す (ADR 0013)。
#
# Cloudflare の MCP は refresh しても grant がログインから 30 日で切れる。ssh で
# `codex mcp login --no-browser` して callback URL を貼る手順を、Bark 通知のタップ →
# Cloudflare Access → 同意画面 → 完了、に置き換える。実体は scripts/codex-mcp-login.py。
{
  config,
  lib,
  pkgs,
  llmAgents,
  ...
}:
let
  cfg = config.services.codex-mcp-login;
  stateDir = "/var/lib/codex-mcp-login";
  origin = "https://${cfg.hostName}";
  python = pkgs.python3.withPackages (ps: [
    ps.pyjwt
    ps.cryptography # PyJWT の RS256 (Access の JWT) に要る
  ]);
  script = ../../../../scripts/codex-mcp-login.py;
  serverArgs = lib.concatMap (s: [
    "--server"
    s
  ]) cfg.servers;

  # ssh からの手動ログイン (callback URL を貼る従来手順) でも最終ログイン時刻を残す。
  # 記録が無いとリマインダが「記録なし」で毎朝鳴り続ける。
  relogin = pkgs.writeShellScriptBin "codex-mcp-relogin" ''
    set -eu
    server=''${1:-${lib.head cfg.servers}}
    [ "$#" -eq 0 ] || shift
    ${llmAgents.codex}/bin/codex mcp login "$server" --no-browser \
      -c 'mcp_oauth_credentials_store="file"' "$@"
    exec ${python}/bin/python3 ${script} record --state-dir ${stateDir} "$server"
  '';
in
{
  options.services.codex-mcp-login = {
    enable = lib.mkEnableOption "codex MCP OAuth の再ログイン入口とリマインダ";
    user = lib.mkOption {
      type = lib.types.str;
      description = "codex の ~/.codex を持つユーザー。login はこのユーザーで走る。";
    };
    hostName = lib.mkOption {
      type = lib.types.str;
      description = "named tunnel と Cloudflare Access に載せる公開ホスト名。";
    };
    servers = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      default = [ "cloudflare" ];
      description = "ログインから ttlDays で切れる MCP server。先頭が /start の既定。";
    };
    ttlDays = lib.mkOption {
      type = lib.types.ints.positive;
      # cloudflare/mcp の refreshTokenTTL (2592000 秒)。refresh では延びない。
      default = 30;
    };
    remindAfterDays = lib.mkOption {
      type = lib.types.ints.positive;
      # 毎朝 1 回、失効前に 3 回鳴る。1 回見逃しても間に合う。
      default = 27;
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 18790;
      description = "入口が 127.0.0.1 で待ち受けるポート (cloudflared の ingress 先)。";
    };
    callbackPort = lib.mkOption {
      type = lib.types.port;
      default = 18791;
      description = "codex の callback listener の固定ポート。入口だけが loopback で叩く。";
    };
    accessTeamDomain = lib.mkOption {
      type = lib.types.str;
      example = "https://gigun.cloudflareaccess.com";
    };
    accessAud = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Access アプリの AUD tag。null なら team の署名・iss・exp だけを見る
        (同じ team の他アプリの JWT も通る。どれも同じ account member ポリシー)。
      '';
    };
    notifier = lib.mkOption {
      type = lib.types.str;
      description = "Bark helper。引数は <unit> <title> <本文ファイル> <タップで開く URL>。";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d ${stateDir} 0750 ${cfg.user} users -" ];

    environment.systemPackages = [ relogin ];

    # **codex は callback URL が loopback でないと listener を 0.0.0.0 に bind する**
    # (rmcp-client perform_oauth_login.rs の callback_bind_host、0.163.0)。
    # nixos-fw より前に tailscaled の ts-input が tailscale0 を丸ごと ACCEPT するので、
    # filter 表の規則では tailnet から届いてしまう。raw 表の PREROUTING で loopback 以外を落とす。
    # raw 表は NixOS の firewall が flush しないので、専用 chain を作り直して重複を避ける。
    # ip46tables を使わないのは、-C の判定が ip6tables 側の結果だけになり v4 に二重に挿すため。
    networking.firewall.extraCommands = ''
      for ipt in iptables ip6tables; do
        $ipt -w -t raw -N codex-mcp-callback 2>/dev/null || true
        $ipt -w -t raw -F codex-mcp-callback
        $ipt -w -t raw -A codex-mcp-callback -p tcp --dport ${toString cfg.callbackPort} ! -i lo -j DROP
        $ipt -w -t raw -C PREROUTING -j codex-mcp-callback 2>/dev/null \
          || $ipt -w -t raw -I PREROUTING -j codex-mcp-callback
      done
    '';
    networking.firewall.extraStopCommands = ''
      for ipt in iptables ip6tables; do
        $ipt -w -t raw -D PREROUTING -j codex-mcp-callback 2>/dev/null || true
        $ipt -w -t raw -F codex-mcp-callback 2>/dev/null || true
        $ipt -w -t raw -X codex-mcp-callback 2>/dev/null || true
      done
    '';

    systemd.services.codex-mcp-login = {
      description = "codex MCP OAuth の再ログイン入口 (Cloudflare Access の裏)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      unitConfig.OnFailure = [ "codex-mcp-login-notify-failure.service" ];
      environment = {
        HOME = "/home/${cfg.user}";
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      };
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        WorkingDirectory = "/home/${cfg.user}";
        ExecStart = lib.escapeShellArgs (
          [
            "${python}/bin/python3"
            script
            "serve"
            "--codex"
            "${llmAgents.codex}/bin/codex"
            "--port"
            (toString cfg.port)
            "--callback-port"
            (toString cfg.callbackPort)
            "--origin"
            origin
            "--access-team"
            cfg.accessTeamDomain
            "--access-aud"
            (if cfg.accessAud == null then "" else cfg.accessAud)
            "--state-dir"
            stateDir
          ]
          ++ serverArgs
        );
        Restart = "always";
        RestartSec = 10;
        NoNewPrivileges = true;
      };
    };

    # 毎時見る。拒否 (= もう使えない) は気づいた回に、日数の催促は 9 時以降に、
    # どちらも server ごとに 1 日 1 通まで (判定は scripts/codex-mcp-login.py の should_send)。
    systemd.services.codex-mcp-login-remind = {
      description = "codex MCP OAuth の失効前・失効後に再ログインを促す";
      serviceConfig = {
        Type = "oneshot";
        # journal と bark-env (root 0400) を読むので root。
        User = "root";
        EnvironmentFile = "-/run/agenix/bark-env";
        ExecStart = lib.escapeShellArgs (
          [
            "${python}/bin/python3"
            script
            "remind"
            "--state-dir"
            stateDir
            "--origin"
            origin
            "--notifier"
            cfg.notifier
            "--notify-unit"
            "codex-mcp-login-remind.service"
            "--journalctl"
            "${config.systemd.package}/bin/journalctl"
            "--ttl-days"
            (toString cfg.ttlDays)
            "--remind-after-days"
            (toString cfg.remindAfterDays)
          ]
          ++ serverArgs
        );
      };
    };

    systemd.timers.codex-mcp-login-remind = {
      description = "codex-mcp-login-remind を毎時回す";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* *:07:00";
        Persistent = true;
      };
    };

    systemd.services.codex-mcp-login-notify-failure = {
      description = "codex-mcp-login の起動失敗を Bark へ通知する";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        EnvironmentFile = "-/run/agenix/bark-env";
        ExecStart = "${cfg.notifier} codex-mcp-login.service 'mini-vm MCP ログイン入口 起動失敗'";
      };
    };
  };
}
