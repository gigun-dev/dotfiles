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
      # 素の python3。リポジトリの scripts/*.py や git hooks が `python3` を呼ぶため
      # (macOS の /usr/bin/python3 は CLT の古い版)。ライブラリは足さない: プロジェクトは
      # uv venv / uv run で閉じ、グローバルに pip install しない。
      python3

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
      # age: secrets/*.age を実行時に復号する側で要る (claude/hooks/bark-notify.sh)。
      # NixOS は activation で自動復号するが、macOS には agenix モジュールを入れて
      # いないため、tofu ラッパと同じ「その場で復号して環境変数へ」方式を採っている。
      age
      # sops: agenix から移す候補 (値ごとの暗号化で差分が読め、開発の .env にも使える)。
      # 移行はまだで、先に CLI だけ入れて試す。docs/security.md §5 の 4。
      sops

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
      # 旧 uv tool から移した Python CLI (nixpkgs にあるものは uv/tools.txt に置かない)。
      yt-dlp
      # hf CLI。ライブラリの derivation だが bin/hf は wrap 済みで、home.packages は
      # bin を拾うだけなので依存が profile の Python に漏れない。
      python3Packages.huggingface-hub

      # DB client (server は都度 Docker / nix shell で起動)
      mariadb.client # mysql CLI (Oracle MySQL 互換)
      postgresql_17 # psql + サーババイナリ同梱 (常駐させず spot 起動)
      # dbcli: 補完 + ハイライト強化版 CLI (mysql/postgres/sqlite で操作感共通)
      mycli
      pgcli
      litecli
    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
      # iOS / Swift 開発 — darwin 限定
      cocoapods
      xcodegen # project.yml から .xcodeproj 生成
      swiftformat # Swift フォーマッタ
      swiftlint # Swift リンタ
      # Google Cloud SDK (gcloud / gsutil / bq)。Cloud Run デプロイ用。brew cask から移した:
      # CLI は nixpkgs の原則で、cask は brew の python@3.14 を巻き込んでいた。追加 component が
      # 要るときは `gcloud components install` ではなく google-cloud-sdk.withExtraComponents。
      # cask と同じく darwin 限定 (Linux 側で使う予定が無い)。
      google-cloud-sdk
      idb-companion # iOS Simulator 自動操作の gRPC companion。CLI 側 fb-idb は nixpkgs に無く uv/tools.txt で宣言
      # YubiKey は Mac に挿して使うので darwin 限定 (mini-vm は無人、WSL には挿さない)。
      yubikey-manager # ykman: Yubico 公式 CLI。型番確認・OTP 無効化・OATH (TOTP)・PIV の設定
      age-plugin-yubikey # age / sops の受信者に YubiKey (PIV) を使う。docs/security.md
    ]
    ++ lib.optionals (!(pkgs.stdenv.hostPlatform.isDarwin && pkgs.stdenv.hostPlatform.isx86_64)) [
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
