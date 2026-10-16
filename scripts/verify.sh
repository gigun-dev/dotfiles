#!/bin/sh
# =============================================================================
# CI の検証本体。CI (.github/workflows/nix-build.yaml) が呼び、手元でも同じものを叩ける。
# =============================================================================
#
# 【なぜスクリプトに切り出すか】
#   検証を workflow に直書きすると、手元で同じことを確かめる手段が workflow の写しになり、
#   片方だけ直したときに黙って食い違う。実際に旧 pre-push フック (harness-template v0.4.0) は
#   `nix flake check --no-build` を直書きしており、「--no-build を付けないこと」と明記した
#   CI と食い違ったままだった。
#   pre-push の関門は撤去した (docs/adr/0011-*)。いま main を守るのは push 後の CI と、
#   CI green の commit しか適用しない mini-vm の dotfiles-autoswitch。
#
# 【手元で走らせたときの CI との差】
#   CI は ubuntu (x86_64-linux) で走るので、この検証に加えて
#   nixosConfigurations.mini-vm と homeConfigurations の**実ビルド**まで見る。
#   手元 (aarch64-darwin) の `nix flake check` は評価対象を現在のシステムに絞るため
#   (`warning: The check omitted these incompatible systems: ...` が出る)、
#   Linux 側のビルド失敗はここでは捕まらない。
#   Why not --all-systems: darwin から Linux の実ビルドはできない (リモートビルダが要る)。
#
# 【所要時間】2026-09-10 実測 (M4 Pro・キャッシュ温): flake check 20 秒 + fmt 8 秒。
#   `--no-build` を付けると 12 秒になるが、CI と揃える価値の方が大きいので付けない。
set -eu

# `nix flake check` に --no-build を付けないこと。ESP-IDF の devShell は
# `builtins.readFile "${src}/tools/tools.json"` でソースを読む (IFD) ため、
# 評価に fetch が要る。--no-build だとそれが禁じられ、x86_64-linux では
# `error: path '...-source.drv' is not valid` で必ず落ちる (CI 側にも同じ注記がある)。
python3 scripts/tests/dotfiles-autoswitch.py
python3 scripts/tests/lock-propose-heartbeat.py
python3 -W error scripts/tests/job-heartbeat.py
python3 -W error scripts/tests/job-heartbeat-activation.py
python3 -W error scripts/tests/job-heartbeat-registration.py
python3 scripts/tests/codex-bridge-refresh.py
python3 scripts/tests/bark-routing.py
python3 -W error scripts/tests/codex-mcp-login.py
python3 -W error scripts/tests/uv-sync-tools.py

nix flake check
nix fmt -- --ci .
