#!/usr/bin/env bash
# Every check CI runs, in CI's order; run it before each push. Usage: tests/all.sh [repo root]
set -eu
cd "${1:-$(dirname "$0")/..}"
[ -d node_modules/typescript ] || { echo "all.sh: run npm ci first (review-context and its tests use mergeworthy's TypeScript)"; exit 1; }
# tests/refuse first on PATH: a docker no suite, nor anything it leaves running, can get past to the machine's Docker
export PATH="$PWD/tests/refuse:$PATH" ALL_SH_LEAKED=$(mktemp); trap 'rm -f "$ALL_SH_LEAKED"; [ -z "${SUITE:-}" ] || kill -- "-$SUITE" 2>/dev/null || true' EXIT
run() { # a suite in a process group of its own; once every process in the group has exited, fail when one of them called docker
  setsid "$@" & SUITE=$!
  wait "$SUITE"
  while kill -0 -- "-$SUITE" 2>/dev/null; do sleep 0.1; done
  if [ -s "$ALL_SH_LEAKED" ]; then echo "all.sh: '$*' called docker:" >&2; cat "$ALL_SH_LEAKED" >&2; exit 1; fi
}
run python3 docs/build-graphs.py --check
run bash tests/hooks.sh .
run bash tests/word-budget .
run python3 tests/pointers.py .
run bash tests/watcher.sh .
run python3 tests/watch-budget.py .
run python3 tests/watch-cadence.py .
run bash tests/loc-breakdown.sh .
run bash tests/disk-sweep.sh .
run bash tests/review-context.sh .
run bash tests/netns.sh .
