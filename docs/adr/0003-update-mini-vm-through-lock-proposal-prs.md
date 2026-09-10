# mini-vm の更新は lock 提案 PR と required CI を通して自動で当てる

Date: 2026-09-06

mini-vm は無人機なので手で `pull && switch` を打つ機会が無く、push 済みの変更が届かないまま気づけない (cloudflare-os で実際に 106 コミット遅れた)。lock 更新の**提案**と**適用**を分け、`dotfiles-lock-propose@fast` (毎日) / `@slow` (日曜) が lock 更新 → 実機ビルド → PR + auto-merge まで行い required CI の成功で merge、`dotfiles-autoswitch` (04:00) は lock を更新せず merge 済みの main を pull → switch → 健全性ゲート → 失敗なら rollback する。理由は、lock の差分は人にレビューできないので人を関門に置いても素通りするだけであり、実機ビルドと required CI を通ることの方が実効的な保証になるから。実装は `nix/modules/nixos/mini-vm.nix`、詳細は `docs/mini-vm.md`。

Considered Options:

- **`system.autoUpgrade` を使う** —— 却下。home 層が視野の外 (`nixos-rebuild` しか叩かない) で、pre/post フックが無いため健全性ゲートも dirty ガードも挟めない。nixpkgs の `nixos/modules/tasks/auto-upgrade.nix` を読んで確認した。提供価値は timer 1 本分。
- **`--flake github:...` を直接参照する** —— 却下。手動 switch (作業コピー) と自動更新 (github:) で真実が二重になり、「いま動いている rev」を作業コピーから読めなくなる。ローカル pull なら食い違いが dirty ガードで鳴る。
- **手元でレビューしてから merge する (当初の設計)** —— 2026-09-06 に撤回。上記のとおり lock 差分は人に判定できない。

Consequences:

- 失敗は鳴るが**沈黙は検出できない** (`todo.txt` の `old:DF-35`)。
- required CI は repo admin の直 push でバイパスできるので、この不変条件には穴がある (`old:DF-40`)。
- 無人で毎日 push する経路に `gh` トークンが乗るため、そのトークンの権限が問題になる (`old:DF-37`)。
