{ pkgs, inputs }:
let
  installSecrets = inputs.sops-nix.packages.${pkgs.system}.sops-install-secrets;
in
pkgs.runCommand "sops-host-delivery"
  {
    nativeBuildInputs = [
      pkgs.age
      pkgs.jq
      pkgs.sops
      installSecrets
    ];
  }
  ''
    set -eu
    root="$TMPDIR/fixture"
    mkdir -p "$root/plain" "$root/encrypted" "$root/run"
    age-keygen -o "$root/identity" 2> "$root/age-keygen.log"
    recipient=$(age-keygen -y "$root/identity")

    printf '%s\n' local-fixture-current > "$root/plain/current"
    printf '%s\n' local-fixture-next > "$root/plain/next"
    sops --encrypt --age "$recipient" --input-type binary --output-type binary \
      "$root/plain/current" > "$root/encrypted/current.sops"
    sops --encrypt --age "$recipient" --input-type binary --output-type binary \
      "$root/plain/next" > "$root/encrypted/next.sops"

    jq -n \
      --arg current "$root/encrypted/current.sops" \
      --arg next "$root/encrypted/next.sops" \
      --arg identity "$root/identity" \
      --arg mount "$root/run/secrets.d" \
      --arg link "$root/run/secrets" \
      '{
        secrets: [
          {name: "host-heartbeat-vm-current", key: "", path: ($link + "/host-heartbeat-vm-current"), uid: 0, gid: 0, sopsFile: $current, format: "binary", mode: "0400", restartUnits: [], reloadUnits: []},
          {name: "host-heartbeat-vm-next", key: "", path: ($link + "/host-heartbeat-vm-next"), uid: 0, gid: 0, sopsFile: $next, format: "binary", mode: "0400", restartUnits: [], reloadUnits: []}
        ],
        templates: [], placeholderBySecretName: {}, secretsMountPoint: $mount,
        symlinkPath: $link, keepGenerations: 1, sshKeyPaths: [], gnupgHome: "",
        ageKeyFile: $identity, ageSshKeyFile: "", ageSshKeyCmd: "",
        ageSshKeyPaths: [], useTmpfs: false, userMode: true,
        logging: {keyImport: false, secretChanges: false}
      }' > "$root/manifest.json"

    sops-install-secrets --ignore-passwd "$root/manifest.json"
    test "$(cat "$root/run/secrets/host-heartbeat-vm-current")" = local-fixture-current
    test "$(cat "$root/run/secrets/host-heartbeat-vm-next")" = local-fixture-next
    test "$(stat -c %a "$root/run/secrets/host-heartbeat-vm-current")" = 400
    test "$(stat -c %a "$root/run/secrets/host-heartbeat-vm-next")" = 400
    test -L "$root/run/secrets"
    test ! -L "$root/run/secrets/host-heartbeat-vm-current"
    test ! -L "$root/run/secrets/host-heartbeat-vm-next"
    touch "$out"
  ''
