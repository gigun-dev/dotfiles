# Isolated Brotli security runtimes

Preparation packages only: no imports from the main flake, host activation or
profile changes. The root flake.lock is unchanged. Node remains on major 24.

- Darwin: official Node 24.22.1 / Bun 1.4.4 archives fixed by upstream SHA256,
  packaged with the caller's compatible Nix toolchain. Preserve binary signatures
  and V8 executable integrity with dontStrip/dontPatchShebangs.
- Intel Darwin: exact generation-26 nixpkgs revision and NAR hash are pinned in
  intel.nix. Never use current x86_64-darwin nixpkgs for this frozen host.
- Linux Node: standard nixpkgs source derivation using official Node 24.22.1
  source. The bundled fixed Brotli is compiled instead of the older shared
  library. The standard Node wrapper retains npm/corepack. Auto-patching the
  official upstream Linux ELF segfaulted even without stripping and is excluded.
- Linux Bun: official baseline archive, fixed hash, standard autoPatchelf hook.

Build on the matching architecture:

```sh
nix build path:./nix/runtime-security#node path:./nix/runtime-security#bun --no-link --print-out-paths
```

Verify each returned runtime using `verify-runtime.mjs`. It checks normal-input
sync/async Brotli and localhost HTTP response decoding; it contains no exploit
input or external request. Bun's `process.versions.node` is a compatibility
identifier, not the separately installed Node version.

Nixpkgs unstable 674a2028661e550a97400c1cc992b9cca9a668a1 and master
f0f1105aaefb617fb766a1edcb77f827d0a1dcb1 still declare Node 24.21.0 and Bun 1.4.2.
Prefer verified standard package updates once upstream incorporates the fix.

## Validation and application boundary

Pro and Intel isolated packages build and pass runtime checks. Linux Bun builds
and starts; Linux Node source build is pending final native execution validation
at the time of this document. Do not equate build preparation with remediation.

A separate Pro candidate branch is based on an exactly reproduced running
snapshot and changes only Node/Bun. Its normal activation still runs existing
Homebrew cleanup and Apple Container operations, so application is held.
The mini-vm Home Manager candidate has identical home files and user services;
its activation changes only the package-profile target. It awaits the source
Node build/runtime validation.

Already-running and embedded runtimes are not replaced by profile updates.
Review service-specific ownership and restart impact separately. No production
deploy, global switch, or restart is implied by these package definitions.
