{
  config,
  pkgs,
  ...
}:
let
  username = "gigun";
  dotfilesDir = "/home/${username}/ghq/github.com/gigun-dev/dotfiles";
  composeSource = ../../../../infra/langfuse/compose.yaml;
  composeFile = "/etc/langfuse/compose.yaml";
  environmentFile = config.age.secrets.langfuse-env.path;

  waitUntilReady = pkgs.writeShellScript "langfuse-wait-until-ready" ''
    set -eu
    deadline=$(( $(date +%s) + 600 ))
    until ${pkgs.curl}/bin/curl -fsS -o /dev/null http://127.0.0.1:3000/api/public/ready; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "Langfuse did not become ready within 10 minutes" >&2
        ${pkgs.docker-compose}/bin/docker-compose \
          --env-file ${environmentFile} -p langfuse -f ${composeFile} ps >&2 || true
        exit 1
      fi
      sleep 10
    done
  '';

  proposeUpdate = pkgs.writeShellScript "langfuse-update-propose" ''
        set -eu
        set -o pipefail

        state=''${STATE_DIRECTORY:-/var/lib/langfuse-update-trial}
        trial="$state/worktree"
        branch="auto/langfuse-v4"
        source_compose=${dotfilesDir}/infra/langfuse/compose.yaml
        cutoff=$(( $(date +%s) - 7 * 24 * 60 * 60 ))

        release=$(${pkgs.curl}/bin/curl -fsSL \
          'https://api.github.com/repos/langfuse/langfuse/releases?per_page=100' \
          | ${pkgs.jq}/bin/jq -r --argjson cutoff "$cutoff" \
            '[.[] | select(.draft == false and .prerelease == false)
              | select(.tag_name | test("^v4\\.[0-9]+\\.[0-9]+$"))
              | select((.published_at | fromdateiso8601) <= $cutoff)][0].tag_name // empty')
        [ -n "$release" ] || { echo "7日経過したLangfuse v4 releaseは無い"; exit 0; }
        version=''${release#v}

        current=$(${pkgs.gnused}/bin/sed -nE \
          's#.*docker.langfuse.com/langfuse/langfuse:([^@]+)@.*#\1#p' "$source_compose")
        [ -n "$current" ] || { echo "composeから現在のLangfuse版を読めない" >&2; exit 1; }
        newest=$(
          printf '%s\n%s\n' "$current" "$version" \
            | ${pkgs.coreutils}/bin/sort -V \
            | ${pkgs.coreutils}/bin/tail -n 1
        )
        if [ "$current" = "$version" ] || [ "$newest" != "$version" ]; then
          echo "Langfuse $current より新しく、7日経過したv4 releaseは無い"
          exit 0
        fi

        web_digest=$(${pkgs.skopeo}/bin/skopeo inspect --format '{{.Digest}}' \
          "docker://docker.langfuse.com/langfuse/langfuse:$version")
        worker_digest=$(${pkgs.skopeo}/bin/skopeo inspect --format '{{.Digest}}' \
          "docker://docker.langfuse.com/langfuse/langfuse-worker:$version")

        cd ${dotfilesDir}
        git fetch --quiet origin
        rm -rf "$trial"
        git worktree prune
        git worktree add --quiet --detach "$trial" origin/main
        trap 'cd ${dotfilesDir}; git worktree remove --force "$trial" >/dev/null 2>&1 || rm -rf "$trial"' EXIT

        target="$trial/infra/langfuse/compose.yaml"
        ${pkgs.gnused}/bin/sed -i -E \
          "s#(docker.langfuse.com/langfuse/langfuse-worker:)[^@]+@sha256:[a-f0-9]+#\\1$version@$worker_digest#" \
          "$target"
        ${pkgs.gnused}/bin/sed -i -E \
          "s#(docker.langfuse.com/langfuse/langfuse:)[^@]+@sha256:[a-f0-9]+#\\1$version@$web_digest#" \
          "$target"

        ${pkgs.docker-compose}/bin/docker-compose \
          --env-file ${environmentFile} -f "$target" config --quiet

        cd "$trial"
        git add infra/langfuse/compose.yaml
        git commit --quiet -m "chore(langfuse): v$versionへ更新"
        nix build --no-link '.#nixosConfigurations.mini-vm.config.system.build.toplevel'
        git push --quiet --force origin "HEAD:refs/heads/$branch"

        body=$(cat <<EOF
    Langfuse Web / Workerをv$versionへ揃え、manifest digestを固定しました。

    - releaseから7日以上経過
    - Docker Composeの構文検証済み
    - mini-vmのNixOS構成を実機ビルド済み

    major更新はこのレーンの対象外です。
    EOF
        )
        if [ -n "$(gh pr list --head "$branch" --state open --json number --jq '.[].number')" ]; then
          gh pr edit "$branch" --title "chore(langfuse): v$versionへ更新" --body "$body"
        else
          gh pr create --base main --head "$branch" \
            --title "chore(langfuse): v$versionへ更新" --body "$body"
        fi
        if [ "$(gh pr view "$branch" --json autoMergeRequest --jq '.autoMergeRequest // "off"')" = "off" ]; then
          gh pr merge --auto --squash "$branch"
        fi
  '';
in
{
  virtualisation.docker.enable = true;
  environment.systemPackages = [ pkgs.docker-compose ];

  environment.etc."langfuse/compose.yaml".source = composeSource;

  # Cloudflare Access protects one browser origin. Langfuse returns presigned
  # MinIO URLs for media, so route the bucket prefix through that same origin;
  # a separate media hostname would require another Access session.
  services.nginx = {
    enable = true;
    virtualHosts."langfuse-ui-local" = {
      listen = [
        {
          addr = "127.0.0.1";
          port = 13000;
        }
      ];
      locations."/langfuse/" = {
        proxyPass = "http://127.0.0.1:9090";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_set_header Host $host;
        '';
      };
      locations."/" = {
        proxyPass = "http://127.0.0.1:3000";
        proxyWebsockets = true;
      };
    };
    virtualHosts."langfuse-otlp-local" = {
      listen = [
        {
          addr = "127.0.0.1";
          port = 13001;
        }
      ];
      locations."/api/public/otel/" = {
        proxyPass = "http://127.0.0.1:3000";
        extraConfig = ''
          client_max_body_size 25m;
        '';
      };
      # The public OTLP hostname doubles as the external uptime boundary. Keep
      # the surface exact and read-only: these two Langfuse endpoints disclose
      # only readiness, while every other non-OTLP path remains a 404.
      locations."= /api/public/health".proxyPass = "http://127.0.0.1:3000";
      locations."= /api/public/ready".proxyPass = "http://127.0.0.1:3000";
      locations."/".return = "404";
    };
  };

  age.secrets.langfuse-env = {
    file = ../../../../secrets/langfuse-env.age;
    # 更新提案 unit は compose の構文検証だけ gigun として行うため、
    # 平文はリポジトリ所有者だけが読めるようにする。起動 unit は root なので読める。
    owner = username;
    group = "users";
    mode = "0400";
  };

  systemd.services.langfuse = {
    description = "Langfuse v4 observability stack";
    wantedBy = [ "multi-user.target" ];
    requires = [ "docker.service" ];
    after = [
      "docker.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    unitConfig.ConditionPathExists = environmentFile;
    restartTriggers = [ composeSource ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "30min";
      TimeoutStopSec = "10min";
      ExecStartPre = [
        "${pkgs.docker-compose}/bin/docker-compose --env-file ${environmentFile} -p langfuse -f ${composeFile} pull"
      ];
      ExecStart = "${pkgs.docker-compose}/bin/docker-compose --env-file ${environmentFile} -p langfuse -f ${composeFile} up -d --remove-orphans";
      ExecStartPost = [ waitUntilReady ];
      ExecStop = "${pkgs.docker-compose}/bin/docker-compose --env-file ${environmentFile} -p langfuse -f ${composeFile} stop";
    };
  };

  # iPhone and other personal devices reach these endpoints through the tailnet.
  # Docker-published ports are deliberately limited to the web/OTLP API and the
  # S3-compatible media endpoint; databases and the MinIO console stay internal.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    3000
    9090
  ];

  systemd.services.langfuse-update-propose = {
    description = "Langfuse v4の非major更新を検証して自動merge PRを出す";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    unitConfig.ConditionPathExists = "${dotfilesDir}/infra/langfuse/compose.yaml";
    path = with pkgs; [
      git
      openssh
      nix
      gh
      bash
      coreutils
      cacert
    ];
    environment = {
      HOME = "/home/${username}";
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    };
    serviceConfig = {
      Type = "oneshot";
      User = username;
      StateDirectory = "langfuse-update-trial";
      TimeoutStartSec = "90min";
      ExecStart = proposeUpdate;
    };
  };

  systemd.timers.langfuse-update-propose = {
    description = "Langfuse v4更新を毎日確認する";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:00:00";
      RandomizedDelaySec = 1800;
      Persistent = true;
    };
  };
}
