#!/usr/bin/env bash
# =============================================================================
# uv/tools.txt に宣言した uv tool のうち、未導入のものだけを入れる。
# home.activation (nix/modules/home/dotfiles.nix) と bootstrap.sh の両方から呼ぶ。
# 何を止めるか: ~/.local/bin の uv tool 群が手で入れた記憶にしか無く、新しい機械で
# 再現できないこと。
#
# 不変条件:
#   - uv が無ければ黙って終わる (ensure_installed パターン)。
#   - 全部入っていればネットワークに触らない (uv tool list はローカルの receipt を読むだけ)。
#   - 入っているものは更新しない。版は浮動で、更新は手で `uv tool upgrade --all`。
#   - 宣言外は消さず警告だけ (手元の editable install を意図的に宣言しないため)。
#   - 1 つの install 失敗で switch を止めない。失敗は stderr に出して続け、終了コードで返す。
#
# 引数: [--dry-run] [宣言ファイル (既定: このスクリプトの隣の tools.txt)]
# 環境: UV_BIN (activation から uv の store パスを渡す)、DOTFILES_PLATFORM (テスト用の上書き)
# =============================================================================
set -u

dry_run=0
if [ "${1:-}" = --dry-run ]; then
	dry_run=1
	shift
fi
decl=${1:-"$(cd "$(dirname "$0")" && pwd)/tools.txt"}

uv=${UV_BIN:-$(command -v uv || true)}
[ -n "$uv" ] && [ -x "$uv" ] || exit 0
[ -r "$decl" ] || exit 0

# activation と bootstrap は .zshrc を読まないので、Takumi Guard の index をここでも向ける
# (値の正は zsh/.zshrc。既に設定されていればそちらに従う)。
export UV_DEFAULT_INDEX="${UV_DEFAULT_INDEX:-https://pypi.flatt.tech/simple/}"

platform=${DOTFILES_PLATFORM:-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)}
platform=${platform/arm64/aarch64}

# PEP 503 の正規化。uv tool list は正規化済みの名前で出すので、宣言側を揃える。
normalize() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[-_.]+/-/g'
}

declared_names=()
declared_lines=()
while IFS= read -r line || [ -n "$line" ]; do
	line=${line%%#*}
	read -r -a fields <<<"$line"
	[ "${#fields[@]}" -gt 0 ] || continue
	spec=${fields[0]}
	wanted=1
	markers=0
	args=()
	for field in "${fields[@]:1}"; do
		case "$field" in
			@*)
				[ "$markers" = 1 ] || wanted=0
				markers=1
				# @darwin は darwin-* 全部、@darwin-aarch64 はその arch だけに当たる。
				case "$platform" in
					"${field#@}" | "${field#@}"-*) wanted=1 ;;
				esac
				;;
			*) args+=("$field") ;;
		esac
	done
	[ "$wanted" = 1 ] || continue
	name=$(normalize "${spec%%[][<>=!~@;]*}")
	declared_names+=("$name")
	declared_lines+=("$spec${args[*]:+ ${args[*]}}")
done <"$decl"

# 行頭が "- " のものは各 tool の実行ファイル。tool 行は "<name> v<version>"。
# 壊れた tool の警告は stderr に出るだけで、ここには載らない。
installed=$("$uv" tool list 2>/dev/null | sed -n -E 's/^([^ -][^ ]*) v[0-9].*/\1/p' | while read -r n; do normalize "$n"; echo; done)

is_installed() {
	printf '%s\n' "$installed" | grep -qxF "$1"
}

status=0
for i in "${!declared_names[@]}"; do
	is_installed "${declared_names[$i]}" && continue
	# 宣言行の追加引数 (--python 3.12 等) は空白で分割して渡す。
	read -r -a install_args <<<"${declared_lines[$i]}"
	if [ "$dry_run" = 1 ]; then
		echo "uv tool install ${install_args[*]}"
		continue
	fi
	echo "uv tools: ${declared_names[$i]} を入れます" >&2
	"$uv" tool install "${install_args[@]}" || {
		echo "uv tools: ${declared_names[$i]} の install に失敗" >&2
		status=1
	}
done

while read -r name; do
	[ -n "$name" ] || continue
	printf '%s\n' "${declared_names[@]}" | grep -qxF "$name" && continue
	echo "uv tools: $name は uv/tools.txt に宣言されていない (消さない。残すなら宣言するか uv tool uninstall $name)" >&2
done <<<"$installed"

exit "$status"
