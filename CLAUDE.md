# Dotfiles

gigun の macOS 開発環境を宣言的に管理する dotfiles。
nix-darwin + home-manager を基盤とし、nix なしでも最低限動作する設計。

## コマンド

```bash
git add . && nix run .#switch  # 変更を適用
nix run .#build                # ビルドのみ（適用しない）
nix run .#update               # flake update + switch
```

**重要**: nix は git index から評価するため、`nix run .#switch` の前に必ず `git add` すること。

## 対象マシン

| マシン | アーキテクチャ | Nix |
|--------|-------------|-----|
| Mac Mini (Intel) | x86_64-darwin | 標準 nix |
| MacBook Pro (M4 Pro) | aarch64-darwin | 標準 nix |

`darwinConfigurations` はアーキテクチャ別に生成し、`nix run .#switch` が perSystem で自動選択する。

## ディレクトリ構造

```
├── flake.nix                # エントリポイント
├── bootstrap.sh             # nix なしの初期セットアップ
├── nix/modules/
│   ├── darwin/
│   │   ├── system.nix       # macOS 設定（nix.settings, TouchID, system.defaults）
│   │   └── homebrew.nix     # casks / brews
│   └── home/
│       ├── default.nix      # home-manager エントリ
│       ├── packages.nix     # home.packages（グローバル CLI）
│       ├── dotfiles.nix     # シンボリックリンク（mkOutOfStoreSymlink + home.activation）
│       └── programs/
│           ├── zsh/         # programs.direnv（programs.zsh は nix-darwin 側で管理）
│           └── git/         # programs.git + programs.delta
├── zsh/
│   ├── .zshrc               # メイン設定（nix 非依存）
│   └── functions/            # zsh 関数（ghq_fzf 等）
├── sheldon/plugins.toml      # sheldon プラグイン定義
└── zeno/config.yml           # zeno snippets
```

## 設計原則

- **nix はオプション強化レイヤー**: 設定ファイル自体は nix に依存しない
- **bootstrap.sh と dotfiles.nix は同じことをする**: 後者が前者を自動化するだけ
- **brew は GUI アプリのみ**: CLI ツールは nixpkgs、tap 限定の例外のみ brews
- **cleanup = "zap"**: 宣言外のアプリは完全削除。使う GUI アプリは必ず casks に宣言する
- **ensure_installed パターン**: ツールが未インストールなら静かにスキップ
- **`~/.local/bin` は例外レーン**: PATH 末尾に追加（nix/brew が常に優先）。self-update 前提のツールや nixpkgs にない uv tool 等、宣言管理できないものだけ許容する

## Nix 規約

- **標準 nix を使用**: Determinate Nix は使わない（ryoppippi パターン）
- **nix.settings で全て宣言**: trusted-users, キャッシュ, experimental-features 等
- **フォーマット**: `treefmt`（nixfmt）を使用
- **nixpkgs.follows を全 input で統一**: キャッシュ共有を最大化
- **useGlobalPkgs = false**: overlay との整合性（flake.nix で設定）
- **mkOutOfStoreSymlink**: nix store にコピーせず dotfiles リポを直接参照
- `.zshrc` は `home.activation` で強制リンク（`programs.zsh` は home-manager 側では使わない）
- **AI ツール**: claude-code は ryoppippi overlay、codex 等は llm-agents overlay（`pkgs.llm-agents.*`）

## Zsh 規約

- **sheldon キャッシュ**: `plugins.toml` の mtime でキャッシュ再生成 + `zcompile`
- **config キャッシュ**: ツール init 出力を `$XDG_CACHE_HOME/zsh/config.zsh` にキャッシュ + `zcompile`
- **deferred compinit**: `zsh-defer` で遅延実行
- **nix store パスを .zshrc に書かない**: ポータビリティのため
- **chpwd フック**: cd 時に `eza -hlF` で自動 ls

## Git ワークフロー

- メインブランチ: `main`
- サブエージェントを活用すること

## 参考

- [ryoppippi/dotfiles](https://github.com/ryoppippi/dotfiles)
- [mozumasu/dotfiles](https://github.com/mozumasu/dotfiles)
