{ pkgs }:
let
  ensureIdentity = pkgs.writeShellApplication {
    name = "ensure-sops-host-identity";
    runtimeInputs = [
      pkgs.age
      pkgs.coreutils
    ];
    text = builtins.readFile ../../scripts/ensure-sops-host-identity.sh;
  };
in
pkgs.runCommand "sops-host-identity-tests"
  {
    nativeBuildInputs = [
      ensureIdentity
      pkgs.age
      pkgs.coreutils
    ];
  }
  ''
    root="$TMPDIR/state"
    identity="$root/key.txt"

    ensure-sops-host-identity "$identity"
    test -f "$identity"
    test ! -L "$identity"
    test "$(stat -c %a "$identity")" = 600
    test "$(stat -c %u "$identity")" = "$(id -u)"
    age-keygen -y "$identity" >/dev/null

    before=$(sha256sum "$identity")
    ensure-sops-host-identity "$identity"
    test "$before" = "$(sha256sum "$identity")"

    mv "$identity" "$root/target"
    ln -s "$root/target" "$identity"
    if ensure-sops-host-identity "$identity"; then
      echo "symlink identity was accepted" >&2
      exit 1
    fi
    rm "$identity"

    install -m 0644 "$root/target" "$identity"
    if ensure-sops-host-identity "$identity"; then
      echo "unsafe identity mode was accepted" >&2
      exit 1
    fi

    touch "$out"
  ''
