# gigun marketplace にある plugin 名。home の dotfiles.nix が enabledPlugins の消し忘れを
# 確かめるのに使う。flake の home 設定と developer-checks の fixture の両方が渡すので 1 か所に置く。
inputs:
map (p: p.name)
  (builtins.fromJSON (builtins.readFile "${inputs.gigun-plugins}/.claude-plugin/marketplace.json"))
  .plugins
