# gigun marketplace (gigun-dev/claude-code) が正本の plugin 一覧。flake の home 設定と
# developer-checks の fixture の両方が渡すので 1 か所に置く。
#   names:      marketplace にある plugin。これに無い @gigun は各ホストの設定から落とす
#   autoEnable: まだ設定に書かれていなければ有効にする plugin。既に書かれた値 (GUI で
#               切り替えた true / false) は上書きしない
inputs:
let
  names =
    map (p: p.name)
      (builtins.fromJSON (builtins.readFile "${inputs.gigun-plugins}/.claude-plugin/marketplace.json"))
      .plugins;
  # 残すか外すかを保留している plugin (claude-code todo 0074)。marketplace には残すが
  # 自動では有効にしない。手で有効にした値は残る。
  held = [
    "swift-concurrency-pro"
    "swift-testing-pro"
    "swiftui-pro"
  ];
in
{
  inherit names;
  autoEnable = builtins.filter (n: !(builtins.elem n held)) names;
}
