#!/usr/bin/env bash

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"

add_all=false
if [ "${1:-}" = "-a" ] || [ "${1:-}" = "--all" ]; then
	add_all=true
	shift
fi

msg="${1:-}"
type="${2:-chore}"
if [ -z "$msg" ]; then
	echo "usage: scripts/ship.sh [-a|--all] \"<message>\" [type]" >&2
	exit 1
fi

if $add_all; then
	git add -A
else
	git add -u
fi

if git diff --cached --quiet; then
	echo "ship: nothing staged to commit." >&2
	exit 1
fi

git commit -m "$type: $msg"
git push
