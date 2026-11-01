# uvx の更新は Nix の autoswitch と分ける

Date: 2026-09-19

`codex-openai-bridge` の `uvx` パッケージは Nix の lock に含まれないため、独立した更新レーンで追従する。uvx の不具合で Nix の健全な generation を rollback しても uvx の版は戻らず、失敗を繰り返し得るため、refresh の成否を autoswitch の健全性ゲートに含めない。

この更新は required CI や Nix rollback を通らない。運用は [mini-vm.md](../mini-vm.md) を参照。
