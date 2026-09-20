{ config, pkgs, ... }:
let
  version = "0.19.0";
  hub = pkgs.fetchzip {
    url = "https://github.com/henrygd/beszel/releases/download/v${version}/beszel_linux_amd64.tar.gz";
    hash = "sha256-zJMh4WU3noZnBrxoG+9S2EPDrxxNqN4dbJrssyZdzfI=";
    stripRoot = false;
  };
  agent = pkgs.fetchzip {
    url = "https://github.com/henrygd/beszel/releases/download/v${version}/beszel-agent_linux_amd64_glibc.tar.gz";
    hash = "sha256-HjXZZ4/KxwCBub89Fztb2kyy1TL51wpEO5r15/jt5aA=";
    stripRoot = false;
  };
  environmentFile = config.age.secrets.beszel-env.path;

  waitForHub = pkgs.writeShellScript "beszel-wait-for-hub" ''
    set -eu
    deadline=$(( $(${pkgs.coreutils}/bin/date +%s) + 60 ))
    until ${pkgs.curl}/bin/curl -fsS -o /dev/null http://127.0.0.1:8090/api/beszel/first-run; do
      if [ "$(${pkgs.coreutils}/bin/date +%s)" -ge "$deadline" ]; then
        echo "Beszel Hub did not become ready within 60 seconds" >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/sleep 2
    done
  '';

  bootstrapAgent = pkgs.writeShellScript "beszel-bootstrap-agent" ''
    set -euo pipefail

    state=/var/lib/beszel-agent
    key_file="$state/hub-key.pub"
    token_file="$state/token"
    if [ -s "$key_file" ] && [ -s "$token_file" ]; then
      exit 0
    fi

    auth=$(${pkgs.curl}/bin/curl -fsS \
      -H 'Content-Type: application/json' \
      -d "$(${pkgs.jq}/bin/jq -nc \
        --arg identity "$BESZEL_HUB_USER_EMAIL" \
        --arg password "$BESZEL_HUB_USER_PASSWORD" \
        '{identity:$identity,password:$password}')" \
      http://127.0.0.1:8090/api/collections/users/auth-with-password)
    auth_token=$(printf '%s' "$auth" | ${pkgs.jq}/bin/jq -er .token)
    user_id=$(printf '%s' "$auth" | ${pkgs.jq}/bin/jq -er .record.id)
    hub_key=$(${pkgs.curl}/bin/curl -fsS \
      -H "Authorization: Bearer $auth_token" \
      http://127.0.0.1:8090/api/beszel/info | ${pkgs.jq}/bin/jq -er .key)
    agent_token=$(${pkgs.openssl}/bin/openssl rand -hex 24)

    system=$(${pkgs.curl}/bin/curl -fsS \
      -H "Authorization: Bearer $auth_token" \
      -H 'Content-Type: application/json' \
      -d "$(${pkgs.jq}/bin/jq -nc \
        --arg user "$user_id" \
        --arg key "$hub_key" \
        '{name:"mini-vm",host:"/run/beszel/agent.sock",port:45876,pkey:$key,users:[$user]}')" \
      http://127.0.0.1:8090/api/collections/systems/records)
    system_id=$(printf '%s' "$system" | ${pkgs.jq}/bin/jq -er .id)

    ${pkgs.curl}/bin/curl -fsS \
      -H "Authorization: Bearer $auth_token" \
      -H 'Content-Type: application/json' \
      -d "$(${pkgs.jq}/bin/jq -nc \
        --arg system "$system_id" \
        --arg token "$agent_token" \
        '{system:$system,token:$token}')" \
      http://127.0.0.1:8090/api/collections/fingerprints/records >/dev/null

    ${pkgs.coreutils}/bin/install -m 0400 -o beszel -g beszel /dev/null "$key_file"
    printf '%s\n' "$hub_key" > "$key_file"
    ${pkgs.coreutils}/bin/install -m 0400 -o beszel -g beszel /dev/null "$token_file"
    printf '%s\n' "$agent_token" > "$token_file"
  '';
in
{
  users.groups.beszel = { };
  users.users.beszel = {
    isSystemUser = true;
    group = "beszel";
    extraGroups = [
      "docker"
      "disk"
    ];
  };

  age.secrets.beszel-env = {
    file = ../../../../secrets/beszel-env.age;
    owner = "beszel";
    group = "beszel";
    mode = "0400";
  };

  systemd.services.beszel = {
    description = "Beszel monitoring hub";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      Type = "simple";
      User = "beszel";
      Group = "beszel";
      WorkingDirectory = "/var/lib/beszel";
      StateDirectory = "beszel";
      EnvironmentFile = environmentFile;
      Environment = [
        "APP_URL=https://beszel.097969.xyz"
        "CHECK_UPDATES=false"
        "TRUSTED_AUTH_HEADER=Cf-Access-Authenticated-User-Email"
      ];
      ExecStart = "${hub}/beszel serve --http 127.0.0.1:8090";
      ExecStartPost = waitForHub;
      Restart = "always";
      RestartSec = 5;
    };
  };

  systemd.services.beszel-agent-bootstrap = {
    description = "Register the local Beszel agent";
    requiredBy = [ "beszel-agent.service" ];
    after = [ "beszel.service" ];
    requires = [ "beszel.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      EnvironmentFile = environmentFile;
      StateDirectory = "beszel-agent";
      ExecStart = bootstrapAgent;
    };
  };

  systemd.services.beszel-agent = {
    description = "Beszel monitoring agent";
    wantedBy = [ "multi-user.target" ];
    after = [
      "beszel-agent-bootstrap.service"
      "docker.service"
    ];
    requires = [ "beszel-agent-bootstrap.service" ];
    serviceConfig = {
      Type = "simple";
      User = "beszel";
      Group = "beszel";
      SupplementaryGroups = [
        "docker"
        "disk"
      ];
      StateDirectory = "beszel-agent";
      RuntimeDirectory = "beszel";
      RuntimeDirectoryMode = "0750";
      Environment = [
        "LISTEN=/run/beszel/agent.sock"
        "HUB_URL=http://127.0.0.1:8090"
        "KEY_FILE=/var/lib/beszel-agent/hub-key.pub"
        "TOKEN_FILE=/var/lib/beszel-agent/token"
        "FILESYSTEM=vda2"
      ];
      ExecStart = "${agent}/beszel-agent";
      ExecStartPost = "${agent}/beszel-agent health";
      Restart = "on-failure";
      RestartSec = 5;
      NoNewPrivileges = true;
      ProtectHome = "read-only";
      ProtectSystem = "strict";
      ReadOnlyPaths = [
        "/proc"
        "/sys"
        "/var/run/docker.sock"
      ];
    };
  };
}
