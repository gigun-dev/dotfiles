{
  config,
  pkgs,
  lib,
  llmAgents, # inputs.llm-agents.packages.${system} (flake.nix の extraSpecialArgs)
  cclens, # inputs.cclens.packages.${system}.default (同上)
  ...
}:
{
  home.packages =
    with pkgs;
    [
      # JS / Python runtime
      nodejs
      bun
      # deno は nixpkgs だと rusty-v8 フルビルドで重いため mise に移譲
      pnpm
      uv

      # AI
      claude-code # ← claude-code-overlay (ryoppippi)
      # llm-agents は overlay 経由だと自 nixpkgs で再ビルドされ numtide キャッシュに
      # ヒットしないため standalone packages を直接参照 (llmAgents = extraSpecialArgs)。
      llmAgents.opencode
      # cclens: Claude Code のセッション transcript を解析する診断ツール (Rust)。
      # llm-agents と同じく follows せず standalone 参照で cclens.cachix.org に当てる
      cclens
      # ccstatusline は bunx/npx で足りるため nix pin をやめた (軽量・常駐でない)
      # agent-browser は chrome-devtools-mcp に一本化したため撤去

      # Nix
      cachix # 個人キャッシュ (gigun.cachix.org) への push に必須。初回 `cachix authtoken <token>`

      # Git
      gh
      ghq

      # Search / files
      ripgrep
      fd
      fzf
      eza
      bat
      zoxide
      jq

      # Shell
      zsh
      sheldon
      vivid

      # Dev
      mise
      ffmpeg

      # DB client (server は都度 Docker / nix shell で起動)
      mariadb.client # mysql CLI (Oracle MySQL 互換)
      postgresql_17 # psql + サーババイナリ同梱 (常駐させず spot 起動)
      # dbcli: 補完 + ハイライト強化版 CLI (mysql/postgres/sqlite で操作感共通)
      mycli
      pgcli
      litecli
    ]
    ++ lib.optionals pkgs.stdenv.isDarwin [
      # iOS / Swift 開発 — darwin 限定
      cocoapods
      xcodegen # project.yml から .xcodeproj 生成
      swiftformat # Swift フォーマッタ
      swiftlint # Swift リンタ
      idb-companion # iOS Simulator 自動操作の gRPC companion。CLI 側 fb-idb は nixpkgs に無く uv 管理 (uv tool install fb-idb)
    ]
    ++ lib.optionals (!(pkgs.stdenv.isDarwin && pkgs.stdenv.isx86_64)) [
      llmAgents.codex # Intel Mac のみ brew cask (Rust build 回避)、それ以外は nix
      # agy (Google Antigravity CLI)。公式バイナリを $out/bin/agy に置くだけでソースビルド無し。
      # 同じ条件だが理由は別: llm-agents が x86_64-darwin を未収録のため Intel Mac Mini では入らない
      # (上流 Google には darwin-x64 バイナリが存在するので、必要になったら llm-agents へ PR)
      llmAgents.antigravity-cli
    ]
    ++ [

      # Font
      nerd-fonts.jetbrains-mono

      # Editor
      neovim
    ];
}
