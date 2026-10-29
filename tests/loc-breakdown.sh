#!/usr/bin/env bash
# Tests for bin/loc-breakdown. Usage: tests/loc-breakdown.sh [repo root]
# Builds a temp git repo whose diff spans two features in one file, a doc, a test and a lockfile, and checks the table, a gap and an overlap.
# Prints "case: <got> (want <want>)"; exits 0 only when every case gives what it wants.
set -u
R=$(readlink -f "${1:-$(dirname "$0")/..}")
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME"
fails=0
check() { echo "$1: $3 (want $2)"; [ "$2" = "$3" ] || fails=$((fails+1)); }
G() { git -c user.name=t -c user.email=t@example.invalid "$@"; }

P="$T/proj"; mkdir -p "$P/docs" "$P/test"; cd "$P"
seq 1 10 | sed 's/^/line /' > app.ts
echo old > docs/guide.md
echo old > test/app.test.ts
echo old > pnpm-lock.yaml
G init -q && G add -A && G commit -qm base
BASE=$(git rev-parse HEAD)
# app.ts: line 2 changed (feature Cache), lines 9-10 replaced by 3 lines (feature Retry); docs, test and lockfile change
sed -i '2s/.*/cache 2/' app.ts
head -8 app.ts > a.tmp && printf 'retry a\nretry b\nretry c\n' >> a.tmp && mv a.tmp app.ts
printf 'new\nmore\n' >> docs/guide.md
echo added >> test/app.test.ts
printf 'x\ny\n' >> pnpm-lock.yaml
G commit -qam head
HEAD=$(git rev-parse HEAD)

printf 'Cache\tapp.ts:2-2\nCache\tapp.ts:base:2-2\nRetry\tapp.ts:9-11\nRetry\tapp.ts:base:9-10\n' > "$T/map"
OUT=$(python3 "$R/bin/loc-breakdown" "$BASE..$HEAD" "$T/map" --repo-dir "$P"); rc=$?
check exit 0 "$rc"
row() { printf '%s\n' "$OUT" | grep -F "| $1 |" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}'; }
check Retry '+3 / −2' "$(row Retry)"
check Cache '+1 / −1' "$(row Cache)"
check Docs '+2 / −0' "$(row 'Docs (one change)')"
check Tests '+1 / −0' "$(row Tests)"
check Lockfile '+2 / −0' "$(row Lockfile)"
check order "Retry,Cache" "$(printf '%s\n' "$OUT" | grep -oE '^\| (Retry|Cache) ' | tr -d '| \n' | sed 's/Cache/,Cache/')"
NUM=$(git diff --numstat "$BASE" "$HEAD" | awk '{a+=$1;r+=$2} END{print a" "r}')
TOT=$(printf '%s\n' "$OUT" | grep -F '**Total**' | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')
check total-matches-numstat "+$(echo $NUM | cut -d' ' -f1) / −$(echo $NUM | cut -d' ' -f2)" "$TOT"

# a gap: Retry's removed lines are not mapped
printf 'Cache\tapp.ts:2-2\nCache\tapp.ts:base:2-2\nRetry\tapp.ts:9-11\n' > "$T/gap"
ERR=$(python3 "$R/bin/loc-breakdown" "$BASE..$HEAD" "$T/gap" --repo-dir "$P" 2>&1 >/dev/null); rc=$?
check gap-exit 1 "$rc"
check gap-lists-lines "yes" "$(printf '%s' "$ERR" | grep -q 'app.ts:base:9-10' && echo yes || echo no)"

# an overlap: line 2 is in two features
printf 'Cache\tapp.ts\nRetry\tapp.ts:2-2\n' > "$T/overlap"
ERR=$(python3 "$R/bin/loc-breakdown" "$BASE..$HEAD" "$T/overlap" --repo-dir "$P" 2>&1 >/dev/null); rc=$?
check overlap-exit 1 "$rc"
check overlap-lists-lines yes "$(printf '%s' "$ERR" | grep -q 'app.ts:2 is in 2 entries: Cache, Retry' && echo yes || echo no)"

# a map entry can reclassify a default: this doc counts as the Cache feature
printf 'Cache\tdocs/guide.md\nCache\tapp.ts:2-2\nCache\tapp.ts:base:2-2\nRetry\tapp.ts:9-11\nRetry\tapp.ts:base:9-10\n' > "$T/over"
OUT=$(python3 "$R/bin/loc-breakdown" "$BASE..$HEAD" "$T/over" --repo-dir "$P")
check reclassified-doc '+3 / −1' "$(row Cache)"
check no-docs-row 0 "$(printf '%s\n' "$OUT" | grep -c 'Docs')"
# a committed build bundle under dist/ goes to Generated with no map entry
mkdir -p dist && printf 'a\nb\n' > dist/bundle.mjs && G add dist && G commit -qm bundle
OUT=$(python3 "$R/bin/loc-breakdown" "$HEAD..HEAD" "$T/map" --repo-dir "$P" 2>&1); rc=$?
check dist-exit 0 "$rc"
check dist-generated '+2 / −0' "$(row Generated)"
exit $((fails > 0))
