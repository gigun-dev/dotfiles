#!/bin/sh
# =============================================================================
# CI と同じ検証を手元で走らせる。pre-push フックの実体でもある。
# =============================================================================
#
# 【なぜスクリプトに切り出すか】
#   同じ検証を CI (.github/workflows/nix-build.yaml) と pre-push の 2 か所に
#   直書きすると、片方だけ直したときに黙って食い違う。実際に旧フック
#   (harness-template v0.4.0) は `nix flake check --no-build` を直書きしており、
#   「--no-build を付けないこと」と明記した CI と食い違ったままだった。
#   → docs/adr/0002-run-the-ci-check-from-pre-push-via-scripts-verify.md
#
# 【CI との差 —— ここは揃っていない】
#   CI は ubuntu (x86_64-linux) で走るので、この 2 コマンドに加えて
#   nixosConfigurations.mini-vm と homeConfigurations の**実ビルド**まで見る。
#   手元 (aarch64-darwin) の `nix flake check` は評価対象を現在のシステムに絞るため
#   (`warning: The check omitted these incompatible systems: ...` が出る)、
#   Linux 側のビルド失敗はここでは捕まらない。**手元の関門は「壊れた main を
#   事故で push しない」ためのもので、mini-vm へ届く保証は CI 側が持つ。**
#   Why not --all-systems: darwin から Linux の実ビルドはできない (リモートビルダが要る)。
#
# 【所要時間】2026-09-10 実測 (M4 Pro・キャッシュ温): flake check 20 秒 + fmt 8 秒。
#   `--no-build` を付けると 12 秒になるが、CI と揃える価値の方が大きいので付けない。
set -eu

# 関門の生死を確かめるための口。pre-push が本番と同じ exec でこのスクリプトを呼び、
# ここで返す失敗が Git まで届いて push を止めることを確かめる。
# Nix コマンド自体の失敗処理はこの自己テストの検証範囲に含まない。
if [ -n "${VERIFY_FORCE_FAIL:-}" ]; then
	echo "verify: VERIFY_FORCE_FAIL が立っているので、意図的に失敗します (関門の自己テスト)"
	exit 1
fi

# `nix flake check` に --no-build を付けないこと。ESP-IDF の devShell は
# `builtins.readFile "${src}/tools/tools.json"` でソースを読む (IFD) ため、
# 評価に fetch が要る。--no-build だとそれが禁じられ、x86_64-linux では
# `error: path '...-source.drv' is not valid` で必ず落ちる (CI 側にも同じ注記がある)。
nix flake check
nix fmt -- --ci .
