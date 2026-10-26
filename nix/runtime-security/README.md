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

## Validation status

- aarch64-darwin: both builds and normal Brotli roundtrip pass.
- x86_64-linux: Bun build and version pass. **Node build succeeds but the
  auto-patched upstream binary segfaults at startup on mini-vm. Do not deploy
  this Node output.** Prefer a source-built standard nixpkgs Node derivation
  with the upstream security source/patch, or a verified upstream package update.
- x86_64-darwin: upstream Node/Bun archives verified by SHA256 and both versions
  run from a temporary directory on mini. This is not yet a Nix package or profile update.

Nixpkgs master f0f1105aaefb617fb766a1edcb77f827d0a1dcb1 still declares
Node 24.21.0 and Bun 1.4.2, as does the pinned unstable revision. Revisit
standard upstream packages before applying this temporary preparation.
