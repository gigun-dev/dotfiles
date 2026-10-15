# Pythonの使い分け

Pythonの依存とランタイムはuvに一本化する。どの形を選ぶかは「後で自分か他人がこれを再現する必要があるか」で決める。
必要ならuvプロジェクトにして依存をlockに残し、不要なら仮想環境を作らない。
uvの用語と挙動は公式ドキュメント（https://docs.astral.sh/uv/ の Projects / Scripts / Tools / Jupyter integration）に揃える。

## 用途ごとの置き場

標準ライブラリだけで済む使い捨ての処理は、nixで全ホストに入れた素の `python3`（`nix/modules/home/packages.nix`）で実行する。
この `python3` にはライブラリを足さない。リポジトリの `scripts/*.py` もこれで動く。

依存のある使い捨てスクリプトは、PEP 723のinline metadataで依存をファイル内に書く。
`uv add --script foo.py numpy` が先頭のメタデータを書き、`uv run foo.py` がその依存で一時環境を作って実行する。
ファイル1つで依存まで再現できるので、仮想環境もpyproject.tomlも要らない。

捨てる前提のnotebookや実験は `uvx --with numpy jupyter lab` で起動するか、Colab（VS Codeの `google.colab` 拡張、または `colab` CLI）を使う。
どちらも手元に仮想環境を残さない。

続けるもの・共有するもの・gitに入れるものは `uv init` でプロジェクトにし、依存は `uv add` で足す。
`pyproject.toml` と `uv.lock` と `.python-version` をcommitする。
`.venv` は使い捨てで、消しても `uv sync` がlockから作り直す。

CLIツールは、常用するものを `uv/tools.txt` に宣言し（`uv/sync-tools.sh` が未導入分だけ入れる）、一度だけ使うものは `uvx <tool>` で実行する。
nixpkgsにあるCLIは `packages.nix` に置き、uv toolにしない。

## 使わない形

グローバルなPythonへの `pip install` はしない。どのPythonに何が入ったかの記録が残らず、別の機械で再現できないからである。

`uv venv` と `uv pip install` の組み合わせも、残すものには使わない。入れた依存がpyproject.tomlにもlockにも記録されないので、上の `pip install` と同じ理由で再現できない。

pyenvは撤去した。pyenvでビルドしたランタイムはbrewの `gettext`（`/opt/homebrew/opt/gettext/lib/libintl.8.dylib`）にリンクしており、brewからgettextが消えた時点で起動しなくなっていた（2026-10-15 に dyld のエラーで確認）。brewの外で入れたものがbrewの整理で壊れる構造を避けるため、ランタイムはuvの管理するビルド済みのものに寄せる。

Pythonの依存をnixのdevShellやdirenvに重ねて持たせることもしない。依存の持ち主がnixとuvの2つになると、どちらが正か決まらなくなる。

## nixがPython環境を用意する必要があるとき

例外はESP-IDFのdevShell（`nix/devshells/esp-idf.nix`）で、ここでもPythonパッケージの解決はuvが担う。
nixが用意するのはSDKとPythonインタプリタとuv本体だけで、依存は `nix/devshells/esp-idf-python/` の `pyproject.toml` と `uv.lock` が持つ。
shellHookが `uv sync --locked --no-dev --python <nixのpython> --no-python-downloads` を実行し、`UV_PROJECT_ENVIRONMENT` をlockのhashごとに分けた `~/.cache/esp-idf/...` の下に向ける。
lockを書き換えずに同期だけするので、nixのPythonを使いながら依存の正はuv.lockに残る。nixでPython環境が要る場面は、この形を雛形にする。

## プロジェクトの中でnotebookを使う

uvプロジェクトの中でnotebookを使うときは、`uv add --dev ipykernel` でカーネルを開発依存に入れる。
VS Codeでは `.venv/bin/python` をカーネルに選ぶ。必要な拡張（ms-python と ms-toolsai.jupyter）はVS CodeのSettings Syncで持ち、dotfilesでは宣言しない。

notebookからパッケージを足すときは `!uv add pkg` を使う。依存がpyproject.tomlとlockに残るからで、`%pip install` は `.venv` に入るだけで記録が残らない。

パッケージは `.venv` に一度入れれば、実行のたびには入れ直さない。
ダウンロードは `~/.cache/uv` にプロジェクト間で共有され、ランタイムはバージョンごとに一度だけ `~/.local/share/uv/python` に置かれる（各 `.venv` はそこへsymlinkを張る）。

## Pythonのバージョン

新しいプロジェクトの `.python-version` は3.13を既定にし、プロジェクトごとに `uv python pin` で固定する。
3.13にしているのは、Colabのランタイムが2026-09-16にPython 3.13.15へ移り（Colabのrelease notes）、手元とColabの版を揃えられるためである。
3.14は、使う依存のすべてが3.14のwheelを出しているときに限って選ぶ。

## パッケージindex

`zsh/.zshrc` が `UV_DEFAULT_INDEX`（と `UV_INDEX_URL`・`PIP_INDEX_URL`）をTakumi Guard（`https://pypi.flatt.tech/simple/`）に向けている。
サプライチェーン攻撃への防御として意図的に置いている。外し方と匿名モードの理由は `npm/npmrc` のコメントにある。

このため `uv.lock` に記録されるsourceとファイルのURLは `pypi.flatt.tech` になる（`nix/devshells/esp-idf-python/uv.lock` が実例）。これは想定どおりの挙動である。
`uv init` は `pyproject.toml` に index を書かないが、続く `uv add` が環境変数の値を `[[tool.uv.index]]`（`default = true`）として書き込む（2026-10-15 に実測）。これも想定どおりで、消さずにコミットする。
`.zshrc` を読まない経路（home.activationとbootstrap.sh）では、`uv/sync-tools.sh` が同じ値を既定として設定する。
