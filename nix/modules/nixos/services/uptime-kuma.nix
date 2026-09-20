{ config, pkgs, ... }:
let
  image = "louislam/uptime-kuma:2.5.5@sha256:c74379ac4509ce2d2c2633f509e67003ee2e45b6e995c5e43fc101f45a0e1fbe";
  environmentFile = config.age.secrets.uptime-kuma-env.path;
  python = pkgs.python313.withPackages (ps: [ ps."uptime-kuma-api" ]);
  bootstrap = pkgs.writeText "uptime-kuma-bootstrap.py" ''
    import os
    import time

    from uptime_kuma_api import MonitorType, UptimeKumaApi
    from uptime_kuma_api.api import _check_arguments_monitor, _convert_monitor_input
    from uptime_kuma_api.exceptions import UptimeKumaException

    endpoint = "http://127.0.0.1:3001"
    username = os.environ["UPTIME_KUMA_ADMIN_USER"]
    password = os.environ["UPTIME_KUMA_ADMIN_PASSWORD"]

    api = None
    needs_setup = False
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        try:
            candidate = UptimeKumaApi(endpoint, timeout=10)
            needs_setup = candidate._call("needSetup", ())
            api = candidate
            break
        except Exception:
            time.sleep(2)
    if api is None:
        raise RuntimeError("Uptime Kuma did not become ready within 120 seconds")

    with api:
        # Uptime Kuma 2.x の引数なしSocket.IOイベントは、古いクライアントが
        # nullを1引数として送るとcallback位置がずれるため、空tupleで呼ぶ。
        if needs_setup:
            api.setup(username, password)

        try:
            api.login(username, password)
        except UptimeKumaException:
            # After Cloudflare Access has become the authentication boundary,
            # Uptime Kuma auto-login is the expected path.
            api.login()

        settings = api._call("getSettings", ())["data"]
        if not settings.get("disableAuth") or not settings.get("trustProxy") \
                or settings.get("primaryBaseURL") != "https://uptime.097969.xyz":
            api.set_settings(
                password=password,
                checkUpdate=settings.get("checkUpdate", False),
                checkBeta=settings.get("checkBeta", False),
                keepDataPeriodDays=settings.get("keepDataPeriodDays", 180),
                serverTimezone=settings.get("serverTimezone", "Asia/Tokyo"),
                entryPage=settings.get("entryPage", "dashboard"),
                searchEngineIndex=False,
                primaryBaseURL="https://uptime.097969.xyz",
                steamAPIKey=settings.get("steamAPIKey", ""),
                nscd=settings.get("nscd", False),
                dnsCache=settings.get("dnsCache", False),
                chromeExecutable=settings.get("chromeExecutable", ""),
                tlsExpiryNotifyDays=settings.get("tlsExpiryNotifyDays", [7, 14, 21]),
                disableAuth=True,
                trustProxy=True,
            )

        existing = {monitor["name"]: monitor for monitor in api.get_monitors()}
        desired = {
            "Langfuse": "https://langfuse-otel.097969.xyz/api/public/health?failIfDatabaseUnavailable=true",
            "Codex Proxy": "https://codex.097969.xyz/healthz",
            "Beszel": "http://127.0.0.1:8090/api/beszel/first-run",
        }
        for name, url in desired.items():
            if name in existing:
                if existing[name].get("url") != url:
                    api.edit_monitor(existing[name]["id"], url=url)
            else:
                monitor = api._build_monitor_data(
                    type=MonitorType.HTTP,
                    name=name,
                    url=url,
                    interval=60,
                )
                monitor["conditions"] = []
                _convert_monitor_input(monitor)
                _check_arguments_monitor(monitor)
                api._call("add", monitor)
  '';
in
{
  age.secrets.uptime-kuma-env = {
    file = ../../../../secrets/uptime-kuma-env.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers.uptime-kuma = {
    inherit image;
    environment = {
      UPTIME_KUMA_DB_TYPE = "sqlite";
    };
    volumes = [ "/var/lib/uptime-kuma:/app/data" ];
    extraOptions = [
      "--network=host"
      "--security-opt=no-new-privileges:true"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/uptime-kuma 0750 root root -"
  ];

  systemd.services.uptime-kuma-bootstrap = {
    description = "Configure Uptime Kuma for Cloudflare Access";
    wantedBy = [ "multi-user.target" ];
    after = [ "docker-uptime-kuma.service" ];
    requires = [ "docker-uptime-kuma.service" ];
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = environmentFile;
      ExecStart = "${python}/bin/python ${bootstrap}";
    };
  };
}
