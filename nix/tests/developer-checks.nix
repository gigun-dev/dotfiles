{
  pkgs,
  system,
  inputs,
  applySwitch,
}:
let
  inherit (pkgs) lib;
  src = ../..;
  python = "${pkgs.python3}/bin/python3";
  fixture = inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      ../modules/home/guard.nix
      {
        home.username = "fixture";
        home.homeDirectory = "/tmp/guard-fixture";
        home.stateVersion = "26.05";
        home.file.".zprofile".text =
          inputs.self.darwinConfigurations.gigun-aarch64-darwin.config.home-manager.users.gigun.home.file.".zprofile".text;
      }
    ];
  };
  files = lib.listToAttrs (
    map (file: lib.nameValuePair file.target file) (
      lib.filter (
        file:
        builtins.elem file.target [
          ".npmrc"
          ".bunfig.toml"
          ".config/.bunfig.toml"
          ".config/uv/uv.toml"
          ".config/pip/pip.conf"
          "Library/Application Support/pip/pip.conf"
          ".zprofile"
        ]
      ) (builtins.attrValues fixture.config.home.file)
    )
  );
  declarations = pkgs.writeText "guard-declarations.json" (
    builtins.toJSON {
      files = builtins.mapAttrs (_: file: {
        inherit (file)
          enable
          force
          target
          text
          ;
      }) files;
      cleanup =
        inputs.self.darwinConfigurations.gigun-aarch64-darwin.config.homebrew.onActivation.cleanup;
    }
  );
  run =
    name: tests: extra:
    pkgs.runCommand "${name}-tests"
      (
        {
          nativeBuildInputs = [
            pkgs.bash
            pkgs.coreutils
            pkgs.jq
            pkgs.gnused
            pkgs.gnugrep
            pkgs.diffutils
            pkgs.findutils
            pkgs.openssl
            pkgs.python3
          ];
          TEST_PATH = lib.makeBinPath [
            pkgs.bash
            pkgs.coreutils
            pkgs.jq
            pkgs.gnused
            pkgs.gnugrep
            pkgs.diffutils
            pkgs.findutils
            pkgs.openssl
            pkgs.python3
          ];
          TEST_BASH = "${pkgs.bash}/bin/bash";
          TEST_SH = "${pkgs.bash}/bin/sh";
          TEST_SYSTEM = system;
        }
        // extra
      )
      ''
            cp -R ${src} repo
            chmod -R u+w repo
            cd repo
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
        ${lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
          # guard-apply selects BSD stat flags on Darwin; keep that native utility.
          mkdir test-tools
          ln -s /usr/bin/stat test-tools/stat
          export TEST_PATH="$PWD/test-tools:$TEST_PATH"
        ''}
            ${lib.concatMapStringsSep "\n" (
              test: "${python} -I -S -B -W error scripts/tests/${test}.py"
            ) tests}
            touch "$out"
      '';
in
{
  guard-settings = run "guard-settings" [ "guard-settings" "declarations" ] {
    DECLARATIONS = declarations;
  };
  guard-handoff = run "guard-handoff" [ "guard-handoff" ] {
    HM_TEST_ACTIVATION = "${fixture.activationPackage}/activate";
  };
  setup-routing = run "setup-routing" [ "setup-routing" ] { };
  switch-routing = run "switch-routing" [ "switch-routing" ] {
    SWITCH_BODY = pkgs.writeText "apply-switch.sh" applySwitch;
  };
  developer-tools =
    run "developer-tools"
      [
        "execution-context"
        "linux-ci-runner"
        "claude-user-settings"
        "codex-bridge-refresh"
        "bark-routing"
        "codex-mcp-login"
        "uv-sync-tools"
      ]
      {
        CLAUDE_ACTIVATION = pkgs.writeText "claude-link-dotfiles" inputs.self.homeConfigurations.gigun-mini-vm.config.home.activation.linkDotfiles.data;
        CLAUDE_HOME = inputs.self.homeConfigurations.gigun-mini-vm.config.home.homeDirectory;
      };
}
// lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
  zsh-startup = run "zsh-startup" [ "zsh-startup" ] { TEST_ZSH = "/bin/zsh"; };
}
