# mini-vm の lock 更新は提案 PR で行う

Date: 2026-09-06
Implementation: done

無人の mini-vm は、lock 更新を実機でビルドして PR に提案し、required CI を通して自動 merge する。適用は別の autoswitch が行う。人が差分を判定しにくい lock 更新は、手動レビューを関門にするより実機ビルドと CI で検証する。自動適用の CI 判定は [ADR 0011](0011-push-without-a-local-gate-and-apply-only-green-commits.md)、運用は [mini-vm.md](../mini-vm.md) を参照。

Accepting: lock 更新は人の差分レビューを経ずに main へ merge される。
Rejected: 手元でレビューしてから merge する — lock の差分は人が判定しにくいから。
Rejected: 自動側だけ flake を `github:` で直接参照する — 手動と自動で参照先が異なると、稼働中の revision と作業コピーが食い違うから。

## GitHub Actions への提案経路移行

GitHub App を使う提案 workflow は、flake.lock の fast / slow、Langfuse、fzf の各レーンに用意する。
ただし workflow の手動受入が成功しただけでは、mini-vm の timer を停止しない。定期実行の責務と
沈黙検知を同時に失わないよう、次の順序を cutover 条件とする。

1. 各レーンを `workflow_dispatch` で受け入れ、差分なし、または対象を限定した提案 PR だけを作ることを確認する。
2. GitHub-hosted runner の schedule を宣言し、JST と UTC の対応、同時実行の抑止、既存 PR の再利用を確認する。
3. mini-vm の fast / slow heartbeat に代わる、GitHub 外から schedule の沈黙を検出できる監視を用意する。
4. 最初の自然発火と監視の receipt を確認してから、旧 timer / service とホスト側の書込認証を退役する。
5. 旧 heartbeat source とその通知設定は、旧 timer の停止後に削除する。

したがって schedule の有効化、旧 timer の停止、credential の失効は別々に先行させない。
移行中は mini-vm の既存 timer が定期実行の正本で、Actions workflow は手動受入経路である。
GitHub の workflow 名や runner label は認可境界ではなく、提案時の書込権限は protected Environment
内で発行する短命な GitHub App token に限定する。
