#!/usr/bin/env python3
"""litellm の価格表から、self-host Langfuse (mini-vm) に単価を焼き込む道具。

やることは cf-fireboard の `scripts/sync-model-pricing.ts` と同じ設計 —— 取ってくる /
いま Langfuse に入っている値と突き合わせる(`--check`、既定) / 実際に POST する(`--write`)。
litellm を選んだ理由・npm パッケージを使わない理由・JSON を repo に commit しない理由は
そちらのコメントが正典なのでここでは繰り返さない。

litellm を毎回 GitHub の main から取りに行く設計にした理由 [2026-09-25]:
ccusage (rust/crates/ccusage-core/build.rs) は litellm を Nix flake input としてピンし、
ビルド時にバイナリへ埋め込む。あちらは「バイナリに焼いたら後から差し替えられない」から
ピンが要る。今回の成果物は Langfuse の model テーブル —— いつでも再同期できる可変な
サーバ状態で、ピンを足すと「flake.lock の陳腐化」と「Langfuse 側の陳腐化」の二層になる
だけ。実行時に main を取りに行けば陳腐化は「今の litellm と比べて古い」の一層で済む。

単位は litellm も Langfuse も「1 トークンあたりの USD」で揃っている
[実測 2026-09-25: 組み込みモデル claude-opus-5 の Langfuse 側 inputPrice は 5e-06、
litellm の `input_cost_per_token` も 5e-06 で完全一致]。cf-fireboard は自前の
`ModelUnitPrice`(100 万トークンあたり)に合わせるため `× 1e6` していたが、ここでは
変換不要 —— 変換を入れるとしたら、それは Langfuse 側の単位を誤認した書き込みバグになる。

言語: Python 3(このリポジトリの `claude/hooks/worktree-write-guard.py` と同じ流儀。
bun/node はこの repo で使っていない一方、python3 は nix の packages.nix で入っており
`.py` の実行ファイルが既に repo 内に前例としてある)。標準ライブラリのみで書く
(urllib.request / json)。requests 等の外部パッケージを venv 無しで足すと、この
リポジトリの「宣言的に管理する」原則(README 参照)に反する。
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

LITELLM_PRICING_URL = (
    "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
)

ENDPOINTS_ENV = Path.home() / ".config/claude-code/langfuse-endpoints.env"
CREDENTIALS_ENV = Path.home() / ".config/claude-code/langfuse.env"

# 対象モデル。litellm には 4000 件超入っている [実測 2026-09-25] ので全部は入れない。
# 決め方: `GET /api/public/v2/observations?type=GENERATION&fields=core,basic,model&limit=200`
# で実際に観測に出ているモデル名を拾う(litellm のキー名と Anthropic の生のモデル ID は
# 一致することを確認済み。フォールバックの `#/` 付き provider 接頭辞は litellm 側にも
# 別キーとして存在するが、ここでは接頭辞なしの生 ID だけを対象にする —— 我々の
# generation.model がその形で入っているため)。
#
# [実測 2026-09-25] 観測 200 件中の内訳: claude-opus-5-5 110 / claude-sonnet-5 50 /
# claude-opus-5 40。litellm のキーとしては 3 つとも存在する。
TARGET_MODELS: tuple[str, ...] = (
    "claude-opus-5-5",
    "claude-sonnet-5",
    "claude-opus-5",
)

# litellm の 1 レコードから拾う欄。cache_creation は cf-fireboard の `ModelUnitPrice` には
# 対応する型が無く見送られていたが、Langfuse の PricingTierInput.prices は自由な
# usage-type キーを受け付けるので、ここでは cache_creation も含める
# (実測: 組み込み claude-opus-5 の prices にも cache_creation_input_tokens が入っている)。
# キー名は Anthropic 系の generation.usageDetails の実測キーに合わせてある
# [実測 2026-09-25: 観測の usageDetails は input / output / cache_read_input_tokens /
# cache_creation_input_tokens]。
PRICE_FIELDS = {
    "input": "input_cost_per_token",
    "output": "output_cost_per_token",
    "cache_read_input_tokens": "cache_read_input_token_cost",
    "cache_creation_input_tokens": "cache_creation_input_token_cost",
}
# 上記のうち欄が無ければモデルごと落とす必須欄(0 で埋めない裁定は cf-fireboard と同じ)。
REQUIRED_PRICE_FIELDS = ("input", "output")


def load_env_file(path: Path) -> dict[str, str]:
    """`KEY=value` 形式の .env を読む。無ければ空 dict(呼び出し側が理由を出す)。"""
    if not path.exists():
        return {}
    out: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        out[key.strip()] = value.strip()
    return out


def langfuse_client(base_url: str, public_key: str, secret_key: str):
    """Basic 認証つきの小さな HTTP クライアント。requests を使わず標準ライブラリだけで足りる。"""
    token = base64.b64encode(f"{public_key}:{secret_key}".encode()).decode()
    headers = {"Authorization": f"Basic {token}", "Content-Type": "application/json"}

    def request(method: str, path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            f"{base_url}{path}", data=data, headers=headers, method=method
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as res:
                return json.loads(res.read())
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            raise RuntimeError(f"{method} {path} -> {e.code}: {detail}") from None

    return request


def fetch_all_models(request) -> list[dict[str, Any]]:
    """`GET /api/public/models` を全ページ辿る。`limit=50` の 1 ページ目だけ見て
    「50 件しかない」と早合点しないため(このリポジトリの依頼者本人が一度それで
    誤った背景情報を渡している —— totalItems は meta を見ないと分からない)。
    """
    models: list[dict[str, Any]] = []
    page = 1
    while True:
        res = request("GET", f"/api/public/models?limit=50&page={page}")
        models.extend(res["data"])
        meta = res["meta"]
        if page >= meta["totalPages"]:
            break
        page += 1
    return models


def litellm_price_entry(entry: dict[str, Any]) -> dict[str, float] | None:
    """litellm の 1 レコード → Langfuse pricingTiers 用の prices dict。
    必須欄(input/output)が無ければ None(0 で埋めない)。任意欄(cache 系)は無ければ
    キーごと省く —— 「無いなら無いなりの単価」で、0 円だと誤読されるほうが危ない。
    """
    prices: dict[str, float] = {}
    for langfuse_key, litellm_key in PRICE_FIELDS.items():
        value = entry.get(litellm_key)
        if isinstance(value, (int, float)):
            prices[langfuse_key] = float(value)
    if not all(k in prices for k in REQUIRED_PRICE_FIELDS):
        return None
    return prices


def build_match_pattern(model_id: str) -> str:
    """既存の組み込みモデル(例: claude-opus-5)の書式に合わせた完全一致パターンを作る。

    `claude-opus-5` の実際の matchPattern は
    `(?i)^((anthropic\\/)?claude-opus-5|(eu\\.|us\\.|apac\\.|au\\.|jp\\.|global\\.)?anthropic\\.claude-opus-5(-v1(:0)?)?)$`
    のように「素の ID」と「region 接頭辞つき Bedrock ID」の両方を 1 パターンで受ける。
    ここでは observation.model には素の ID しか来ていない実測([実測 2026-09-25]
    観測 200 件の model 欄はすべて接頭辞なし)に基づき、素の ID の完全一致だけに絞る
    —— 要らない受け口を広げるとテストしていない一致を作ることになる。
    """
    escaped = re.escape(model_id)
    return f"(?i)^{escaped}$"


def pattern_conflicts(
    candidate_name: str, candidate_pattern: str, existing_models: list[dict[str, Any]]
) -> list[str]:
    """新しいモデルの matchPattern が、既存の登録済みモデルと相互に衝突しないか調べる。

    双方向で見る: (a) 既存モデルの matchPattern が新モデル名そのものに一致してしまわないか
    (= 既に別のモデルがこの名前を勝手に拾ってしまう)、(b) 新モデルの matchPattern が
    既存モデルの名前に一致してしまわないか(= 新モデルが既存モデルの一致を横取りする)。
    (依頼者の懸念: claude-opus-5 が既に登録済みなので、claude-opus-5-5 を安易な
    パターンで足すと "claude-opus-5" 側にも誤って一致しかねない。実測では
    claude-opus-5 のパターンは `$` で終端されるため claude-opus-5-5 には一致しない
    ことを確認済みだが、ここでは全既存モデルに対して機械的に再確認する)。
    """
    conflicts: list[str] = []
    try:
        candidate_re = re.compile(candidate_pattern)
    except re.error as e:
        return [f"自分自身の matchPattern がコンパイルできない: {e}"]
    for m in existing_models:
        other_name = m["modelName"]
        other_pattern = m.get("matchPattern")
        if other_name == candidate_name:
            continue
        if candidate_re.match(other_name):
            conflicts.append(f"新パターンが既存モデル {other_name!r} にも一致する")
        if other_pattern:
            try:
                if re.match(other_pattern, candidate_name):
                    conflicts.append(
                        f"既存モデル {other_name!r} の matchPattern が新モデル名にも一致する"
                    )
            except re.error:
                continue
    return conflicts


def fmt_prices(prices: dict[str, float]) -> str:
    parts = [f"{k}={v}" for k, v in sorted(prices.items())]
    return ", ".join(parts) if parts else "(無し)"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="litellm の価格表から self-host Langfuse へモデル単価を同期する。"
    )
    parser.add_argument(
        "--write", action="store_true", help="実際に POST する(既定は --check 相当で書かない)"
    )
    parser.add_argument(
        "--from", dest="from_path", help="litellm の JSON をネットワークから取らずファイルで渡す"
    )
    args = parser.parse_args(argv)

    if args.from_path:
        litellm = json.loads(Path(args.from_path).read_text())
    else:
        with urllib.request.urlopen(LITELLM_PRICING_URL, timeout=30) as res:
            litellm = json.loads(res.read())

    print(f"# litellm 総モデル数: {len(litellm)} / 対象: {len(TARGET_MODELS)}")
    print()

    desired: dict[str, dict[str, float]] = {}
    missing_in_litellm: list[str] = []
    for model_id in TARGET_MODELS:
        entry = litellm.get(model_id)
        if not isinstance(entry, dict):
            missing_in_litellm.append(model_id)
            continue
        prices = litellm_price_entry(entry)
        if prices is None:
            missing_in_litellm.append(model_id)
            continue
        desired[model_id] = prices

    endpoints = load_env_file(ENDPOINTS_ENV)
    creds = load_env_file(CREDENTIALS_ENV)
    base_url = endpoints.get("LANGFUSE_BASE_URL")
    public_key = creds.get("LANGFUSE_PUBLIC_KEY")
    secret_key = creds.get("LANGFUSE_SECRET_KEY")
    if not base_url or not public_key or not secret_key:
        print(
            "Langfuse の接続情報が揃っていない"
            f"({ENDPOINTS_ENV} / {CREDENTIALS_ENV} を確認)",
            file=sys.stderr,
        )
        return 2

    request = langfuse_client(base_url, public_key, secret_key)
    existing_models = fetch_all_models(request)
    existing_by_name = {m["modelName"]: m for m in existing_models}
    print(f"# Langfuse 登録済みモデル数(全ページ): {len(existing_models)}")
    print()

    to_create: list[str] = []
    exit_code = 0
    for model_id in TARGET_MODELS:
        if model_id in missing_in_litellm:
            print(f"✗ {model_id}  litellm の価格表に無い(このIDでは) → 単価を作らない(0 で埋めない)")
            continue
        wanted = desired[model_id]
        current = existing_by_name.get(model_id)
        if current is None:
            print(f"○ {model_id}  Langfuse に未登録 → 作成候補: {fmt_prices(wanted)}")
            to_create.append(model_id)
            exit_code = 1
            continue
        current_prices = {
            "input": current.get("inputPrice"),
            "output": current.get("outputPrice"),
            "cache_read_input_tokens": (current.get("prices") or {})
            .get("cache_read_input_tokens", {})
            .get("price"),
            "cache_creation_input_tokens": (current.get("prices") or {})
            .get("cache_creation_input_tokens", {})
            .get("price"),
        }
        diffs = []
        for key, want_val in wanted.items():
            have_val = current_prices.get(key)
            if have_val is None or abs(have_val - want_val) > 1e-15:
                diffs.append(f"{key}: {have_val} -> {want_val}")
        if diffs:
            print(f"! {model_id}  既存登録と litellm の値がずれている: {'; '.join(diffs)}")
            print("  (このツールは既存モデルを上書きしない。手で確認すること)")
            exit_code = 1
        else:
            print(f"✅ {model_id}  既存登録済み・litellm と一致(数値のみ比較)")
    print()

    if not args.write:
        if to_create:
            print("# --write で以下を新規作成する(既存モデルは触らない):")
            for model_id in to_create:
                print(f"    {model_id}: {fmt_prices(desired[model_id])}")
        print("# --check 相当(書き込みなし)")
        return exit_code

    if not to_create:
        print("# 作成対象なし(--write は何もしない)")
        return 0

    for model_id in to_create:
        prices = desired[model_id]
        pattern = build_match_pattern(model_id)
        conflicts = pattern_conflicts(model_id, pattern, existing_models)
        if conflicts:
            print(f"✗ {model_id}  matchPattern の衝突が疑われるため作成を中止:")
            for c in conflicts:
                print(f"    - {c}")
            exit_code = 2
            continue
        body = {
            "modelName": model_id,
            "matchPattern": pattern,
            "unit": "TOKENS",
            "pricingTiers": [
                {
                    "name": "Standard",
                    "isDefault": True,
                    "priority": 0,
                    "conditions": [],
                    "prices": prices,
                }
            ],
        }
        created = request("POST", "/api/public/models", body)
        print(f"✅ {model_id} を作成した(id={created.get('id')})")
        # 作ったあとの existing_models / existing_by_name は更新しない(1 回のプロセス内で
        # 同じモデルを 2 回処理することは無い設計のため、再利用の必要が無い)。

    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
