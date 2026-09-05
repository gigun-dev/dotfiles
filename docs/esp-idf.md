# ESP-IDF開発環境

SDK・toolchain・Python本体・uvは `nix/devshells/esp-idf.nix` と `flake.lock` で管理する。
Pythonパッケージは `nix/devshells/esp-idf-python/pyproject.toml` と `uv.lock` で管理する。
ESP-IDF 6.1 / Xtensaを固定し、ESP32 / S2 / S3の開発に使う。
公式stable: https://github.com/espressif/esp-idf/releases/tag/v6.1 （2026-09-05確認）。
グローバルPATHへの導入や `nix run .#switch` は不要。開発時に環境へ入る。

```sh
# dotfiles checkout内
nix develop .#esp-idf

# firmwareプロジェクト内から、dotfilesの環境を指定
nix develop /absolute/path/to/dotfiles#esp-idf --command idf.py --version
```

別のMac/Linuxでも同じdotfilesコミットをcheckoutして同じコマンドを使う。
shellに入ると `uv sync --locked` が端末のcache内へPython環境を作る。
初回はネット接続が必要。通常の起動で依存を更新せず、lockのhashごとに環境を分ける。
Nixはホスト用のcompilerバイナリを選択する。ファームの対象は別途
`idf.py set-target esp32s3` などで選ぶ。ビルドディレクトリは各ホストで作り直す。

対象は `aarch64-darwin` / `x86_64-darwin` / `x86_64-linux` / `aarch64-linux`。
Intel MacのOS設定が凍結されていても、この開発shellは上流の25.11 nixpkgsを使う。
ARM Linux用の開発shellを追加したが、Home Managerのホスト設定を追加したわけではない。

LinuxのUSBアクセスはホスト側のdialout/udev等で設定する。WSL/LimaではUSB転送も
別途必要。shellはroot権限やdevice権限を変更しない。

## 固定範囲と更新

- `flake.lock`: esp-devと専用nixpkgs（Python本体・uvを含む）のリビジョン。
- `esp-idf.nix`: SDKのtagとサブモジュールを含むソースhash。
- SDKの `tools/tools.json`: OS別toolchainの版・ダウンロードhash。
- `esp-idf-python/uv.lock`: Pythonの直接・間接依存と配布物hash。
- `esp-idf-python/espidf.constraints.v6.1.txt`: 2026-09-05取得の公式条件スナップショット。

公式条件の取得元: https://dl.espressif.com/dl/esp-idf/espidf.constraints.v6.1.txt

上流は `mirrexagon/nixpkgs-esp-dev`。dotfilesのnixpkgsをfollowsさせない理由は
native toolsの基盤とIntel Mac対応を維持するため。グローバルなoverlayは追加しない。
上流のPython依存は5.5用で更新が遅いため使わない。uvが公式6.1条件内で解決した
パッケージを配置し、shell起動時にSDK自身のcheckerで保存した公式条件を検査する。
NixはOS別バイナリのhash検証・Linuxのライブラリ補正に使い、PyPIの追従はuvに任せる。
この環境は完全なNix store内のclosureではなく、Python部分にuv管理の書き込み可能cacheを持つ。

SDK更新では公式stable releaseを確認し、tag/hashとPython宣言・公式条件を更新する。
`nix flake update esp-dev` だけではSDK版は変わらない。Pythonの更新には
`uv lock --project nix/devshells/esp-idf-python --upgrade --python 3.13` を使う。
上流Nixの更新はnative toolsの互換対応が必要な場合に行う。
Macで実ビルド、各OSのderivation評価、可能ならLinuxでも実ビルドを行う。
他ホストへ共有する際は宣言とlockを同じコミットに含める。

## PoCからの利用

`esp32-airdrop-poc/tools/with-idf.sh` はghqからdotfilesを探す。
checkout位置が違う場合のみ `DOTFILES_ROOT` を指定する。
古い `.idf-env.local` やCodex作業フォルダへの依存は廃止。
以前の手動導入物は今回削除せず、必要な成果物の確認後に別途整理する。

## 6.1 + uv環境の検証（2026-09-05）

- Apple Silicon MacでSDK 6.1.0 / GCC 15.2.0 / Python 3.13.9 / esptool 5.4.0の起動成功。
- PoCの `bash tools/idf.sh set-target esp32s3 build` に成功。出力は `build/nix-6.1/`。
- SDKの公式条件checkerと `uv pip check` が成功。Pythonの6テストも成功。
- 2回目のshell起動は既存の65パッケージを監査するだけで再インストールなし。
- Mac/LinuxのARM64・x86_64向けNix評価が成功。Linux・Intel Macの実ビルドは未実施。
- 環境構築時点ではOS全体のswitchと実機書き込みは未実施。
- 後続のCoreS3実機検証では6.1既定PicolibcでUSBログ停止を確認。PoC側で
  `CONFIG_LIBC_NEWLIB=y` を選ぶと起動・AWDL受信が成功した（約84秒、566フレーム）。
  libc選択はファームのsdkconfig.defaultsの責務。dotfilesのSDKは6.1を維持する。
  詳細: https://github.com/gigun-dev/esp32-airdrop-poc/blob/main/docs/hardware-validation.md

## 旧5.5.1環境の検証（2026-09-05）

Apple Silicon MacでこのshellからESP-IDF 5.5.1 / GCC 14.2.0 / esptool 4.9.0の
起動と、ESP32-S3 PoCのclean buildに成功。SDK・compiler・PythonはNix storeを参照する。
他の3プラットフォームはderivationの評価まで成功し、実ビルドは未実施。

Pythonの6テストはshell内で成功。macOS 26.5.2では同梱ClangのASanが初期化中に
停止したため、CのASan/UBSan検査（不正入力100000件）はshell外のApple Clangで実行し成功。
ホスト側のsanitizer実行にはこの制限があり、ESP32向けビルドとは分けて扱う。
