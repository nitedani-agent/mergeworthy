#!/usr/bin/env bash
# Every check CI runs, in CI's order; run it before each push. Usage: tests/all.sh [repo root]
set -eu
cd "${1:-$(dirname "$0")/..}"
[ -d node_modules/typescript ] || { echo "all.sh: run npm ci first (review-context and its tests use mergeworthy's TypeScript)"; exit 1; }
python3 docs/build-graphs.py --check
bash tests/hooks.sh .
bash tests/word-budget .
python3 tests/pointers.py .
bash tests/watcher.sh .
python3 tests/watch-budget.py .
python3 tests/watch-cadence.py .
bash tests/loc-breakdown.sh .
bash tests/disk-sweep.sh .
bash tests/review-context.sh .
bash tests/netns.sh .
