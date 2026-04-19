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

## 落とし穴 (Gotchas)

Windows 環境で遭遇したハマり所と解決策。設定ファイル側にも該当箇所にコメント付き。

### キーボード remap
- **Fn キーは OS 層に届かない**: ノート PC の Fn はファーム処理で Scancode Map/AHK/Kanata いずれでも remap 不可。MBP の Karabiner でも同じ
- **Scancode Map は HWID フィルタ不可**: 全キーボード共通適用。device 別 remap は Kanata + Interception 必須 (不採用方針のため、1 デバイスに絞る設計)
- **Scancode Map バイナリフォーマット**: `8-byte header (0) + 4-byte count (N+1) + N*4-byte mappings + 4-byte terminator (0)`。mapping は `[out VK low][out VK high][in VK low][in VK high]` の little-endian 4 bytes。count = mappings 数 + 1 (terminator 込)
- **未割当キーへの退避**: 物理 LWin を Scancode Map で `F13` (未割当) に逃がすと Windows の `Win+C`/`Win+V` 等が AHK 未起動時も絶対発火しない。AHK で `F13 & key` を拾って任意の操作にマップ可能
- **Custom combination hotkey の foreground lock**: `F13 & Space::` 等は modifier を保持したまま処理されるため `WinActivate` が失敗する。`KeyWait "Space"` でキー release を待つのが鉄板

### WezTerm
- **`window_background_opacity` が効かない**: WebGpu + dual-GPU + Windows 11 の既知 regression (GitHub wezterm/wezterm #4502 #5790 #6265 #6359)。対処:
  1. `front_end = 'OpenGL'` + `prefer_egl = true` (ANGLE 経由で DX11)
  2. WezTerm を iGPU 強制 (`HKCU\Software\Microsoft\DirectX\UserGpuPreferences` で `GpuPreference=1;`) — DWM と同じ GPU に揃えることで cross-adapter alpha 欠落を回避
- **`INTEGRATED_BUTTONS` が消える**: `hide_tab_bar_if_only_one_tab = true` だと 1 タブ時にタブバーごと隠れ、統合ボタンも消える → `false` にする
- **Hotkey Window (iTerm2 風)**: `WinMinimize`/`WinRestore` は Windows 11 の foreground lock に阻まれて再呼出しでちらつくだけで前面化しない。`WinHide`/`WinShow` は hidden window の特性で foreground lock を迂回できる (タスクバーからも消える)。併用必須: `#WinActivateForce` + `SPI_SETFOREGROUNDLOCKTIMEOUT=0` + `ForegroundLockTimeout` Registry=0 + `KeyWait` + 失敗時 `SwitchToThisWindow` フォールバック
- **分割方向の用語**: `direction = 'Right'` = 左右分割 (iTerm2 の Vertical Split)、`direction = 'Down'` = 上下分割 (Horizontal Split)。日本語の「垂直分割」と混同注意
- **設定変更の反映**: `automatically_reload_config = false` にしてあるため wezterm.lua を編集したら `wezterm-gui.exe` を kill → 再起動

### Windows 視覚効果
- **`VisualFXSetting = 2` (パフォーマンス優先) は透明効果を system-wide で無効化**: WezTerm 等の透過も描画されなくなる。`3` (Custom) + `EnableTransparency = 1` の組合せで個別設定を尊重
- **DWM キャッシュ**: 透明効果の Registry を変えても反映されない時は Explorer 再起動 (`taskkill /f /im explorer.exe && start explorer`) で DWM リセット
- **Foreground lock (Win11 は特に強い)**: 他プロセス発の `SetForegroundWindow` が阻まれる。AHK 公式の対策セットは上記 Hotkey Window 節参照

### MS IME
- **ライブ変換は Windows 11 標準 MS IME にない**: macOS の live conversion (azooKey 風) は標準未提供。Mozc 等 OSS も同等機能なし。azooKey Windows 版は未リリース (2026-04 時点)
- **無変換/変換 → IME Off/On**: 設定 → 言語 → 日本語 → Microsoft IME → キーとタッチのカスタマイズ で可能だが Registry 宣言化 path が未特定 (TODO)

### dual-GPU (NVIDIA Optimus 系)
- **DWM は iGPU で動作**: アプリが dGPU で描画すると DXGI surface の cross-adapter 共有で alpha が欠落する既知バグ (WezTerm 透過失敗の根源)
- **WezTerm のような軽量 GUI は iGPU で十分**: `GpuPreference=1` (Power saving) で固定が安定。`2` (High performance) だと透過が壊れるだけで描画性能メリットなし

### WSL ↔ Windows の境界
- **環境変数の継承は WSLENV だけ**: Windows 側の env を WSL に渡すには `WSLENV` 環境変数に列挙が必要 (例: `WT_SESSION:WT_PROFILE_ID::TERM:COLORTERM:TERM_PROGRAM:TERM_PROGRAM_VERSION`)。WezTerm は WSLENV を設定しないので `WEZTERM_PANE` 等は WSL 内で空 → `.zshrc` で OSC 7 シェル統合の判定を `WEZTERM_PANE` ベースにすると WSL では発動しない。**判定撤廃して常時送信が無難** (対応外ターミナルは escape を無視)
- **`TERM` は WSL 内で `xterm-256color` になりがち**: WezTerm がデフォルトで `wezterm` を設定しても WSL の login shell で上書きされる。`TERM=wezterm*` 判定も WSL では効かない
- **git credential は OS ごとに別**: Windows GCM (DPAPI) と WSL の credential helper は別ストア。`gh CLI` を helper に統一すれば全 OS で `gh auth login` 1 回で完結
- **chmod は WSL native (`~/`) のみ有効**: `/mnt/c/` 以下の Windows ファイルは drvfs 経由で chmod が反映されない (NTFS permission は別仕様)

## 未対応 / 今後

- `kanata` サービス登録の自動化（DSC Script に追加）
- `kanata` を Anker 限定化（Interception ドライバ + HWID フィルタ、または接続検出）
- WSL 初回構築の自動化（`wsl --install` + dotfiles clone + `nix run .#switch`）
- ターミナルキーバインドの整合（Kanata / WezTerm / WSL 内 zsh）
