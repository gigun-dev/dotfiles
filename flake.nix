{
  description = "gigun's macOS dotfiles — nix-darwin + home-manager";

  nixConfig = {
    extra-substituters = [
      "https://cache.numtide.com"
      "https://gigun.cachix.org"
      "https://cclens.cachix.org"
    ];
    # numtide は署名鍵を 2 本使う。旧 cache.numtide.com-1 だけでは、現在 narinfo に付く
    # niks3.numtide.com-1 の署名が `not signed by any of the keys` で弾かれ、全部ローカルビルドになる。
    # 値を疑うときは numtide/system-manager の flake.nix を見る (flake.lock の narHash と取り違えた前例あり)。
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

    # ADR 0016 に従って暗号化fileの配送をSOPSへ統一する。agenixはconsumerを
    # 一件ずつ移行して旧credentialを失効するまでの一時的なrollback経路だけに残す。
    sops-nix = {
      url = "github:Mic92/sops-nix";
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

    # t3-limits (T3 Code サーバーから AI プロバイダの利用上限を読む CLI + agent skill)。
    # 中身は Nushell スクリプトでビルドが軽く、専用キャッシュも無いので nixpkgs を
    # follows する (nix-secure-enclave-key と同じ理由)。
    t3-limits = {
      url = "github:ryoppippi/t3-limits";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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
      ];

      perSystem =
        {
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

          # onActivation.cleanup = "uninstall" は、適用する Brewfile に無い cask / formula / tap を
          # switch の最中に黙って消す。何が消えるかを事前に見えるようにするため、
          # これから適用する Brewfile に `brew bundle cleanup` (dry-run) を当て、空でなければ
          # 一覧を出して止める。続行するなら DOTFILES_ALLOW_BREW_CLEANUP=1。
          # 置き場所を switch app にした理由: darwin-rebuild の activation 内は sudo 下で
          # 対話もできず、止めても switch が部分適用されるだけ。update 系も apply_switch を
          # 通るので 1 箇所で全経路を守れる。brew の無い経路 (Linux / mini-vm / WSL) は
          # 別の applySwitch 分岐なので何もしない。brew 自体が無い darwin も素通り。
          # Brewfile の `trusted: true` は install 時にしか trust store へ反映されず、
          # cleanup 単体は未 trust の tap で落ちる。本物の trust store は触らず、
          # 一時の XDG_CONFIG_HOME へ写して同じ trust を当てた上で判定する。
          brewCleanupGuard =
            let
              brewfile =
                pkgs.writeText "Brewfile"
                  inputs.self.darwinConfigurations."${username}-${system}".config.homebrew.brewfile;
            in
            ''
              brew_cleanup_guard() {
                local brew_bin="" tmp out
                for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
                  if [ -x "$b" ]; then brew_bin="$b"; break; fi
                done
                [ -n "$brew_bin" ] || return 0
                tmp=$(mktemp -d)
                mkdir -p "$tmp/homebrew"
                cp "''${XDG_CONFIG_HOME:+$XDG_CONFIG_HOME/homebrew}''${XDG_CONFIG_HOME:-$HOME/.homebrew}/trust.json" "$tmp/homebrew/" 2>/dev/null || true
                sed -nE 's/^brew "([^"]+\/[^"]+)".*trusted: true.*/\1/p' ${brewfile} \
                  | while read -r n; do XDG_CONFIG_HOME="$tmp" "$brew_bin" trust --formula "$n" >/dev/null 2>&1 || true; done
                sed -nE 's/^cask "([^"]+\/[^"]+)".*trusted: true.*/\1/p' ${brewfile} \
                  | while read -r n; do XDG_CONFIG_HOME="$tmp" "$brew_bin" trust --cask "$n" >/dev/null 2>&1 || true; done
                out=$(XDG_CONFIG_HOME="$tmp" HOMEBREW_NO_AUTO_UPDATE=1 "$brew_bin" bundle cleanup --file=${brewfile} 2>&1) || true
                rm -rf "$tmp"
                if [ -n "$out" ] && [ "''${DOTFILES_ALLOW_BREW_CLEANUP:-}" != 1 ]; then
                  echo "error: この switch は Brewfile に無い brew 項目を uninstall / untap する:" >&2
                  echo "$out" >&2
                  echo "消してよければ DOTFILES_ALLOW_BREW_CLEANUP=1 を付けて再実行。残すなら nix/modules/darwin/homebrew.nix に宣言する。" >&2
                  return 1
                fi
              }
            '';

          # switch と update 系が共有する適用本体。
          # darwin: darwin-rebuild で system + home 両方適用
          # linux:  Linux は 2 種類ある: WSL (home-manager standalone のみ) と
          #   Mac Mini の Lima ゲスト (NixOS なので OS 層も管理する)。
          #   /etc/NIXOS の有無で判別し、darwin の switch が system + home を
          #   まとめて適用するのと同じ挙動に揃える。どの機械でも
          #   `nix run .#switch` だけ覚えていれば済むようにするための分岐。
          # 各行の `|| return`: update 系は `if ! apply_switch` で呼ぶので
          # 関数内では set -e が効かず、system の失敗後に home へ進んでしまう。
          applySwitch =
            if pkgs.stdenv.hostPlatform.isDarwin then
              ''
                ${brewCleanupGuard}
                apply_switch() {
                  brew_cleanup_guard || return
                  sudo ${inputs.nix-darwin.packages.${system}.darwin-rebuild}/bin/darwin-rebuild \
                    switch --flake ".#${username}-${system}" "$@" || return
                }
              ''
            else
              ''
                apply_switch() {
                  home_target="${username}-${system}"
                  if [ -e /etc/NIXOS ]; then
                    home_target="${username}-mini-vm"
                    sudo nixos-rebuild switch --flake ".#mini-vm" "$@" || return
                  fi
                  ${inputs.home-manager.packages.${system}.home-manager}/bin/home-manager \
                    switch --flake ".#$home_target" "$@" || return
                }
              '';

          # lock を更新して適用し、変わっていれば commit まで行う。push はしない
          # (共有 main への公開は、人が commit を見てから打つ一手に残す)。
          # 何を止めるか: update した lock が未 commit のまま手元に残り、次の pull で
          # 衝突するか、main と違う lock で動き続けること (docs/adr/0011-*)。
          mkUpdate =
            name:
            { targets, lane }:
            mkApp name ''
              ${applySwitch}
              cd "$(git rev-parse --show-toplevel)"

              # mini-vm の lock は dotfiles-lock-propose の PR からだけ入る。ここで commit すると
              # 作業コピーが origin より先行し、dotfiles-autoswitch が毎朝止まる。
              if [ -e /etc/NIXOS ]; then
                echo "error: NixOS (mini-vm) では update しない。lock は dotfiles-lock-propose の PR 経由で入る" >&2
                exit 1
              fi
              if ! git diff --quiet || ! git diff --cached --quiet; then
                echo "error: 未コミットの変更がある。commit か stash してから再実行する" >&2
                git status --short >&2
                exit 1
              fi

              # 更新前に main へ追いつく。古い lock から update すると、mini-vm が merge 済みの
              # lock と分岐した commit を作ってしまう。この後で自分で switch するので、
              # pull が起こす post-merge / post-rewrite の switch は止める。
              DOTFILES_SKIP_AUTO_SWITCH=1 git pull --rebase

              log=$(mktemp)
              trap 'rm -f "$log"' EXIT
              nix flake update ${targets} 2>&1 | tee "$log"

              # 適用に失敗した lock は commit しない。pull 済みの版へ戻し、dirty のまま残さない。
              if ! apply_switch "$@"; then
                git checkout -- flake.lock
                echo "error: switch に失敗したので flake.lock を pull 済みの版へ戻した" >&2
                exit 1
              fi

              if git diff --quiet -- flake.lock; then
                echo "flake.lock に差分なし"
              else
                git add flake.lock
                git commit --quiet -m "chore(deps): flake.lock を更新 (${lane})" -m "$(cat "$log")"
                echo "flake.lock を commit した。push は手で行う: git push"
              fi
            '';
        in
        {
          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
          };

          # Why not git-hooks.nix (cachix/git-hooks.nix, 旧 pre-commit-hooks.nix):
          #   このリポジトリの pre-commit は git/hooks/pre-commit (staged 内容の
          #   treefmt 整形 + gitleaks 検査) で、core.hooksPath = git/hooks を home-manager の
          #   installDotfilesHooks が毎 switch で宣言し直している。git-hooks.nix の
          #   devShell に入ると shellHook が core.hooksPath を .git/hooks へ書き換え、
          #   その宣言を無言で奪う。しかも生成される hook は nix store の絶対パスを
          #   exec するだけで gc root を持たないため、nix gc 後は
          #   `/nix/store/...-pre-commit-4.6.2/bin/pre-commit: No such file or directory`
          #   で全コミットが落ちる (2026-09-21 に devShell へ入り、実際に踏んだ)。
          #   検証内容 (treefmt) は scripts/verify.sh の `nix fmt -- --ci .` が CI で
          #   見ているので、消しても守りは薄くならない。
          # Why not devShells.default を空の mkShell で残すか:
          #   中身は inputsFrom = [ config.pre-commit.devShell ] だけだった。入る理由の
          #   無いシェルを残すと `nix develop` を打つ動機だけが残る。ESP 用は
          #   devShells.esp-idf / esp32drop という名前付きなので影響しない。

          # 全ホスト共通の opt-in 開発環境。switch 時の SDK 自動導入や
          # プロジェクト名に依存するグローバル環境変数は不要。
          devShells.esp-idf = import ./nix/devshells/esp-idf.nix {
            inherit system;
            espDev = inputs.esp-dev;
          };
          # 比較用 Arduino core は ESP-IDF 6.1 と別の SDK/cache を使う。
          devShells.esp32drop = import ./nix/devshells/esp32drop.nix { inherit pkgs; };

          # Keep false-success and credential-leak regressions in the CI gate (scripts/verify.sh).
          checks = {
            dotfiles-autoswitch = pkgs.runCommand "dotfiles-autoswitch-tests" { } ''
              mkdir -p nix/modules/nixos scripts/tests infra/langfuse/scripts
              cp ${./nix/modules/nixos/mini-vm.nix} nix/modules/nixos/mini-vm.nix
              cp ${./scripts/tests/dotfiles-autoswitch.py} scripts/tests/dotfiles-autoswitch.py
              cp ${./scripts/tests/lock-propose-heartbeat.py} scripts/tests/lock-propose-heartbeat.py
              cp ${./scripts/job-heartbeat.py} scripts/job-heartbeat.py
              cp ${./scripts/tests/job-heartbeat.py} scripts/tests/job-heartbeat.py
              cp ${./scripts/tests/job-heartbeat-activation.py} scripts/tests/job-heartbeat-activation.py
              cp ${./infra/langfuse/scripts/rollback-target.sh} infra/langfuse/scripts/rollback-target.sh
              cp ${./infra/langfuse/scripts/rollback-safe.sh} infra/langfuse/scripts/rollback-safe.sh
              export PATH=${
                inputs.nixpkgs.lib.makeBinPath [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.jq # autoswitch の CI 判定は本物の jq 式をそのまま回す
                ]
              }
              ${pkgs.python3}/bin/python3 -B scripts/tests/dotfiles-autoswitch.py
              ${pkgs.python3}/bin/python3 -B scripts/tests/lock-propose-heartbeat.py
              ${pkgs.python3}/bin/python3 -B -W error scripts/tests/job-heartbeat.py
              ${pkgs.python3}/bin/python3 -B -W error scripts/tests/job-heartbeat-activation.py
              touch "$out"
            '';

            proposal-clones =
              pkgs.runCommand "proposal-clones-tests"
                {
                  nativeBuildInputs = [
                    pkgs.git
                    pkgs.python3
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.jq
                    pkgs.gnused
                  ];
                }
                ''
                  mkdir -p nix/modules/nixos/services scripts/tests
                  cp ${./nix/modules/nixos/mini-vm.nix} nix/modules/nixos/mini-vm.nix
                  cp ${./nix/modules/nixos/services/langfuse.nix} nix/modules/nixos/services/langfuse.nix
                  cp ${./scripts/tests/proposal-clones.py} scripts/tests/proposal-clones.py
                  ${pkgs.python3}/bin/python3 -B scripts/tests/proposal-clones.py
                  touch "$out"
                '';

            job-heartbeat-config = import ./nix/tests/job-heartbeat-config.nix {
              inherit pkgs;
              nixos = inputs.self.nixosConfigurations.mini-vm;
            };

            host-heartbeat = pkgs.runCommand "host-heartbeat-tests" { } ''
              mkdir tests
              cp ${./scripts/host-heartbeat.py} host-heartbeat.py
              cp ${./scripts/tests/host-heartbeat.py} tests/host-heartbeat.py
              ${pkgs.python3}/bin/python3 -B -W error tests/host-heartbeat.py
              touch "$out"
            '';

            host-heartbeat-preparation = pkgs.runCommand "host-heartbeat-preparation-tests" { } ''
              mkdir -p scripts/tests
              cp ${./scripts/ssh-path-observe.py} scripts/ssh-path-observe.py
              cp ${./scripts/prepare-host-heartbeat-registration.py} scripts/prepare-host-heartbeat-registration.py
              cp ${./scripts/prepare-job-heartbeat-registration.py} scripts/prepare-job-heartbeat-registration.py
              cp ${./scripts/tests/ssh-path-observe.py} scripts/tests/ssh-path-observe.py
              cp ${./scripts/tests/host-heartbeat-registration.py} scripts/tests/host-heartbeat-registration.py
              cp ${./scripts/tests/job-heartbeat-registration.py} scripts/tests/job-heartbeat-registration.py
              ${pkgs.python3}/bin/python3 -B -W error scripts/tests/ssh-path-observe.py
              ${pkgs.python3}/bin/python3 -B -W error scripts/tests/host-heartbeat-registration.py
              ${pkgs.python3}/bin/python3 -B -W error scripts/tests/job-heartbeat-registration.py
              touch "$out"
            '';

            ssh-private-include = import ./nix/tests/ssh-private-include.nix {
              inherit pkgs system inputs;
            };

            mini-vm-narrow-mounts = import ./nix/tests/mini-vm-narrow-mounts.nix { inherit pkgs inputs; };
          }
          // import ./nix/tests/developer-checks.nix {
            inherit
              pkgs
              system
              inputs
              applySwitch
              ;
          }
          // inputs.nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
            sops-migration-config = import ./nix/tests/sops-migration-config.nix { inherit pkgs inputs; };

            antigravity-service = import ./nix/tests/antigravity-service.nix {
              inherit pkgs;
              nixos = inputs.self.nixosConfigurations.mini-vm;
            };

            reviewed-ci-runner = import ./nix/tests/reviewed-ci-runner.nix { inherit pkgs inputs; };

            dotfiles-autoswitch-lifecycle = import ./nix/tests/dotfiles-autoswitch-lifecycle.nix {
              inherit pkgs;
              service = inputs.self.nixosConfigurations.mini-vm.config.systemd.services.dotfiles-autoswitch;
            };
          };

          # Apps — perSystem の system で正しい構成を選択 (分岐は applySwitch)
          apps = {
            # pre-commit hook の秘密検査用。overlay を通さない素の nixpkgs 版なので
            # 上流キャッシュにヒットする。
            gitleaks = {
              type = "app";
              program = "${pkgs.gitleaks}/bin/gitleaks";
              meta.description = "Scan repository content for secrets";
            };

            switch = mkApp "switch" ''
              ${applySwitch}
              apply_switch "$@"
            '';

            build = mkApp "build" (
              if pkgs.stdenv.hostPlatform.isDarwin then
                ''
                  ${inputs.nix-darwin.packages.${system}.darwin-rebuild}/bin/darwin-rebuild \
                    build --flake ".#${username}-${system}" "$@"
                ''
              else
                ''
                  home_target="${username}-${system}"
                  if [ -e /etc/NIXOS ]; then
                    home_target="${username}-mini-vm"
                    nixos-rebuild build --flake ".#mini-vm" "$@"
                  fi
                  ${inputs.home-manager.packages.${system}.home-manager}/bin/home-manager \
                    build --flake ".#$home_target" "$@"
                ''
            );

            update = mkUpdate "update" {
              targets = "";
              lane = "local";
            };

            # mini-vm の fast レーン (dotfiles-lock-propose@fast) と同じ input を手元で先取りする。
            update-ai-tools = mkUpdate "update-ai-tools" {
              targets = "llm-agents claude-code-overlay cclens";
              lane = "local fast";
            };

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

          # t3-limits も overlay にせず standalone package を extraSpecialArgs で渡す
          # (overlay に混ぜると nixpkgs 全体の評価に input が絡むため)。
          t3LimitsFor = system: inputs.t3-limits.packages.${system}.default;

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
              # HostName を宣言しないと `hostname` が DHCP 由来の一時名に流される
              # (scutil の HostName 未設定時のフォールバック)。実際に 2026-09-07
              # home 5G 導入でルーターが変わり MacBook の `hostname` が `Mac` に
              # 化けた (ComputerName/LocalHostName は無傷)。zsh プロンプトの `%m`
              # がこれを見ているため名前が飛んで見えた。デフォルト値を付けない
              # 理由: 新ホストを足すときに書き忘れたら評価エラーで気づけるように。
              hostName,
              alwaysOn ? false,
              shellLinksManagedByAnsible ? false,
              userDefaultsManagedByAnsible ? false,
            }:
            inputs.nix-darwin.lib.darwinSystem {
              specialArgs = { inherit userDefaultsManagedByAnsible; };
              modules = [
                {
                  # プラットフォームは darwinSystem の `system` 引数ではなく
                  # nixpkgs.hostPlatform で宣言する (nix-darwin の推奨形)
                  nixpkgs.hostPlatform = system;
                  nixpkgs.overlays = overlays;
                  # localHostName は書かない: hostName から既定されるため
                  # (nix-darwin の networking.localHostName の意味論)。
                  networking.hostName = hostName;
                  networking.computerName = hostName;
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
                ./nix/modules/darwin/host-heartbeat.nix
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
                      inherit shellLinksManagedByAnsible;
                      llmAgents = llmAgentsFor system;
                      cclens = cclensFor system;
                      t3Limits = t3LimitsFor system;
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
                      # useGlobalPkgs = false なので home 層の nixpkgs は system 層の
                      # config を継がない。claude-code-overlay が unfree を宣言したため
                      # Linux の homeConfigurations と同じく許可する。
                      nixpkgs.config.allowUnfree = true;
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
            "${username}-aarch64-darwin" = mkDarwinSystem "aarch64-darwin" { hostName = "MBPM4Pro"; };
            # Explicit maintenance target; ordinary switch retains Homebrew/Container management.
            "${username}-aarch64-darwin-runtime-maintenance" =
              (mkDarwinSystem "aarch64-darwin" { hostName = "MBPM4Pro"; }).extendModules
                {
                  modules = [
                    ({ lib, ... }: {
                      disabledModules = [ ./nix/modules/darwin/apple-container.nix ];
                      # Pinned nix-darwin internal module option; verify on every lock upgrade.
                      system.activationScripts.homebrew.text = lib.mkForce "";
                      home-manager.users.${username}.home.activation = {
                        installLaunchdUI = lib.mkForce {
                          data = "";
                          after = [ "writeBoundary" ];
                          before = [ ];
                        };
                        installUvPython = lib.mkForce {
                          data = "";
                          after = [ "writeBoundary" ];
                          before = [ ];
                        };
                      };
                      homebrew.onActivation = {
                        cleanup = lib.mkForce "none";
                        upgrade = lib.mkForce false;
                        autoUpdate = lib.mkForce false;
                      };
                    })
                  ];
                };
            # Mac Mini (Intel)。Lima ゲスト (mini-vm) を載せた 24/365 の拠点。
            # macOS 側は nix 管理を凍結中なのでこの hostName 宣言は当たらない。
            # network-watchdog / homebrew の brews と同じ「M チップ化した日に効く予約」。
            "${username}-x86_64-darwin" = mkDarwinSystem "x86_64-darwin" {
              hostName = "mini";
              alwaysOn = true;
              shellLinksManagedByAnsible = true;
              userDefaultsManagedByAnsible = true;
            };
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
              # 自動更新 (dotfiles-autoswitch) が home 層を switch するのに使う。
              # apps.switch と同じ input を参照し、手動 switch と同じ home-manager で
              # 回るようにする (バージョン差で片方だけ壊れるのを避ける)。
              dotfilesSource = inputs.self.outPath;
              dotfilesRevision = inputs.self.rev or inputs.self.dirtyRev or "unversioned";
              homeManager = inputs.home-manager.packages."x86_64-linux".home-manager;
            };
            modules = [
              inputs.nixos-lima.nixosModules.lima
              inputs.agenix.nixosModules.default
              inputs.sops-nix.nixosModules.sops
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
                shellLinksManagedByAnsible = false;
                llmAgents = llmAgentsFor "x86_64-linux";
                cclens = cclensFor "x86_64-linux";
                t3Limits = t3LimitsFor "x86_64-linux";
              };
              modules = [ ./nix/modules/home ];
            };
            # Raw upstream Node requires mini-vm's existing nix-ld; keep WSL unchanged.
            "${username}-mini-vm" =
              let
                base = inputs.self.homeConfigurations."${username}-x86_64-linux";
                runtime = import ./nix/runtime-security/pinned-linux.nix;
                replace =
                  p:
                  if
                    builtins.elem (p.pname or "") [
                      "nodejs"
                      "nodejs-slim"
                    ]
                  then
                    runtime.node
                  else if (p.pname or "") == "bun" then
                    runtime.bun
                  else
                    p;
              in
              base.extendModules {
                modules = [ { home.packages = base.pkgs.lib.mkForce (map replace base.config.home.packages); } ];
              };
          };
        };
    };
}
