#!/usr/bin/env python3
"""`sync-model-pricing.py` の純関数だけを検める(ネットワークも Langfuse も触らない)。

対象は cf-fireboard の `scripts/sync-model-pricing.test.ts` と同じ切り方 ——
litellm の JSON を Langfuse 向けの形に変換する関数と、matchPattern の衝突検出。
HTTP を叩く `langfuse_client` / `fetch_all_models` / `main` はここでは検めない
(`scripts/tests/worktree-write-guard.py` も hook 本体を subprocess で叩くだけで
ネットワークや実 repo には触らない、という同じ切り方)。

ファイル名にハイフンが入っている(`sync-model-pricing.py`)ため `import` 文では
読めない。`worktree-write-guard.py` の前例は hook を subprocess として叩いて
避けているが、ここは純関数を直接呼びたいので `importlib.util` でパスから
読み込む(標準ライブラリの正攻法。`sys.path` に細工しない)。
"""

import importlib.util
import re
import sys
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "sync-model-pricing.py"
spec = importlib.util.spec_from_file_location("sync_model_pricing", MODULE_PATH)
sync_model_pricing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync_model_pricing)


class BuildMatchPatternTests(unittest.TestCase):
    """`-` や `.` は正規表現のメタ文字なので、素通しするとエスケープ漏れになる
    (`.` は「任意の 1 文字」に化ける ―― 例えば `claude-sonnet-5` 用のパターンが
    `claudexsonnet-5` のような文字列にまで誤って一致しかねない)。"""

    def test_hyphen_is_escaped(self):
        pattern = sync_model_pricing.build_match_pattern("claude-opus-5-5")
        self.assertEqual(pattern, r"(?i)^claude\-opus\-5\-5$")

    def test_exact_match_only(self):
        pattern = sync_model_pricing.build_match_pattern("claude-opus-5-5")
        self.assertIsNotNone(re.match(pattern, "claude-opus-5-5"))
        # 完全一致のみ。前後に何か付くだけでも一致しない(部分一致に広げない)。
        self.assertIsNone(re.match(pattern, "claude-opus-5-5-preview"))
        self.assertIsNone(re.match(pattern, "anthropic/claude-opus-5-5"))

    def test_dot_is_escaped(self):
        # モデル名に "." が入る場合(litellm には無いが仮に来ても)を "任意の 1 文字" に
        # させないための回帰テスト。エスケープ漏れなら "claudexsonnet-5" にも一致してしまう。
        pattern = sync_model_pricing.build_match_pattern("claude.sonnet-5")
        self.assertIsNotNone(re.match(pattern, "claude.sonnet-5"))
        self.assertIsNone(re.match(pattern, "claudexsonnet-5"))


