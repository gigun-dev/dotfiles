# ESP-IDF開発環境

SDK・toolchain・Python依存は `nix/devshells/esp-idf.nix` と `flake.lock` で管理する。
ESP-IDF 5.5.1 / Xtensaを固定し、ESP32 / S2 / S3の開発に使う。
グローバルPATHへの導入や `nix run .#switch` は不要。開発時に環境へ入る。

```sh
# dotfiles checkout内
nix develop .#esp-idf

# firmwareプロジェクト内から、dotfilesの環境を指定
nix develop /absolute/path/to/dotfiles#esp-idf --command idf.py --version
```

別のMac/Linuxでも同じdotfilesコミットをcheckoutして同じコマンドを使う。
Nixはホスト用のcompilerバイナリを選択する。ファームの対象は別途
`idf.py set-target esp32s3` などで選ぶ。ビルドディレクトリは各ホストで作り直す。

対象は `aarch64-darwin` / `x86_64-darwin` / `x86_64-linux` / `aarch64-linux`。
Intel MacのOS設定が凍結されていても、この開発shellは上流の25.11 nixpkgsを使う。
ARM Linux用の開発shellを追加したが、Home Managerのホスト設定を追加したわけではない。

LinuxのUSBアクセスはホスト側のdialout/udev等で設定する。WSL/LimaではUSB転送も
別途必要。shellはroot権限やdevice権限を変更しない。

## 固定範囲と更新

- `flake.lock`: esp-devと専用nixpkgs/Pythonパッケージ群のリビジョン。
- `esp-idf.nix`: SDKのtagとサブモジュールを含むソースhash。
- SDKの `tools/tools.json`: OS別toolchainの版・ダウンロードhash。

上流は `mirrexagon/nixpkgs-esp-dev`。dotfilesのnixpkgsをfollowsさせない理由は
Python依存セットとIntel Mac対応を維持するため。グローバルなoverlayは追加しない。
上流はesptool用ecdsaの限定許可と `IDF_PYTHON_CHECK_CONSTRAINTS=no` を使うため、
SDK更新時は版表示だけでなくファームのclean buildを必ず確認する。

更新は `nix flake update esp-dev` から開始する。SDK版を変える場合はtag/hashも更新し、
Macで実ビルド、各OSのderivation評価、可能ならLinuxでも実ビルドを行う。
他ホストへ共有する際は宣言とlockを同じコミットに含める。

## PoCからの利用

`esp32-airdrop-poc/tools/with-idf.sh` はghqからdotfilesを探す。
checkout位置が違う場合のみ `DOTFILES_ROOT` を指定する。
古い `.idf-env.local` やCodex作業フォルダへの依存は廃止。
以前の手動導入物は今回削除せず、必要な成果物の確認後に別途整理する。
