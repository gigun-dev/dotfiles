#!/usr/bin/env nu

# 宣言した Codex 設定を live の config.toml に重ねる。宣言していないキーは残す。
# ryoppippi/dotfiles (MIT) の nix/modules/home/programs/codex/merge-config.nu を移植した。
#
# 丸ごとコピーしない理由: ChatGPT デスクトップアプリが同じファイルに plugin 登録、
# node_repl などの MCP、desktop の UI 設定、projects の trust を書き込む。上書きすると
# browser use / computer use がアプリが書き戻すまで壊れる。
#
# Usage: merge-config.nu <template> <live>

# 両側が record のキーだけ再帰し、それ以外は $overlay の値で置き換える。
# 再帰するので features.memories を宣言してもアプリが書いた features.js_repl は残る。
def deep-merge [overlay: record]: record -> record {
    let base = $in

    $overlay
    | columns
    | reduce --fold $base {|key, merged|
        let new = $overlay | get $key
        let old = $merged | get --optional $key

        let both_records = (
            ($old | describe | str starts-with 'record')
            and ($new | describe | str starts-with 'record')
        )

        $merged | upsert $key (if $both_records { $old | deep-merge $new } else { $new })
    }
}

# 宣言した mcp_servers.<name> は live の同名の表を捨ててから入れる。表 1 つが 1 つの
# 起動定義なので、deep-merge で混ぜると宣言に無い args・env が live から残り、別の
# command に渡ってしまう (暫定の REA 設定は command = "/bin/bash" と launcher の args を
# 書いていた)。宣言していない server (アプリが書く node_repl など) には触らない。
def replace-declared-mcp-servers [overlay: record]: record -> record {
    let base = $in
    let declared = $overlay | get --optional mcp_servers | default {} | columns
    let live = $base | get --optional mcp_servers
    if ($declared | is-empty) or not ($live | describe | str starts-with 'record') {
        return $base
    }
    $base | upsert mcp_servers ($live | reject --optional ...$declared)
}

def main [template: path, live: path]: nothing -> nothing {
    let template_settings = open --raw $template | from toml

    let merged = if ($live | path exists) {
        open --raw $live
        | from toml
        | replace-declared-mcp-servers $template_settings
        | deep-merge $template_settings
    } else {
        $template_settings
    }

    mkdir ($live | path dirname)

    # Codex とアプリは動作中もこのファイルを読むので、書きかけを見せず rename で入れ替える。
    # 0600 はアプリが作ったときの mode。他人に見せる理由が無いので合わせる。
    let staged = $live | path parse | upsert extension 'toml.nix-tmp' | path join
    $merged | to toml | save --force $staged
    ^chmod 600 $staged
    mv --force $staged $live
}
