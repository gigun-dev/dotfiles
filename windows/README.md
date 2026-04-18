# windows/

Windows 11 (x86_64) 向け、**宣言的** 構成。
Mac 側 (`nix run .#switch`) と同じ運用感を **WinGet Configuration** で実現する。

## 前提

- Windows 11 (22000+)
- PowerShell 7+ (未導入なら winget 経由で自動導入される)
- winget 1.6+ (Windows 11 組込版で充足)
- `git` がインストール済 (dotfiles を clone するため)

## 適用

**管理者権限の PowerShell** で:

```powershell
# 1. dotfiles を clone (初回のみ)
mkdir $HOME\ghq\github.com\gigun-dev -Force
cd $HOME\ghq\github.com\gigun-dev
git clone https://github.com/gigun-dev/dotfiles
cd dotfiles

# 2. 宣言的構成を適用
pwsh -ExecutionPolicy Bypass -File .\windows\setup.ps1
```

内部的には以下と等価（setup.ps1 はこれを呼ぶ薄いラッパ）:

```powershell
winget configure --file .\windows\configuration.dsc.yaml --accept-configuration-agreements
```

差分適用（構成更新）は同じコマンドを再実行するだけ。各リソースは冪等（既に目的状態なら no-op）。

## 構成

```
windows/
├── configuration.dsc.yaml  # ★ Single source of truth (宣言的構成)
├── setup.ps1               # winget configure を呼ぶ薄いラッパ
├── README.md
├── fonts/install.ps1       # JetBrains Mono Nerd Font (DSC から呼ばれる)
├── kanata/kanata.kbd       # karabiner.json から移植 (symlink 対象)
├── tailscale/install-daemon.ps1  # Tailscale + unattended mode (DSC から呼ばれる)
├── terminal/wezterm.lua    # WezTerm 設定 (symlink 対象)
└── wsl/wslconfig           # WSL2 設定 (symlink 対象)
```

## configuration.dsc.yaml の中身

| カテゴリ | リソース型 | 例 |
|---|---|---|
| パッケージ | `Microsoft.WinGet.DSC/WinGetPackage` | Git, gh, VSCode, Cursor, Zed, WezTerm, Kanata, Tailscale, Claude, Chrome, Figma, uv |
| Explorer 設定 | `PSDscResources/Registry` | 隠しファイル、拡張子、This PC、チェックボックス |
| UI 抑止 | `PSDscResources/Registry` | Widgets, Copilot, 広告 ID, Start 推奨 |
| パフォーマンス | `PSDscResources/Registry` + `Service` | Visual effects, Fast Startup, SysMain |
| カスタムスクリプト | `PSDscResources/Script` | Hibernation off, 電源プラン, Font 導入, Tailscale, Defender 除外, Symlink |

## 設計原則

- **宣言的 single source of truth**: `configuration.dsc.yaml` が構成の全て。個別 .ps1 は DSC Script から呼ばれる補助
- **winget 一本化**: Scoop / Chocolatey は不採用
- **WSL2 を主力に**: ローカル開発は WSL 内で完結。Git Bash は Claude Code 等のネイティブツールが呼ぶ最小 POSIX 用途のみ（nix / home-manager は動かない）
- **Tailscale**: MSI デフォルト構成 (GUI + daemon) を尊重、Unattended mode 有効化で daemon 単独接続可
- **フォント**: Mac と同じ JetBrains Mono Nerd Font
- **キーボード**: Kanata で karabiner.json 相当を提供。ノート PC 内蔵キーは remap しない方針（Interception + HWID filter または Anker 接続時のみ起動は TODO）

## DSC 適用後の手動ステップ

```powershell
# Tailscale ログイン (ブラウザ認証)
tailscale login
tailscale set --unattended=true

# SSH 鍵を生成 (必要なら)
ssh-keygen -t ed25519 -f $HOME\.ssh\id_ed25519

# WSL2 Ubuntu (DSC でも自動化可能だが初回は対話を挟むので手動推奨)
wsl --install -d Ubuntu
# 初回起動でユーザー作成 → dotfiles clone → home-manager 適用
```

## NVIDIA GPU (該当機のみ)

NVIDIA discrete GPU 搭載機では追加で:

- **Windows ドライバ**: Windows Update で自動。`nvidia-smi.exe` が `C:\Windows\System32\` に入れば OK
- **WSL2 GPU passthrough**: Windows 側ドライバが新しければ WSL 内で `nvidia-smi` が自動で動作（追加インストール不要）
- **CUDA Toolkit**: 必要な時のみ WSL 内で `nix shell nixpkgs#cudaPackages.cuda_cudart` や project-local な `flake.nix` で調達。グローバルには入れない
- **LM Studio / ローカル推論**: VRAM に応じてモデル選択（MX450 2GB なら 7B 4bit が上限目安）

CUDA は project-scoped にするのが筋なので `packages.nix` には入れない。

## 未対応 / 今後

- `kanata` サービス登録の自動化（DSC Script に追加）
- `kanata` を Anker 限定化（Interception ドライバ + HWID フィルタ、または接続検出）
- WSL 初回構築の自動化（`wsl --install` + dotfiles clone + `nix run .#switch`）
- ターミナルキーバインドの整合（Kanata / WezTerm / WSL 内 zsh）
