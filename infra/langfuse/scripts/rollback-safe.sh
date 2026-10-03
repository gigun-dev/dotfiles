#!/usr/bin/env bash
# DB migration は OS 世代と一緒には戻らない。イメージの対が同じ場合だけ、
# autoswitch の既存 OS rollback を許す。移行有無を推測して旧版を起動しない。
set -euo pipefail

image_pair() {
	local compose=$1 line image web='' worker=''
	[[ -r $compose ]] || return 2
	while IFS= read -r line || [[ -n $line ]]; do
		if [[ $line =~ ^[[:space:]]*image:[[:space:]]+(docker\.langfuse\.com/langfuse/langfuse(-worker)?:[^[:space:]]+)[[:space:]]*$ ]]; then
			image=${BASH_REMATCH[1]}
			case "$image" in
				docker.langfuse.com/langfuse/langfuse-worker:*)
					[[ -z $worker ]] || return 2
					worker=$image
					;;
				docker.langfuse.com/langfuse/langfuse:*)
					[[ -z $web ]] || return 2
					web=$image
					;;
				esac
		fi
	done < "$compose"
	[[ -n $web && -n $worker ]] || return 2
	printf '%s\n%s\n' "$web" "$worker"
}

if [[ $# != 2 ]]; then
	echo 'usage: rollback-safe.sh BEFORE_COMPOSE AFTER_COMPOSE' >&2
	exit 2
fi

# 不明な形式・欠落は「変化なし」ではない。認証値を含む Compose 本文は出さない。
if ! before=$(image_pair "$1") || ! after=$(image_pair "$2"); then
	echo 'Langfuse image pair を確認できないため自動 rollback を停止する' >&2
	exit 2
fi
if [[ $before != "$after" ]]; then
	echo 'Langfuse image pair が変わったため移行済み DB の旧版復帰を停止する' >&2
	exit 1
fi
