# Bounded ripgrep / PCRE2 trial

Build PCRE2 10.49 from the pinned official formula, then verify its bottle on a separate Intel macOS15 runner with official ripgrep15.2.0 Sonoma bottle. No Rust build, schedule, update PR, publication or normal host selection. Existing fzf policy/recipe are unchanged.

Reuses fzf prepare-ci with the same core revision. Formula hashes pin source checksums and bottle metadata. Standard Homebrew verifies downloads. Jobs cap build15min/verify10min with two make jobs. Default preflight is read-only. Local mutation requires --execute and empty target packages; a local core must already match the pin (never automatically repinned). Only disposable hosted CI may replace preinstalled target packages. No unrelated cleanup/upgrade.

Usage: recipe.sh preflight; recipe.sh build WORK --execute; recipe.sh verify WORK --execute. The branch-only push trigger allows initial draft validation before merge and is not a package-update schedule. Artifacts retained14days. Normal mini rg remains Nix-managed pending isolated results.
