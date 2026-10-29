#!/usr/bin/env bash
# Every check CI runs, in CI's order; run it before each push. Usage: tests/all.sh [repo root]
set -eu
REAP=$(readlink -f "$(dirname "$0")/reap.py")
cd "${1:-$(dirname "$0")/..}"
[ -d node_modules/typescript ] || { echo "all.sh: install the dependencies first, \`npm ci\` (\`pnpm install\` where npm is disabled): review-context and its tests use mergeworthy's TypeScript"; exit 1; }
# tests/refuse first on PATH: a docker a suite finds by PATH lookup is the refusing one (an absolute path or a replaced PATH is not)
export PATH="$PWD/tests/refuse:$PATH" ALL_SH_LEAKED=$(mktemp); trap 'rm -f "$ALL_SH_LEAKED"' EXIT
run() { # a suite; once it and every process it started have exited (tests/reap.py), fail when one of them called docker
  python3 "$REAP" "$@"
  if [ -s "$ALL_SH_LEAKED" ]; then echo "all.sh: '$*' called docker:" >&2; cat "$ALL_SH_LEAKED" >&2; exit 1; fi
}
run python3 docs/build-graphs.py --check
run bash tests/hooks.sh .
run bash tests/word-budget .
run python3 tests/pointers.py .
run bash tests/watcher.sh .
run bash tests/steward.sh .
run python3 tests/watch-budget.py .
run python3 tests/watch-cadence.py .
run bash tests/loc-breakdown.sh .
run bash tests/disk-sweep.sh .
run bash tests/review-context.sh .
run bash tests/netns.sh .
