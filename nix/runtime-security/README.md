# Isolated Brotli security runtimes

Preparation only: no imports from the main flake, no activation, no profile changes.
The root flake.lock is unchanged. This separate flake pins build tooling and official
Node 24.22.1 / Bun 1.4.4 archives by upstream SHA256. Nixpkgs at the selected revision
still supplies Node 24.21.0 / Bun 1.4.2, so directly selecting those packages is insufficient.

Build on the matching architecture:

```sh
nix build path:./nix/runtime-security#node path:./nix/runtime-security#bun --no-link --print-out-paths
```

Run the returned absolute store paths for isolated verification. Do not run switch.
Linux outputs require native Linux build/runtime validation before use.
Intel macOS is deliberately excluded from this modern nixpkgs flake. Official
Node darwin-x64 and Bun darwin-x64-baseline archives exist, but an isolated derivation
using the frozen compatible Intel toolchain must be prepared and tested separately.
Never apply the current full nix-darwin configuration to the frozen Intel host.

Application: after approval, select the verified runtimes for explicit jobs only;
review each service's executable path before changing it. Profile replacement alone
will not fix embedded runtimes or already-running processes. No application has yet
been performed by this change.
