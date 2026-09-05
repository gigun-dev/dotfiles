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

    # Secure Enclave の中に SSH 鍵を作り、それを Git のコミット署名鍵として使う。
    # 秘密鍵はチップから一切出ない (~/.ssh/id_enclave_key はスタブで、実体は
    # Secure Enclave 内)。upstream の `systems` が aarch64-darwin のみなので
    # 事実上 M4 Pro 専用。Intel Mac / Linux (mini-vm, WSL) には homeManagerModules
    # を足さない (flake.nix の mkDarwinSystem 参照)。
    # follows を付けてよい理由: llm-agents / cclens と違いこちらは中身が Nushell
    # スクリプト (package.nix 参照) でビルドが軽く、専用キャッシュに当たるかを
    # 気にする必要が無い。follows してもソースビルドのコストが無視できる。
    nix-secure-enclave-key = {
      url = "github:ryoppippi/nix-secure-enclave-key";
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

    # Cloudflare OS。mini-vm が wrangler dev で常駐させている。
    #
    # **`flake = false` で、ここから運ぶのは rev だけ**。ビルドはしない。
    # 実行形態が `pnpm run-local` (実行時に pnpm install + Vite+ ビルド、27 ワークスペース /
    # node_modules 874MB) なので derivation 化は割に合わない。詳細は mini-vm.nix の
    # ExecStartPre のコメント。
    #
    # 狙いは版の固定。以前は誰も版を決めておらず、mini-vm の作業コピーの HEAD が
    # たまたまの版だった (2026-09-01 に 106 コミット遅れているのを偶然発見)。
    # ここに置けば `nix flake update cloudflare-os` が更新の起点になり、
    # codex (llm-agents) と同じ手順に揃う。
    cloudflare-os = {
      url = "github:cloudflare/cloudflare-os";
      flake = false;
    };

    # ESP-IDF と OS 別の公式 toolchain を hash 固定する上流実装。
    # nixpkgs は follows しない: 上流の native tools の基盤と
    # Intel Mac 対応を保つ。dotfiles の基盤パッケージへ overlay は適用しない。
    esp-dev.url = "github:mirrexagon/nixpkgs-esp-dev";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "x86_64-linux"
        "aarch64-linux"
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

          # 全ホスト共通の opt-in 開発環境。switch 時の SDK 自動導入や
          # プロジェクト名に依存するグローバル環境変数は不要。
          devShells.esp-idf = import ./nix/devshells/esp-idf.nix {
            inherit system;
            espDev = inputs.esp-dev;
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

              # Cloudflare リソースの IaC (tofu/)。`nix run .#tofu -- plan` のように使う。
              #
              # ラッパにしている理由は認証情報の扱い。素の `tofu` を叩けるようにすると
              # CLOUDFLARE_API_TOKEN / AWS_* をシェルの rc か direnv に平文で置くことになる。
              # ここで secrets/tofu-env.age を**実行のたびにその場で復号**して環境変数へ
              # 流し込めば、平文はプロセスの寿命しか生きない。
              #
              # なお mini-vm の cloudflare-os が使う CLOUDFLARE_API_TOKEN (Workers AI +
              # Workers Scripts) とは別のトークン。名前が同じなので、間違えて同じ .age に
              # 混ぜないこと (権限も用途も違う)。
              tofu = mkApp "tofu" ''
                root=$(${pkgs.git}/bin/git rev-parse --show-toplevel)
                key="$HOME/.ssh/id_ed25519"

                if [ ! -f "$key" ]; then
                  echo "error: $key が無い。secrets/secrets.nix の受信者鍵が必要" >&2
                  exit 1
                fi

                # コマンド置換なので age が失敗すれば set -e でここで止まる。
                # `< <(age ...)` だと復号失敗でも空を読んで素通りしてしまうため避けている。
                env_content=$(${pkgs.age}/bin/age -d -i "$key" "$root/secrets/tofu-env.age")
                # here-string を使う (here-doc だと nix のインデント文字列剥がしと
                # 終端マーカーの位置がぶつかって壊れやすい)。
                while IFS='=' read -r k v; do
                  [ -n "$k" ] || continue
                  # shellcheck disable=SC2163  # "k=v" の形なので正しく export される
                  export "$k=$v"
                done <<< "$env_content"

                # R2 にリージョンは無いが S3 バックエンドが必須項目として要求する。
                # versions.tf の `region = "auto"` と揃えておく。
                export AWS_REGION=auto
                export AWS_DEFAULT_REGION=auto

                cd "$root/tofu" || exit 1
                exec ${pkgs.opentofu}/bin/tofu "$@"
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

          # 両アーキテクチャで同一モジュールを共有。
          #
          # 第 2 引数は**役割**。アーキテクチャとは別の軸として明示的に渡す。
          #   alwaysOn: 24/365 で置きっぱなしにする拠点か (現状は Mac Mini だけ)。
          #             人が前に座っていないので、落ちても誰も気づかない。だから
          #             証拠を残す番人 (network-watchdog) を入れる対象になる。
          #
          # ⚠️ いま「x86_64-darwin = mini = alwaysOn」が 1:1 なのは**偶然**。mini が
          # Intel なのは買った時期の話で、常時起動であることとは何の関係も無い。
          # だから番人の有無を `system == "x86_64-darwin"` では分岐させない
          # (そう書くと mini を Apple Silicon に置き換えた日に、誰にも気づかれずに
          # 番人が消える)。機械を入れ替えるときは、arch ではなくこの alwaysOn を
          # 新しいホストへ付け替えること。
          #
          # Why not ホスト名で分岐: darwinConfigurations のキーは
          # `${username}-${system}` で、nix run .#switch がこの形で自動選択している
          # (下のコメント参照)。キーにホスト名を入れると switch が壊れるため、
          # キーの形は変えずに、生成側の引数で役割を渡す形にした。
          mkDarwinSystem =
            system:
            {
              alwaysOn ? false,
            }:
            inputs.nix-darwin.lib.darwinSystem {
              inherit system;
              modules = [
                {
                  nixpkgs.overlays = overlays;
                }
                ./nix/modules/darwin/system.nix
                ./nix/modules/darwin/homebrew.nix
                ./nix/modules/darwin/apple-container.nix
              ]
              # 常時起動ホストにだけ入れる番人。2026-09-03 に mini が 7 時間
              # 外部と通信できなくなり (詳細は network-watchdog.sh の冒頭)、
              # 何が起きたかを示す記録が 1 行も残っていなかったことへの答え。
              # MacBook には入れない: 蓋を閉じれば落ちるのが当たり前の機械で
              # 「届かない」を記録しても、証拠にもノイズ源にしかならない。
              ++ inputs.nixpkgs.lib.optionals alwaysOn [
                ./nix/modules/darwin/network-watchdog.nix
              ]
              ++ [
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
                      # nix-secure-enclave-key の upstream `systems` は aarch64-darwin
                      # のみ (packages.default が aarch64-darwin でしかビルドされない)。
                      # x86_64-darwin (Intel Mac Mini) で homeManagerModules.default を
                      # 無条件 import すると `self.packages.${pkgs.system}.default` の
                      # 評価自体が存在しない attr で落ちる。optionals で system 分岐して
                      # Intel Mac ではこの import 自体を評価させない (`nix eval` すら
                      # 通らないので mkIf では防げない — import するかどうかのレベルで切る)。
                      imports = [
                        ./nix/modules/home
                      ]
                      ++ inputs.nixpkgs.lib.optionals (system == "aarch64-darwin") [
                        inputs.nix-secure-enclave-key.homeManagerModules.default
                        ./nix/modules/darwin/secure-enclave-key.nix
                      ];
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
          # ⭐️ キーの形 (`${username}-${system}`) は変えないこと。役割は第 2 引数で渡す。
          darwinConfigurations = {
            # MacBook Pro (M4 Pro)。手元機なので alwaysOn ではない。
            "${username}-aarch64-darwin" = mkDarwinSystem "aarch64-darwin" { };
            # Mac Mini (Intel)。Lima ゲスト (mini-vm) を載せた 24/365 の拠点。
            "${username}-x86_64-darwin" = mkDarwinSystem "x86_64-darwin" { alwaysOn = true; };
          };

          # Mac Mini (Intel) 上の Lima ゲスト。
          # OS 層のみここで管理し、CLI 環境は下の homeConfigurations
          # (WSL と共用の x86_64-linux 構成) を home-manager standalone で適用する。
          # Lima がユーザーを imperative に作る都合で users.mutableUsers = true が
          # 要るため、home 層を NixOS module 側へ統合はしない。
          nixosConfigurations."mini-vm" = inputs.nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            # codex を OS 層の systemd unit (codex-remote-control) から参照するため、
            # home 層と同じ standalone packages を渡す。home 側と同一 derivation なので
            # 実体は共有され、numtide キャッシュにも同じくヒットする (二重ビルドにならない)。
            # Why not `/home/gigun/.nix-profile/bin/codex`: home-manager の activation
            # 順序に system unit が依存してしまう上、版が固定されない。
            specialArgs = {
              llmAgents = llmAgentsFor "x86_64-linux";
              # ソースではなく rev だけを渡す。ExecStartPre がこの rev へ checkout する。
              cloudflareOsRev = inputs.cloudflare-os.rev;
            };
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
