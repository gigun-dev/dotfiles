# Isolated Brotli security runtimes

mini-vm imports these narrowly pinned packages through its system and dedicated
Home Manager output. WSL keeps the shared Linux output. Darwin also selects the patched archives in its ordinary Home Manager
configuration. The root flake.lock is unchanged. Node remains on major 24.

- Darwin: official Node 24.22.1 / Bun 1.4.4 archives fixed by upstream SHA256,
  packaged with the caller's compatible Nix toolchain. Preserve binary signatures
  and V8 executable integrity with dontStrip/dontPatchShebangs.
- Intel Darwin: exact generation-26 nixpkgs revision and NAR hash are pinned in
  intel.nix. Never use current x86_64-darwin nixpkgs for this frozen host.
- Linux Node: unmodified official archive with fixed hash; mini-vm's existing
  nix-ld runs its upstream loader. Auto-patching the ELF segfaulted, while the
  unmodified binary passed startup, child spawning and Brotli checks. No new
  nix-ld setting is introduced. Do not substitute an automatic source build.
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

Pro and Intel profiles have been updated by the owner and passed runtime checks.
mini-vm Node/Bun and Tailscale 1.104.2 were applied using an isolated candidate
based on its running source. Its CLI paths and normal-input
Brotli tests passed. The permanent source must be merged into the autoswitch's
upstream main before a later automatic activation can retain these fixes.

Normal Darwin activation includes Homebrew cleanup and Apple Container actions.
Do not run an older candidate or replace managed profile links by hand.

Already-running and embedded runtimes are not replaced by profile updates.
Review service-specific ownership and restart impact separately. No production
deploy, global switch, or restart is implied by these package definitions.

## Darwin maintenance and Intel boundary

The explicit `gigun-aarch64-darwin-runtime-maintenance` output omits Homebrew
bundle, Apple Container activation, and unrelated app/Python downloads. Ordinary
Darwin outputs retain their normal management behavior and patched runtimes.
The maintenance output uses a pinned nix-darwin internal activation option;
recheck it when changing that input. Signing and access settings are preserved.

Intel remains outside the current main nix-darwin switch workflow because its
architecture is unsupported by current nixpkgs. Its applied temporary candidate
uses the existing frozen toolchain, not a new long-term pin policy. The same
fixed official archives are retained in `intel.nix`; current main must not be
switched onto Intel. Neither a Git update nor the VM autoswitch changes the
Intel system profile. A later supported migration must retain these minimum
runtime versions. Already-running processes are separate from CLI selection.
