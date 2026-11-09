# Linux CI の本人確認済みself-hosted fallback

GitHub-hosted runnerを通常経路とする。課金等で利用できない期間だけ、本人がreviewした完全SHAをselectorへ設定し、専用labelのephemeral self-hosted runnerへ対象jobを送る。PRではGitHub生成merge SHA、push / workflow dispatchでは実行SHAを照合する。baseやheadが動けば再確認する。

selector変数とrunner labelは認可境界ではない。workflowを編集できる主体は条件も変えられるため、runner起動前に対象SHA、workflow差分、queued jobを人が確認する。

## runnerの境界

[opt-in NixOS module](../ci/linux-runner/mini-runner.nix) は既定無効で、明示的に有効化したときだけ専用system userとrunnerを作る。

- jobごとに登録・解除するephemeral runnerとし、boot起動や自動再登録をしない。
- runner userへsudo、container group、Nix trusted userを与えない。
- host secret、container control socket、overlay network control socketをrunnerから隠す。
- registration tokenはNix storeへ入れず、job終了後にtoken、state、work、logを処理する。
- systemd sandboxはVMでもnetwork isolationでもない。同じkernel、network、store、diskを共有する。
- Nix daemonの非trusted clientでも、buildによるstore追加やdisk消費、到達可能なbinary cacheの影響は残る。

信頼できないforkや未review codeには使用しない。状態を消して再利用しても、この境界を強くするものではない。

## 実行とcleanup

1. 対象SHA、workflow、他のqueued jobを確認する。
2. selectorを設定し、新しいrunを起動する。既にqueuedのjobは自動で振り直されない。
3. 短命tokenでrunnerを一度だけ登録し、job終了と登録解除を確認する。
4. 次のjobごとに新しいephemeral登録を行う。同時実行しない。
5. failure、cancelled、skipped、結果欠落をaggregate gateが成功扱いしないことを確認する。
6. 最後にrunner登録、selector、token、state、work、log、専用unit / userの残存を確認して撤去する。

Linux結果はmacOS検証を代替しない。Darwin buildとAnsible native fixtureは対応hostで別に実行し、未実行を成功扱いしない。

## 受入済み範囲

2026-11-09、review済みPR mergeを対象にLinuxの変更判定、secret scan、check、build、aggregate gate、portable testが成功した。jobごとのephemeral登録解除と、使用後のselector、token、runner state、work、log、専用unit / userの撤去も確認した。失敗fixtureをgateがfailureへ集約する経路も別に確認している。

この受入は当時のreview済みSHAだけを対象とし、後続commitや最終公開SHAを証明しない。public化前には最終SHAでLinux一式を再実行し、必要なmacOS検証を別gateとして記録する。
