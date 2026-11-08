#!/bin/sh
# agents/AGENTS.md から ~/.codex/AGENTS.md の中身を作り、標準出力へ書く。
# 使い方: sh agents/codex-agents-md.sh <agents ディレクトリ>
#
# Codex には Claude Code の `@` import が無いので、`@~/.claude/shared/<name>` の行を
# agents/shared/<name> の中身で置き換える (ryoppippi の codex module の dropClaudeImports と
# 同じ考え方)。断片の一覧を別に持たず import 行から決めるのは、断片を足すときに書く場所を
# 1 か所にするため。shared/ 以外を指す `@` 行は Claude 専用の import として落とす。
# nix (home-manager の build) と bootstrap.sh (nix なし) が同じこのスクリプトを呼ぶ。
# POSIX sh + awk だけで書くのは、nix の無い初期 bootstrap でも動かすため。
set -eu

dir=${1:?usage: codex-agents-md.sh AGENTS_DIR}

printf '<!-- Generated from agents/AGENTS.md in gigun-dev/dotfiles. Edit that file, not this one. -->\n\n'
awk -v dir="$dir" '
  index($0, "@~/.claude/shared/") == 1 {
    file = dir "/shared/" substr($0, length("@~/.claude/shared/") + 1)
    while ((status = (getline line < file)) > 0) print line
    if (status < 0) {
      print "codex-agents-md: missing fragment " file > "/dev/stderr"
      exit 1
    }
    close(file)
    next
  }
  /^@/ { next }
  { print }
' "$dir/AGENTS.md"
