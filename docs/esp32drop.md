# ESP32Drop 比較用 Arduino 環境

ESP-IDF 6.1 の `esp-idf` devShell と独立した、Apple Silicon macOS 用の環境。
グローバルの `switch`、既存 `Arduino15`、`Documents/Arduino` は使わない。
対象は [ESP32Drop](https://github.com/s-iwaki-d/ESP32Drop) の upstream 比較ビルド。
Arduino builtin の `ctags` は x86_64 バイナリなので **Rosetta 2 が必要**。
この setup は Rosetta を自動インストールしない。mkspiffs / dfu-util も Intel 配布物を含むが、
今回の通常 compile で全ツールを実行するわけではない。

## 再現手順

dotfiles で実行する。初回 setup は公式 core が要求する他 SoC のツールも含めて取得するため、
約 1.7 GB のダウンロードと展開後の空き容量が必要。

```sh
nix develop .#esp32drop --command esp32drop-setup
nix develop .#esp32drop --command esp32drop-build \
  /Users/gigun/ghq/github.com/s-iwaki-d/ESP32Drop
```

未追跡ファイルを含む変更を評価する間は `.#esp32drop` の代わりに
`path:/Users/gigun/ghq/github.com/gigun-dev/dotfiles#esp32drop` を使う。
`flake.lock` の更新や Git index の操作は不要。

`esp32drop-build` は `PrintReceivedFiles` / `ShowReceivedImage` / `GreetingCard` を
順に clean build する。`--warnings all` と `-Wshadow` を付ける。
成功はコンパイル・リンクの成功であり、警告ゼロや無線送達の意味ではない。
ログと成果物は `$ESP32DROP_ENV_ROOT/build/ESP32Drop/<board>/<example>{,.log}`。
repo path の後ろに `GreetingCard` などを指定すると、その example だけビルドする。

通常シェルに入り、CLI の読み取り確認を行う例:

```sh
nix develop .#esp32drop
arduino-cli version
arduino-cli --config-file "$ESP32DROP_CONFIG" core list
arduino-cli --config-file "$ESP32DROP_CONFIG" lib list
```

CLI を直接使う場合は `--config-file "$ESP32DROP_CONFIG"` が必須。
`esp32drop-setup` と `esp32drop-build` は自動で指定する。
upstream の `tools/common.sh` は通常の `Arduino15` を指定するため、この独立環境では使わない。

## 固定した依存

| 対象 | 固定値 | 管理場所 |
|---|---|---|
| Arduino CLI | 1.5.1（作成時） | 既存 `flake.lock` の nixpkgs |
| Board core | `m5stack:esp32@3.3.8` | `nix/devshells/esp32drop/package_m5stack_index.json` |
| M5Unified | 0.2.21 | `nix/devshells/esp32drop/library_index.json` |
| M5GFX | 0.2.28 | 同上、M5Unified が要求する `>=0.2.28` を満たす版 |
| Arduino builtin tools / dfu-util | index 内の明示版 | `nix/devshells/esp32drop/package_index.json` |

CLI は既存 nixpkgs のソース・バイナリ pin に従うため、将来の dotfiles lock 更新で版が変わる。
core とライブラリの版は index を意図的に変更しない限り変わらない。
system と index 3 個・CLI version の hash を cache path に含めるため、更新後の環境が旧版と混ざらない。

core が要求する依存は省略していない。`esp-x32` / `esp-rv32` 2601、GDB 16.3_20250913、
OpenOCD v0.12.0-esp32-20251215、esptool 5.2.0、mkspiffs 0.2.3、mklittlefs 4.0.2-db0513a、
9 SoC の `*-libs` 3.3.8、dfu-util 0.11.0-arduino5 を含む。

2026-09-07 に以下の公式 index から、対象 core 版・その toolsDependencies・M5 ライブラリ 2 版を抽出。
package index のホスト候補は macOS のみに絞った。CLI が選ぶ builtin tools の版も snapshot 内で固定。

- [M5Stack package index](https://static-cdn.m5stack.com/resource/arduino/package_m5stack_index.json)
- [Arduino package index](https://downloads.arduino.cc/packages/package_index.tar.bz2)
- [Arduino library index](https://downloads.arduino.cc/libraries/library_index.tar.bz2)

各エントリには公式の URL / archive filename / byte size / SHA-256 を保持している。
setup は `core update-index` / `lib update-index` を呼ばず、同梱 snapshot を cache にコピーしてから
明示版を install する。配布物は Arduino CLI が index の checksum と照合する。
ライブラリは `--no-deps` で 2 個とも明示し、将来の依存解決へ委ねない。

## ボードと実機境界

既定 FQBN は upstream と同じ StopWatch:

```text
m5stack:esp32:m5stack_stopwatch:PartitionScheme=huge_app,PSRAM=opi,DebugLevel=error,USBMode=default,CDCOnBoot=cdc,UploadMode=cdc
```

別ボードは `FQBN` 環境変数で変更できるが、StopWatch の成功を CoreS3 の成功とは扱わない。
core 3.3.8 の `boards.txt` と CLI `board details` で確認した CoreS3 向けの例:

```sh
FQBN='m5stack:esp32:m5stack_cores3:PSRAM=enabled,PartitionScheme=huge_app,FlashSize=16M,DebugLevel=error,USBMode=default,CDCOnBoot=cdc,UploadMode=cdc' \
  nix develop .#esp32drop --command esp32drop-build \
    /Users/gigun/ghq/github.com/s-iwaki-d/ESP32Drop GreetingCard
```

Flash 16 MB / QSPI PSRAM、3 MB app 領域の設定。`huge_app` は残り全 16 MB を活用する
partition layout ではないが、upstream と同じ app 容量で比較するため選ぶ。
2026-09-07 訂正: CoreS3 は公式 `PSRAM=enabled`（QSPI）で実機動作・転送を確認。
初回例の `opi` は誤りだった。StopWatch の既定 `PSRAM=opi` は維持する。
この環境のセットアップと build はポートの検出・monitor・flash を行わない。
書き込みには別途、対象機体・確認済みポートとユーザー承認が必要。

## 検証記録

2026-09-07: Apple Silicon macOS、upstream commit
`92bdc1221924ca522f3ccbebbd9353612ce5b2d7` で検証。

| ボード / example | program storage | 静的 RAM | 結果 |
|---|---:|---:|---|
| StopWatch / PrintReceivedFiles | 1,018,215 B | 119,228 B | clean build 成功 |
| StopWatch / ShowReceivedImage | 1,266,535 B | 122,576 B | clean build 成功 |
| StopWatch / GreetingCard | 1,354,259 B | 127,108 B | clean build 成功 |
| CoreS3 / GreetingCard | 1,354,275 B | 127,108 B | clean build 成功 |

3 例とも upstream `lint.sh` の fatal-warning 分類に該当する自前コードの警告は 0。
他の警告はある。全 library translation unit の `compile_commands.json` で
`-Wshadow` と `@build_opt.h` が併存し、GreetingCard のみ `-DESP32DROP_SENDER` を含むことを確認。
GreetingCard ELF に `ad_send` / `ad_sender_begin` がリンクされていることも確認した。

26 個の取得 archive、計 1,652,256,437 B は CLI install 成功に加え、独立した SHA-256 と
byte size の再計算で全件 index と一致。setup 再実行は全対象が `already installed`。
`nix flake check` は評価・treefmt・pre-commit build とも成功。
CoreS3 版も sender define / `ARDUINO_M5STACK_CORES3` / `BOARD_HAS_PSRAM` の全 library 適用と、
`flash_args` の `--flash-size 16MB` を確認。fatal-warning 分類の自前警告は 0。

初回 StopWatch 検証は board 別出力導入前のためログは以下の直下にある。
再実行時は前述の `<board>` 配下に保存される。

```text
~/.cache/esp32drop/aarch64-darwin/152bd622e89c9a662b1d1225e6df4af982cb34992d8c9560f92aa13c37d441cd/build/ESP32Drop/
```

補足証拠: `/tmp/esp32drop-arduino-setup.log`、`/tmp/esp32drop-arduino-setup-repeat.log`、
`/tmp/esp32drop-download-checksums.log`、`/tmp/esp32drop-sender-flags.log`。
flash、BLE/Wi-Fi 実行、相手端末への転送は行っていない。
