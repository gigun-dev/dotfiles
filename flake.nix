{
  description = "gigun's macOS dotfiles — nix-darwin + home-manager";

  nixConfig = {
    extra-substituters = [
      "https://cache.numtide.com"
      "https://gigun.cachix.org"
      "https://cclens.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cache.numtide.com-1:bf1jVIGj3GBKisevCptOlNXMoMnPkKlkh89RqPsNJWo="
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
      "gigun.cachix.org-1:jP3ksvzV3coFUQORcYZOR3repURIK+eYtpMiIMaN788="
      "cclens.cachix.org-1:0QUNU6PuVyf+yXOvg3n1rd3FksBoB3s3/Jty50iKRNQ="
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

    # Mac Mini (Intel) 上の Lima ゲストを NixOS で動かすためのモジュール。
    # 提供されるイメージはビルドせず nixosModules.lima だけを使うため、
    # キャッシュヒットの心配がなく follows を統一できる。
    nixos-lima = {
      url = "github:nixos-lima/nixos-lima";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # 秘密の宣言管理。暗号文 (secrets/*.age) を git に置き、mini-vm のホスト鍵で
    # activation 時に復号する。dotfiles を public のまま保てるのが要点。
    # 受信者の定義は secrets/secrets.nix。
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    llm-agents.url = "github:numtide/llm-agents.nix";

    # cclens (Claude Code の使用状況診断ツール, Rust)。llm-agents と同じ理由で
    # nixpkgs.follows を付けない: follows すると我々の nixpkgs に対して Rust を
    # フルビルドし、cclens.cachix.org のキャッシュにヒットしなくなる。
    cclens.url = "github:lambdalisue/cclens";

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
              # Linux は 2 種類ある: WSL (home-manager standalone のみ) と
              # Mac Mini の Lima ゲスト (NixOS なので OS 層も管理する)。
              # /etc/NIXOS の有無で判別し、darwin の switch が system + home を
              # まとめて適用するのと同じ挙動に揃える。どの機械でも
              # `nix run .#switch` だけ覚えていれば済むようにするための分岐。
              switch = mkApp "linux-switch" ''
                if [ -e /etc/NIXOS ]; then
                  sudo nixos-rebuild switch --flake ".#mini-vm" "$@"
                fi
                ${inputs.home-manager.packages.${system}.home-manager}/bin/home-manager \
                  switch --flake ".#${username}-${system}" "$@"
                # cachix push in background (requires `cachix authtoken` to have been run)
                if command -v cachix &>/dev/null; then
                  echo "Pushing to cachix in background..."
                  nix path-info --all | cachix push gigun &>/dev/null &
                fi
              '';

              build = mkApp "linux-build" ''
                if [ -e /etc/NIXOS ]; then
                  nixos-rebuild build --flake ".#mini-vm" "$@"
                fi
                ${inputs.home-manager.packages.${system}.home-manager}/bin/home-manager \
                  build --flake ".#${username}-${system}" "$@"
              '';

              update = mkApp "linux-update" ''
                nix flake update
                if [ -e /etc/NIXOS ]; then
                  sudo nixos-rebuild switch --flake ".#mini-vm" "$@"
                fi
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
                nix flake update llm-agents claude-code-overlay cclens
                echo "Done! Run 'nix run .#switch' to apply changes."
              '';
            };
        };

      flake =
        let
          username = "gigun";

          # llm-agents の CLI ツール (codex/opencode 等) は overlay 経由で取ると
          # 我々の nixpkgs に対して再ビルドされ numtide キャッシュ(llm-agents 自身の
          # nixpkgs でビルド)にヒットしない。standalone packages を直接参照して
          # キャッシュヒットさせるため overlay は使わず extraSpecialArgs で渡す
          # (flake.nix の home-manager 設定参照)。
          llmAgentsFor = system: inputs.llm-agents.packages.${system};

          # cclens も同じ理由で overlay を使わず standalone package を直接参照する
          # (専用キャッシュ cclens.cachix.org は nixConfig で substituter に追加済み)。
          cclensFor = system: inputs.cclens.packages.${system}.default;

          overlays = [
            inputs.claude-code-overlay.overlays.default
            # direnv の doCheck=false override は撤去した: override はハッシュを変えて
            # 素なら upstream キャッシュから fetch できる direnv を毎回ソースビルドさせ、
            # その結果 checkPhase ハングを踏むという自己誘発ループだった。override 無しなら
            # キャッシュヒットでビルドが走らず、ハングも起きない。
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
                ./nix/modules/darwin/apple-container.nix
                inputs.home-manager.darwinModules.home-manager
                {
                  home-manager = {
                    useGlobalPkgs = false;
                    useUserPackages = true;
                    backupFileExtension = "backup";
                    extraSpecialArgs = {
                      llmAgents = llmAgentsFor system;
                      cclens = cclensFor system;
                    };
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

          # Mac Mini (Intel) 上の Lima ゲスト。
          # OS 層のみここで管理し、CLI 環境は下の homeConfigurations
          # (WSL と共用の x86_64-linux 構成) を home-manager standalone で適用する。
          # Lima がユーザーを imperative に作る都合で users.mutableUsers = true が
          # 要るため、home 層を NixOS module 側へ統合はしない。
          nixosConfigurations."mini-vm" = inputs.nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            modules = [
              inputs.nixos-lima.nixosModules.lima
              inputs.agenix.nixosModules.default
              ./nix/modules/nixos/mini-vm.nix
            ];
          };

          # home-manager standalone (WSL / Lima ゲスト向け)
          # nix run .#switch が perSystem の system で自動選択
          homeConfigurations = {
            "${username}-x86_64-linux" = inputs.home-manager.lib.homeManagerConfiguration {
              pkgs = import inputs.nixpkgs {
                system = "x86_64-linux";
                inherit overlays;
                config.allowUnfree = true;
              };
              extraSpecialArgs = {
                llmAgents = llmAgentsFor "x86_64-linux";
                cclens = cclensFor "x86_64-linux";
              };
              modules = [ ./nix/modules/home ];
            };
          };
        };
    };
}
