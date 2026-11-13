# gigun marketplace (gigun-dev/claude-code) が正本の plugin 一覧。flake の home 設定と
# developer-checks の fixture の両方が渡すので 1 か所に置く。
#   names:      marketplace にある plugin。これに無い @gigun は各ホストの設定から落とす
#   autoEnable: まだ設定に書かれていなければ有効にする plugin。既に書かれた値 (GUI で
#               切り替えた true / false) は上書きしない
# 自動で有効にしないものを作るときは、ここで names から引いた autoEnable を返す。
inputs:
let
  names =
    map (p: p.name)
      (builtins.fromJSON (builtins.readFile "${inputs.gigun-plugins}/.claude-plugin/marketplace.json"))
      .plugins;
in
{
  inherit names;
  autoEnable = names;
}
