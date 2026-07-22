{
  description = "gigun's macOS dotfiles — nix-darwin + home-manager";

  nixConfig = {
    extra-substituters = [
      "https://cache.numtide.com"
      "https://gigun.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cache.numtide.com-1:bf1jVIGj3GBKisevCptOlNXMoMnPkKlkh89RqPsNJWo="
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
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
            # llm-agents.nix は overlay 名を default → shared-nixpkgs に改名した
            # (2026-07 頃)。pkgs.llm-agents.* の中身は不変。
            inputs.llm-agents.overlays.shared-nixpkgs
            # direnv の checkPhase が nix sandbox 内でハングするため無効化
            (final: prev: {
              direnv = prev.direnv.overrideAttrs { doCheck = false; };
            })
            # zsh master ビルド: 5.9 リリース版の `signal_suspend` は
            # `sigprocmask + pause()` の race 持ち実装で、macOS 26.4.1 と組合せると
            # SIGCHLD 配送タイミング次第で widget 内 `$(...)` が永久 wait に陥る。
            # master では `sigsuspend()` 単体に書き換えられて race 解消済みのため
            # nixpkgs 5.9 ではなく master を pin して使用する。
            (final: prev: {
              zsh = prev.zsh.overrideAttrs (old: {
                version = "master-23d1bfe";
                src = prev.fetchgit {
                  url = "https://github.com/zsh-users/zsh.git";
                  rev = "23d1bfe75d428eb6ed0f32a14c7e73824c86756f";
                  hash = "sha256-ZKua8aglVuNN5nYnMbE/f6ikT6H4EKFJ3nVz/CfGYGs=";
                };
                # nixpkgs 5.9 は master で fix 済の back-port patch を多数持っているが、
                # master 自体に取り込み済みのため一切不要 (適用すると衝突する)。
                patches = [ ];
                # master は configure を含まず Util/preconfig で生成する。
                # autoreconfHook は configure.ac から configure を作るが、preconfig は
                # それに加えて Src/Modules.list 等を生成するため明示的に呼ぶ。
                preAutoreconf = (old.preAutoreconf or "") + ''
                  Util/preconfig
                '';
                # yodl (man page generator) は darwin で使えないが、zsh の configure は
                # yodl 不在を検出すると YODL=":" を設定し doc 生成を skip する設計
                # (Doc/Makefile.in の `case '$(YODL)' in :*) touch $@ ;;`) なので
                # 追加しない。
                # ただし `make install` の `install.man` ターゲットは `test -s` で
                # ファイル非空チェックするため、空 man ファイルで fail する。
                # darwin では man/info/doc 生成自体を install から除外。
                outputs = [ "out" ];
                # doc/info/man は yodl 無しでは生成できないので install しない。
                # 通常の `make install` は install.bin/modules/fns/man/info を全部走るため、
                # 必要なターゲットだけ手動で叩く。
                installPhase = ''
                  runHook preInstall
                  make install.bin install.modules install.fns
                  runHook postInstall
                '';
                # 元 derivation の postInstall は `make install.info install.html` を呼ぶため
                # 上書き。zshenv の zcompile + 配置だけ残す。
                postInstall = ''
                  mkdir -p $out/etc/
                  cat > $out/etc/zshenv <<'EOF'
                  if test -e /etc/NIXOS; then
                    if test -r /etc/zshenv; then
                      . /etc/zshenv
                    else
                      emulate bash
                      alias shopt=false
                      if [ -z "$__NIXOS_SET_ENVIRONMENT_DONE" ]; then
                        . /etc/set-environment
                      fi
                      unalias shopt
                      emulate zsh
                    fi
                    if test -r /etc/zshenv.local; then
                      . /etc/zshenv.local
                    fi
                  else
                    if test -r /etc/zshenv; then
                      . /etc/zshenv
                    fi
                  fi
                  EOF
                  $out/bin/zsh -c "zcompile $out/etc/zshenv"
                  mv $out/etc/zshenv $out/etc/zshenv_zwc_is_used
                  rm -f $out/bin/zsh-master-23d1bfe
                '';
              });
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
