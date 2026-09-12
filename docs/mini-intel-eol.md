# Mac Mini (Intel) の打ち切り対応

> 旧 `docs/next-directions.md`(2026-09-10 に廃止)の棚卸し(2026-09-08)で正典から降ろした。決着済みの経緯。

**背景**: nixpkgs 26.11 が x86_64-darwin を drop し、`nix run .#switch` が eval すら通らなくなった
(実際 mini は 2026-04-25 の generation 26 で止まっていた)。26.05 への固定で延命するには
nixpkgs / home-manager / nix-darwin の3つを固定する必要があり、しかも llm-agents が x86_64-darwin
非対応なので AI ツールは結局入らない。2026年末で切れる延命に複雑度を払わないと判断した。

**採った構成**: macOS を温存したまま Lima ゲスト (NixOS) を常駐させ、エージェント環境だけを移した。
T2 機のネイティブ Linux 化 (デュアルブート) は Activation Lock 解除と Secure Boot 無効化が要り、
かつ有線 LAN 未接続で Wi-Fi (BCM4364) 依存になるためリスクが高く、採らなかった。

**残る選択肢**: Xcode 26.4 以降は macOS Tahoe 26.2 必須なので、mini の Xcode は 26.3 が上限。
それが問題になる日が来たら macOS を残す理由は iPhone バックアップだけになるので、ネイティブ
NixOS 化を再検討してよい。t2linux の NixOS サポートは現役 (nixos-hardware の `apple/t2`、
kernel 6.18 LTS / 7.0 に追従)。