class PatternConflictsTests(unittest.TestCase):
    """[実測 2026-09-25] 実際にこの検査が効いた組み合わせ:
    既存の組み込みモデル `claude-opus-5` の matchPattern は
    `(?i)^((anthropic\\/)?claude-opus-5|...)$` で `$` 終端のため `claude-opus-5-5`
    には一致しない ―― が、それを機械的に確かめずに新モデルを足すのは危険なので、
    この実例をそのまま回帰テストに固定する。"""

    EXISTING_OPUS_5_PATTERN = (
        r"(?i)^((anthropic\/)?claude-opus-5|"
        r"(eu\.|us\.|apac\.|au\.|jp\.|global\.)?anthropic\.claude-opus-5(-v1(:0)?)?)$"
    )

    def test_no_conflict_between_opus_5_and_opus_5_5(self):
        existing = [{"modelName": "claude-opus-5", "matchPattern": self.EXISTING_OPUS_5_PATTERN}]
        candidate_pattern = sync_model_pricing.build_match_pattern("claude-opus-5-5")
        conflicts = sync_model_pricing.pattern_conflicts(
            "claude-opus-5-5", candidate_pattern, existing
        )
        self.assertEqual(conflicts, [])

    def test_conflict_detected_when_existing_pattern_is_too_broad(self):
        # 既存パターンが `$` 終端を欠き、新モデル名にまで一致してしまう場合を検出できること。
        existing = [{"modelName": "claude-opus-5", "matchPattern": r"(?i)^claude-opus-5"}]
        candidate_pattern = sync_model_pricing.build_match_pattern("claude-opus-5-5")
        conflicts = sync_model_pricing.pattern_conflicts(
            "claude-opus-5-5", candidate_pattern, existing
        )
        self.assertTrue(conflicts, "既存パターンが新モデル名に一致するのに検出できていない")

    def test_conflict_detected_when_new_pattern_is_too_broad(self):
        # 新パターン側が広すぎて既存モデル名まで拾ってしまう場合も両方向で検出できること。
        existing = [{"modelName": "claude-opus-5", "matchPattern": self.EXISTING_OPUS_5_PATTERN}]
        too_broad_pattern = r"(?i)^claude-opus-5.*$"
        conflicts = sync_model_pricing.pattern_conflicts(
            "claude-opus-5-5", too_broad_pattern, existing
        )
        self.assertTrue(conflicts, "新パターンが既存モデル名に一致するのに検出できていない")

    def test_self_is_excluded(self):
        # 更新(将来 --update を足す場合)を想定し、自分自身の名前は衝突として数えない。
        existing = [{"modelName": "claude-opus-5-5", "matchPattern": r"(?i)^claude-opus-5-5$"}]
        candidate_pattern = sync_model_pricing.build_match_pattern("claude-opus-5-5")
        conflicts = sync_model_pricing.pattern_conflicts(
            "claude-opus-5-5", candidate_pattern, existing
        )
        self.assertEqual(conflicts, [])


class LitellmPriceEntryTests(unittest.TestCase):
    """cf-fireboard の裁定「litellm に無い/欠けているモデルを 0 で埋めない」の機械的な担保。"""

    def test_missing_required_fields_returns_none_not_zero(self):
        # output_cost_per_token が無い(欠損)レコード。0 で埋めた price dict を返してはいけない。
        entry = {"input_cost_per_token": 4e-06}
        self.assertIsNone(sync_model_pricing.litellm_price_entry(entry))

    def test_empty_entry_returns_none(self):
        self.assertIsNone(sync_model_pricing.litellm_price_entry({}))

    def test_non_numeric_field_is_treated_as_missing(self):
        # litellm 側の欄が文字列や None になっているレコード(実例: 一部モデルは
        # 価格欄が "not_yet_priced" のような文字列のことがある)を数値と誤認しない。
        entry = {"input_cost_per_token": "unpriced", "output_cost_per_token": 2e-05}
        self.assertIsNone(sync_model_pricing.litellm_price_entry(entry))

    def test_required_fields_present_returns_prices(self):
        entry = {"input_cost_per_token": 4e-06, "output_cost_per_token": 2e-05}
        prices = sync_model_pricing.litellm_price_entry(entry)
        self.assertEqual(prices, {"input": 4e-06, "output": 2e-05})

    def test_optional_cache_fields_are_included_when_present(self):
        entry = {
            "input_cost_per_token": 4e-06,
            "output_cost_per_token": 2e-05,
            "cache_read_input_token_cost": 2e-07,
            "cache_creation_input_token_cost": 5e-06,
        }
        prices = sync_model_pricing.litellm_price_entry(entry)
        self.assertEqual(
            prices,
            {
                "input": 4e-06,
                "output": 2e-05,
                "cache_read_input_tokens": 2e-07,
                "cache_creation_input_tokens": 5e-06,
            },
        )

    def test_optional_cache_fields_absent_are_omitted_not_zeroed(self):
        # cache 欄が丸ごと無いレコード。キー自体を落とす(0 を入れない)。
        entry = {"input_cost_per_token": 4e-06, "output_cost_per_token": 2e-05}
        prices = sync_model_pricing.litellm_price_entry(entry)
        self.assertNotIn("cache_read_input_tokens", prices)
        self.assertNotIn("cache_creation_input_tokens", prices)


if __name__ == "__main__":
    unittest.main()
