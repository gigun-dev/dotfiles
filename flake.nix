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

    # ADR 0018 に従って暗号化fileの配送をSOPSへ統一する。agenixはconsumerを
    # 一件ずつ移行して旧credentialを失効するまでの一時的なrollback経路だけに残す。
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Secure Enclave の中に SSH 鍵を作り、それを Git のコミット署名鍵として使う。
    # 秘密鍵はチップから一切出ない (~/.ssh/id_enclave_key はスタブで、実体は
    # Secure Enclave 内)。upstream の `systems` が aarch64-darwin のみなので
    # darwin 構成 (mkDarwinSystem) だけが homeManagerModules を足し、Linux
    # (mini-vm, WSL) の homeConfigurations には足さない。
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

    # skill だけのものを plugin で包まず 3 ホストへ配る (nix/modules/home/agent-skills.nix)。
    agent-skills = {
      url = "github:Kyure-A/agent-skills-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # ryoppippi の skill の上流。版は flake.lock で固定する。
    ryoppippi-dotfiles = {
      url = "github:ryoppippi/dotfiles";
      flake = false;
    };
    # 以下も skill だけでできた上流。plugin で包まず agent-skills-nix で配る
    # (gigun-dev/claude-code ADR 0006)。版は flake.lock で固定する。
    emil-skills = {
      url = "github:emilkowalski/skills";
      flake = false;
    };
    unslop = {
      url = "github:heydamir/unslop";
      flake = false;
    };
    hallmark = {
      url = "github:Nutlope/hallmark";
      flake = false;
    };
    langfuse-skills = {
      url = "github:langfuse/skills";
      flake = false;
    };
    modern-web-guidance = {
      url = "github:GoogleChrome/modern-web-guidance";
      flake = false;
    };
    yomiyasu = {
      url = "github:nanaism/yomiyasu";
      flake = false;
    };
    swift-concurrency-skill = {
      url = "github:twostraws/Swift-Concurrency-Agent-Skill";
      flake = false;
    };
    swift-testing-skill = {
      url = "github:twostraws/Swift-Testing-Agent-Skill";
      flake = false;
    };
    swiftui-skill = {
      url = "github:twostraws/SwiftUI-Agent-Skill";
      flake = false;
    };

    # gigun-dev/claude-code の flake。marketplace の一覧 (nix/gigun-plugins.nix) と、版を固定して
    # 1 回だけビルドした外部 plugin (overlay の external-plugins。claude-code の ADR 0007) を渡す。
    # 置き場所は nix/modules/home/agent-plugins.nix。版とハッシュは claude-code 側で動き、
    # ここは rev を進めるだけ。
    gigun-plugins = {
      url = "github:gigun-dev/claude-code";
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

          # flake app は Nushell で書き、ビルド時に nu-check を当てる (ryoppippi/dotfiles の
          # nix/flake/writers.nix と同じ)。構文の誤りはビルドで落ちる。switch-routing check が
          # switch app そのものをビルドして動かすので、`nix flake check` でも落ちる
          # (a9b4f08 の bash の誤りは、CI が darwin の app をビルドしないので
          # `nix run .#switch` で初めて出た)。外部コマンド名の誤りまでは nu-check も見ない。
          # makeScriptWriter は check を `<check> $out` の形で呼ぶので、対象は引数で届く。
          # `--debug` を付けないと nu-check は false を出すだけで 0 で終わる。
          # `--no-config-file` は writeNu が shebang に入れるので、対話用の設定は読まない。
          nu = pkgs.lib.getExe pkgs.nushell;
          nuCheck = pkgs.writeShellScript "nu-check" ''
            exec ${nu} --no-config-file --commands "nu-check --debug '$1'"
          '';
          writeNu = name: body: pkgs.writers.writeNu name { check = nuCheck; } body;
          # 引数をそのまま渡す app は `def --wrapped main [...args: string]` で受ける。
          # 素の `...args` だと未知のフラグを main のフラグとして解釈して落ちる。
          mkApp = name: body: {
            type = "app";
            program = toString (writeNu name body);
          };

          # darwin-rebuild evaluates as root; only its Git SSH transport needs the
          # invoking user's SSH config, known_hosts and agent. Keep activation and
          # profile/rollback handling in the official privileged switch command.
          darwinGitSSH = pkgs.writeShellScript "darwin-git-user-ssh" ''
            exec /usr/bin/sudo --user=${pkgs.lib.escapeShellArg username} --set-home \
              --preserve-env=SSH_AUTH_SOCK -- /usr/bin/ssh "$@"
          '';

          homeManager = "${inputs.home-manager.packages.${system}.home-manager}/bin/home-manager";

          # Linux は 2 種類ある: WSL (home-manager standalone のみ) と Mac Mini の Lima ゲスト
          # (NixOS なので OS 層も管理する)。/etc/NIXOS の有無で判別し、darwin の switch が
          # system + home をまとめて適用するのと同じ挙動に揃える。どの機械でも
          # `nix run .#switch` だけ覚えていれば済むようにするための分岐。
          linuxHomeTarget = ''
            def home-target [] {
              if ("/etc/NIXOS" | path exists) { "${username}-mini-vm" } else { "${username}-${system}" }
            }
          '';

          # switch と update 系が共有する適用本体。
          # 外部コマンドが失敗すると Nushell はそこでエラーを投げるので、system の失敗後に
          # home へ進むことは無い (bash 版は各行の `|| return` で止めていた)。update 系は
          # apply-system を try で包み、失敗したら lock を戻す。
          # after-switch: darwin は Homebrew を activation の後に利用者として揃える
          # (理由は nix/modules/darwin/homebrew.nix の brewBundle)。update 系は lock を
          # commit してから呼ぶ。system は新しい lock で適用済みなので、brew の失敗で
          # lock を戻すと、動いている system と lock が食い違う。
          applySwitch =
            if pkgs.stdenv.hostPlatform.isDarwin then
              ''
                def apply-system [args: list<string>] {
                  (^/usr/bin/sudo --preserve-env=SSH_AUTH_SOCK
                    "GIT_SSH_COMMAND=${darwinGitSSH}"
                    ${inputs.nix-darwin.packages.${system}.darwin-rebuild}/bin/darwin-rebuild
                    switch --flake ".#${username}-${system}" ...$args)
                }

                # --rollback / --switch-generation で brew-bundle を持たない前の世代へ戻ったときは
                # 飛ばす。system の切り替えは成功しているので、ここで失敗にしない。
                def after-switch [] {
                  let bundle = "/run/current-system/brew-bundle"
                  if ($bundle | path exists) {
                    ^$bundle
                  } else {
                    print --stderr $"note: この世代には ($bundle) が無いので、Homebrew は揃えない"
                  }
                }
              ''
            else
              ''
                ${linuxHomeTarget}

                def apply-system [args: list<string>] {
                  if ("/etc/NIXOS" | path exists) {
                    ^sudo nixos-rebuild switch --flake ".#mini-vm" ...$args
                  }
                  ^${homeManager} switch --flake $".#(home-target)" ...$args
                }

                def after-switch [] {}
              '';

          # darwin-rebuild は世代の一覧や切り替え (--list-generations / --rollback /
          # --switch-generation) でも 0 で終わる。これらは宣言した新しい構成を適用しないので、
          # switch は after-switch を呼ばず、update 系は lock を触る前に断る (適用していない
          # lock を commit しない)。
          generationOnly = ''
            const generation_only = ["--list-generations", "--rollback", "--switch-generation", "-G", "--help"]

            def applies-new-config [args: list<string>] {
              $args | all {|arg| $arg not-in $generation_only }
            }
          '';

          switchApp = writeNu "switch" ''
            ${applySwitch}
            ${generationOnly}

            def --wrapped main [...args: string] {
              apply-system $args
              if (applies-new-config $args) { after-switch }
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
              ${generationOnly}

              # 一時ログを消してから、元の終了コードで終わる (bash 版の EXIT trap の代わり)。
              def or-remove [log: path, job: closure] {
                try { do $job } catch {|e|
                  rm --force $log
                  exit ($e.exit_code? | default 1)
                }
              }

              def --wrapped main [...args: string] {
                if not (applies-new-config $args) {
                  print --stderr $"error: update は世代の一覧・切り替えの引数を受け付けない: ($args | str join ' ')"
                  exit 1
                }
                cd (^git rev-parse --show-toplevel | str trim)

                # mini-vm の lock は flake-lock-proposal.yaml の PR からだけ入る。ここで commit すると
                # 作業コピーが origin より先行し、dotfiles-autoswitch が毎朝止まる。
                if ("/etc/NIXOS" | path exists) {
                  print --stderr "error: NixOS (mini-vm) では update しない。lock は flake-lock-proposal.yaml の PR 経由で入る"
                  exit 1
                }
                let unstaged = (^git diff --quiet | complete).exit_code != 0
                let staged = (^git diff --cached --quiet | complete).exit_code != 0
                if $unstaged or $staged {
                  print --stderr "error: 未コミットの変更がある。commit か stash してから再実行する"
                  print --stderr --no-newline (^git status --short)
                  exit 1
                }

                # 更新前に main へ追いつく。古い lock から update すると、mini-vm が merge 済みの
                # lock と分岐した commit を作ってしまう。この後で自分で switch するので、
                # pull が起こす post-merge / post-rewrite の switch は止める。
                with-env { DOTFILES_SKIP_AUTO_SWITCH: "1" } { ^git pull --rebase }

                let log = (mktemp --tmpdir flake-update.XXXXXX)
                or-remove $log { ^nix flake update ...${builtins.toJSON targets} o+e>| tee { save --force $log } }

                # 適用に失敗した lock は commit しない。pull 済みの版へ戻し、dirty のまま残さない。
                try {
                  apply-system $args
                } catch {
                  ^git checkout -- flake.lock
                  rm $log
                  print --stderr "error: switch に失敗したので flake.lock を pull 済みの版へ戻した"
                  exit 1
                }

                if (^git diff --quiet -- flake.lock | complete).exit_code == 0 {
                  print "flake.lock に差分なし"
                } else {
                  ^git add flake.lock
                  or-remove $log { ^git commit --quiet -m "chore(deps): flake.lock を更新 (${lane})" -m (open --raw $log) }
                  print "flake.lock を commit した。push は手で行う: git push"
                }
                rm $log
                after-switch
              }
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

          # Expose the pinned private downstream for explicit builds as well as Home Manager.
          packages = pkgs.lib.optionalAttrs (system == "aarch64-darwin") {
            ipatool-security-key = pkgs.callPackage ./nix/packages/ipatool-security-key { };
          };

          # Keep false-success and credential-leak regressions in the CI gate (scripts/verify.sh).
          checks = {
            dotfiles-autoswitch = pkgs.runCommand "dotfiles-autoswitch-tests" { } ''
              mkdir -p nix/modules/nixos scripts/tests infra/langfuse/scripts
              cp ${./nix/modules/nixos/mini-vm.nix} nix/modules/nixos/mini-vm.nix
              cp ${./scripts/tests/dotfiles-autoswitch.py} scripts/tests/dotfiles-autoswitch.py
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

            sops-host-identity = import ./nix/tests/sops-host-identity.nix { inherit pkgs; };

            mini-vm-narrow-mounts = import ./nix/tests/mini-vm-narrow-mounts.nix { inherit pkgs inputs; };
          }
          // import ./nix/tests/developer-checks.nix {
            inherit
              pkgs
              system
              inputs
              switchApp
              ;
          }
          // inputs.nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
            sops-migration-config = import ./nix/tests/sops-migration-config.nix { inherit pkgs inputs; };
            sops-host-delivery = import ./nix/tests/sops-host-delivery.nix { inherit pkgs inputs; };

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

            switch = {
              type = "app";
              program = toString switchApp;
            };

            build = mkApp "build" (
              if pkgs.stdenv.hostPlatform.isDarwin then
                ''
                  def --wrapped main [...args: string] {
                    ^${
                      inputs.nix-darwin.packages.${system}.darwin-rebuild
                    }/bin/darwin-rebuild build --flake ".#${username}-${system}" ...$args
                  }
                ''
              else
                ''
                  ${linuxHomeTarget}

                  def --wrapped main [...args: string] {
                    if ("/etc/NIXOS" | path exists) {
                      ^nixos-rebuild build --flake ".#mini-vm" ...$args
                    }
                    ^${homeManager} build --flake $".#(home-target)" ...$args
                  }
                ''
            );

            update = mkUpdate "update" {
              targets = [ ];
              lane = "local";
            };

            # flake-lock-proposal.yaml の fast レーンと同じ input を手元で先取りする。
            update-ai-tools = mkUpdate "update-ai-tools" {
              targets = [
                "llm-agents"
                "claude-code-overlay"
                "cclens"
              ];
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
              def --wrapped main [...args: string] {
                let root = (^${pkgs.git}/bin/git rev-parse --show-toplevel | str trim)
                let key = ($env.HOME | path join ".ssh" "id_ed25519")

                if not ($key | path exists) {
                  print --stderr $"error: ($key) が無い。secrets/secrets.nix の受信者鍵が必要"
                  exit 1
                }

                # 復号に失敗すると age の非 0 終了でここで止まる。空の環境で tofu へ進まない。
                let env_content = (^${pkgs.age}/bin/age -d -i $key $"($root)/secrets/tofu-env.age")
                # 1 行 1 つの KEY=VALUE。値に = が入ってもよいよう、最初の = だけで分ける。
                $env_content
                | lines
                | each {|line| $line | split row --number 2 "=" }
                | where {|kv| ($kv | first) != "" }
                | each {|kv| { ($kv | first): ($kv | get --optional 1 | default "") } }
                | reduce --fold {} {|it, acc| $acc | merge $it }
                | load-env

                # R2 にリージョンは無いが S3 バックエンドが必須項目として要求する。
                # versions.tf の `region = "auto"` と揃えておく。
                $env.AWS_REGION = "auto"
                $env.AWS_DEFAULT_REGION = "auto"

                cd $"($root)/tofu"
                exec ${pkgs.opentofu}/bin/tofu ...$args
              }
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

          # gigun marketplace の plugin 一覧。各ホストで未記載のものを有効にし、消えたものを落とす。
          gigunPlugins = import ./nix/gigun-plugins.nix inputs;

          # agent-skills-nix に渡す skill の上流 (nix/modules/home/agent-skills.nix)。
          skillSources = {
            inherit (inputs)
              ryoppippi-dotfiles
              gigun-plugins
              emil-skills
              unslop
              hallmark
              langfuse-skills
              modern-web-guidance
              yomiyasu
              swift-concurrency-skill
              swift-testing-skill
              swiftui-skill
              ;
          };

          overlays = [
            inputs.claude-code-overlay.overlays.default
            inputs.gigun-plugins.overlays.default
            # direnv の doCheck=false override は撤去した: override はハッシュを変えて
            # 素なら upstream キャッシュから fetch できる direnv を毎回ソースビルドさせ、
            # その結果 checkPhase ハングを踏むという自己誘発ループだった。override 無しなら
            # キャッシュヒットでビルドが走らず、ハングも起きない。
          ];

          # 第 2 引数は**役割**。アーキテクチャとは別の軸として明示的に渡す。
          #   alwaysOn: 24/365 で置きっぱなしにする拠点か。人が前に座っていないので、
          #             落ちても誰も気づかない。だから証拠を残す番人 (network-watchdog)
          #             を入れる対象になる。
          #
          # 今の darwin ホストは Pro だけで、alwaysOn のホストは無い。Intel mini の
          # macOS は Nix から外して Ansible が持つ (docs/mini-ansible.md)。常時起動の
          # Apple Silicon 機を足す日は、新しい aarch64-darwin ホストとして alwaysOn を
          # 付ける。番人の有無を arch で分岐させないのはこのため (常時起動かどうかは
          # 買った機械の CPU と関係が無い)。
          # ⚠️ そのホストを足すときは switch の自動選択も見直す。キーは
          # `${username}-${system}` なので、2 台目の aarch64-darwin は Pro と衝突する。
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
            }:
            inputs.nix-darwin.lib.darwinSystem {
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
                ./nix/modules/darwin/nh-clean.nix
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
                      llmAgents = llmAgentsFor system;
                      cclens = cclensFor system;
                      t3Limits = t3LimitsFor system;
                      inherit skillSources;
                      inherit gigunPlugins;
                    };
                    users.${username} = {
                      # nix-secure-enclave-key の upstream `systems` は aarch64-darwin
                      # のみ。darwin 構成は aarch64-darwin だけなので無条件に import する。
                      imports = [
                        ./nix/modules/home
                        inputs.agent-skills.homeManagerModules.default
                        ./nix/modules/home/agent-skills.nix
                        ./nix/modules/home/agent-plugins.nix
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
          # Intel Mac 用の ESP-IDF shell だけを perSystem の外で出す。esp-dev 自身の nixpkgs
          # (x86_64-darwin を持つ版) で組むので、dotfiles の nixpkgs が x86_64-darwin を
          # 外しても評価できる。ホスト構成と switch は出さない (docs/esp-idf.md)。
          devShells.x86_64-darwin.esp-idf = import ./nix/devshells/esp-idf.nix {
            system = "x86_64-darwin";
            espDev = inputs.esp-dev;
          };

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
                      # Homebrew activation is already empty for every Darwin output
                      # (nix/modules/darwin/homebrew.nix); also keep brew-bundle inert here.
                      dotfiles.homebrew.bundleAfterSwitch = false;
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
                llmAgents = llmAgentsFor "x86_64-linux";
                cclens = cclensFor "x86_64-linux";
                t3Limits = t3LimitsFor "x86_64-linux";
                inherit skillSources;
                inherit gigunPlugins;
              };
              modules = [
                ./nix/modules/home
                inputs.agent-skills.homeManagerModules.default
                ./nix/modules/home/agent-skills.nix
                ./nix/modules/home/agent-plugins.nix
              ];
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
                modules = [
                  (
                    { config, lib, ... }:
                    let
                      ensureSopsUserIdentity = base.pkgs.writeShellApplication {
                        name = "ensure-sops-user-identity";
                        runtimeInputs = [
                          base.pkgs.age
                          base.pkgs.coreutils
                        ];
                        text = builtins.readFile ./scripts/ensure-sops-host-identity.sh;
                      };
                      sopsUserIdentityPath = "${config.xdg.configHome}/sops/age/keys.txt";
                    in
                    {
                      home.packages = base.pkgs.lib.mkForce (map replace base.config.home.packages);
                      home.activation.ensureSopsUserIdentity = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
                        $DRY_RUN_CMD ${ensureSopsUserIdentity}/bin/ensure-sops-user-identity ${lib.escapeShellArg sopsUserIdentityPath}
                      '';
                    }
                  )
                ];
              };
          };
        };
    };
}
