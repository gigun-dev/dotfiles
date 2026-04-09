# /pkg — Unified Package Management

Parse `$ARGUMENTS` to determine the subcommand, then spawn a **general-purpose Agent** (subagent) to execute it. This keeps the main context clean.

If `$ARGUMENTS` is empty or unrecognized, show usage help:

```
/pkg add <package-name>    # Add a package
/pkg remove <package-name> # Remove a package
/pkg list                  # List all packages
/pkg switch                # Apply changes manually
```

## Dispatch

Use the Agent tool with `subagent_type: "general-purpose"` for each subcommand. Pass the full prompt below to the agent.

### `add <package-name>`

Spawn agent with this prompt:

> You are a package manager for a dotfiles repository.
>
> **Task**: Add the package `<package-name>`.
>
> **Target files** (absolute paths):
> - Nix packages: `/Users/gigun/ghq/github.com/gigun-dev/dotfiles/nix/modules/home/packages.nix`
> - Homebrew (brews/casks/taps): `/Users/gigun/ghq/github.com/gigun-dev/dotfiles/nix/modules/darwin/system.nix`
>
> **Steps**:
> 1. Run `nix search nixpkgs#<package-name>` to check nixpkgs availability.
> 2. Classify and propose destination using AskUserQuestion:
>    - GUI app (`.app` bundle, desktop application) → propose **cask**
>    - Found in nixpkgs, CLI tool → propose **nix**
>    - Not found in nixpkgs → propose **brew**
>    - Always let the user confirm or override (nix / brew / cask)
> 3. Read the target file, then edit:
>    - **nix**: Add bare attribute name (e.g., `ripgrep`, not `pkgs.ripgrep`) to `home.packages` in the appropriate category section.
>    - **brew**: Add quoted string to the `brews` list.
>    - **cask**: Add quoted string to the `casks` list. Add tap to `taps` if needed.
> 4. Preserve existing comments and category structure.
> 5. Apply: Run `cd /Users/gigun/ghq/github.com/gigun-dev/dotfiles && git add . && nix run .#switch`

### `remove <package-name>`

Spawn agent with this prompt:

> You are a package manager for a dotfiles repository.
>
> **Task**: Remove the package `<package-name>`.
>
> **Target files** (absolute paths):
> - Nix packages: `/Users/gigun/ghq/github.com/gigun-dev/dotfiles/nix/modules/home/packages.nix`
> - Homebrew (brews/casks/taps): `/Users/gigun/ghq/github.com/gigun-dev/dotfiles/nix/modules/darwin/system.nix`
>
> **Steps**:
> 1. Read both files and search for `<package-name>`.
> 2. If found in multiple places, ask the user which one to remove using AskUserQuestion.
> 3. Remove the matching line. Clean up trailing blank lines.
> 4. Apply: Run `cd /Users/gigun/ghq/github.com/gigun-dev/dotfiles && git add . && nix run .#switch`

### `list`

Spawn agent with this prompt:

> You are a package manager for a dotfiles repository.
>
> **Task**: List all managed packages.
>
> **Target files** (absolute paths):
> - Nix packages: `/Users/gigun/ghq/github.com/gigun-dev/dotfiles/nix/modules/home/packages.nix`
> - Homebrew (brews/casks/taps): `/Users/gigun/ghq/github.com/gigun-dev/dotfiles/nix/modules/darwin/system.nix`
>
> **Steps**:
> 1. Read both files.
> 2. Display a categorized summary:
>
> ```
> ## Nix Packages
> <grouped by comment-section categories>
>
> ## Homebrew Brews
> <each entry>
>
> ## Homebrew Casks
> <each entry>
>
> ## Homebrew Taps
> <each entry>
> ```

### `switch`

Spawn agent with this prompt:

> **Task**: Apply dotfiles changes.
>
> Run: `cd /Users/gigun/ghq/github.com/gigun-dev/dotfiles && git add . && nix run .#switch`
