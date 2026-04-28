{
  description = "gigun's macOS dotfiles — nix-darwin + home-manager";

  nixConfig = {
    extra-substituters = [
      "https://cache.numtide.com"
      "https://gigun.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cache.numtide.com-1:bf1jVIGj3GBKisevCptOlNXMoMnPkKlkh89RqPsNJWo="
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKlx087E31z7KurReQ1YHSKp5iw="
      "gigun.cachix.org-1:jP3ksvzV3coFUQORcYZOR3repURIK+eYtpMiIMaN788="
    ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";

    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    llm-agents.url = "github:numtide/llm-agents.nix";

    claude-code-overlay = {
      url = "github:ryoppippi/claude-code-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      imports = [
        inputs.treefmt-nix.flakeModule
        inputs.git-hooks.flakeModule
      ];

      perSystem =
        {
          config,
          pkgs,
          system,
          ...
        }:
        let
          username = "gigun";

          # mkApp helper (mozumasu pattern)
          mkApp = name: script: {
            type = "app";
            program = "${
              pkgs.writeShellApplication {
                inherit name;
                text = script;
              }
            }/bin/${name}";
          };
        in
        {
          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
          };

          pre-commit.settings.hooks = {
            treefmt.enable = true;
          };

          devShells.default = pkgs.mkShell {
            inputsFrom = [ config.pre-commit.devShell ];
          };

          # Apps — perSystem の system で正しい構成を選択
          # darwin: darwin-rebuild で system + home 両方適用
          # linux:  home-manager standalone で home のみ適用 (WSL 想定)
          apps =
            pkgs.lib.optionalAttrs pkgs.stdenv.isDarwin {
              switch = mkApp "darwin-switch" ''
                sudo ${inputs.nix-darwin.packages.${system}.darwin-rebuild}/bin/darwin-rebuild \
                  switch --flake ".#${username}-${system}" "$@"
                # cachix push in background
                if command -v cachix &>/dev/null; then
                  echo "Pushing to cachix in background..."
                  nix path-info --all | cachix push gigun &>/dev/null &
                fi
              '';

              build = mkApp "darwin-build" ''
                ${inputs.nix-darwin.packages.${system}.darwin-rebuild}/bin/darwin-rebuild \
                  build --flake ".#${username}-${system}" "$@"
              '';

              update = mkApp "darwin-update" ''
                nix flake update
                sudo ${inputs.nix-darwin.packages.${system}.darwin-rebuild}/bin/darwin-rebuild \
                  switch --flake ".#${username}-${system}" "$@"
                # cachix push in background
                if command -v cachix &>/dev/null; then
                  echo "Pushing to cachix in background..."
                  nix path-info --all | cachix push gigun &>/dev/null &
                fi
              '';
            }
            // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
              switch = mkApp "home-switch" ''
                ${inputs.home-manager.packages.${system}.home-manager}/bin/home-manager \
                  switch --flake ".#${username}-${system}" "$@"
                # cachix push in background (requires `cachix authtoken` to have been run)
                if command -v cachix &>/dev/null; then
                  echo "Pushing to cachix in background..."
                  nix path-info --all | cachix push gigun &>/dev/null &
                fi
              '';

              build = mkApp "home-build" ''
                ${inputs.home-manager.packages.${system}.home-manager}/bin/home-manager \
                  build --flake ".#${username}-${system}" "$@"
              '';

              update = mkApp "home-update" ''
                nix flake update
                ${inputs.home-manager.packages.${system}.home-manager}/bin/home-manager \
                  switch --flake ".#${username}-${system}" "$@"
                # cachix push in background
                if command -v cachix &>/dev/null; then
                  echo "Pushing to cachix in background..."
                  nix path-info --all | cachix push gigun &>/dev/null &
                fi
              '';
            }
            // {
              update-ai-tools = mkApp "update-ai-tools" ''
                echo "Updating AI tools inputs..."
                nix flake update llm-agents claude-code-overlay
                echo "Done! Run 'nix run .#switch' to apply changes."
              '';
            };
        };

      flake =
        let
          username = "gigun";

          overlays = [
            inputs.claude-code-overlay.overlays.default
            inputs.llm-agents.overlays.default
            # direnv の checkPhase が nix sandbox 内でハングするため無効化
            (final: prev: {
              direnv = prev.direnv.overrideAttrs { doCheck = false; };
            })
          ];

          # 両アーキテクチャで同一モジュールを共有
          mkDarwinSystem =
            system:
            inputs.nix-darwin.lib.darwinSystem {
              inherit system;
              modules = [
                {
                  nixpkgs.overlays = overlays;
                }
                ./nix/modules/darwin/system.nix
                ./nix/modules/darwin/homebrew.nix
                inputs.home-manager.darwinModules.home-manager
                {
                  home-manager = {
                    useGlobalPkgs = false;
                    useUserPackages = true;
                    backupFileExtension = "backup";
                    users.${username} = {
                      imports = [ ./nix/modules/home ];
                      nixpkgs.overlays = overlays;
                    };
                  };
                }
              ];
            };
        in
        {
          # system 別の darwinConfiguration を生成
          # nix run .#switch が perSystem の system で自動選択
          darwinConfigurations = {
            "${username}-aarch64-darwin" = mkDarwinSystem "aarch64-darwin";
            "${username}-x86_64-darwin" = mkDarwinSystem "x86_64-darwin";
          };

          # home-manager standalone (WSL / Linux 向け)
          # nix run .#switch が perSystem の system で自動選択
          homeConfigurations = {
            "${username}-x86_64-linux" = inputs.home-manager.lib.homeManagerConfiguration {
              pkgs = import inputs.nixpkgs {
                system = "x86_64-linux";
                inherit overlays;
                config.allowUnfree = true;
              };
              modules = [ ./nix/modules/home ];
            };
          };
        };
    };
}
