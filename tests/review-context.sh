#!/usr/bin/env bash
# Tests for bin/review-context. Usage: tests/review-context.sh [repo root]
# Builds a temp git repo with a tiny TS project, changes f and removes g, and checks what review-context prints.
# Prints "case: <got> (want <want>)"; exits 0 only when every case gives what it wants.
set -u
R=$(readlink -f "${1:-$(dirname "$0")/..}")
TSDIR=/home/nitedani/projects/vike/node_modules/.pnpm/typescript@5.9.3/node_modules/typescript
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME"
fails=0
check() { # name want got
  echo "$1: $3 (want $2)"; [ "$2" = "$3" ] || fails=$((fails+1))
}
has() { printf '%s\n' "$OUT" | grep -qE -- "$1" && echo yes || echo no; }
section() { printf '%s\n' "$OUT" | sed -n "/^### $1/,/^### /p"; } # the output section of the symbol heading $1
G() { git -c user.name=t -c user.email=t@example.invalid "$@"; }

P="$T/proj"; mkdir -p "$P/test" "$P/node_modules"; cd "$P"
ln -s "$TSDIR" node_modules/typescript
echo node_modules > .gitignore
echo '{"compilerOptions":{"target":"ES2020","module":"ESNext","moduleResolution":"Bundler","strict":true},"include":["*.ts","test/*.ts"]}' > tsconfig.json
cat > a.ts <<'X'
export function f(x: number): number {
  return x + 1
}
export function twice(x: number): number {
  return x * 2
}
X
cat > b.ts <<'X'
import { f } from './a'
export function useF(): number {
  return f(1)
}
X
cat > test/a.test.ts <<'X'
import { f } from '../a'
export const ok = f(2) === 3
X
cat > c.ts <<'X'
export function g(): string {
  return 'g'
}
X
mkdir pkg2 && echo '{"compilerOptions":{"strict":true},"include":["*.ts"]}' > pkg2/tsconfig.json
echo 'export const v = twice(3)' > pkg2/use.ts
G init -q && G add -A && G commit -qm base
BASE=$(git rev-parse HEAD)
cat > a.ts <<'X'
export function f(x: number): number {
  return x + 2
}
export function twice(x: number): number {
  return x * 3
}
X
git rm -q c.ts
echo "// still calls g() somewhere" > c2.ts
G add -A && G commit -qm change

OUT=$("$R/bin/review-context" "$BASE" 2>&1); code=$?
check "exit code" 0 "$code"
check "f is listed" yes "$(has '^### f \(function\) — a\.ts:1')"
check "the caller b.ts is listed" yes "$(has 'b\.ts:3 in `useF`')"
check "the test caller is tagged" yes "$(has '\[test\] test/a\.test\.ts')"
check "g is listed as removed" yes "$(has '^### removed: g$')"
check "g's remaining hit is listed" yes "$(has 'c2\.ts:1')"
check "the header names the base" yes "$(has "^base $BASE")"
check "twice is listed" yes "$(has '^### twice \(function\) — a\.ts:4')"
check "pkg2/use.ts is an other mention of twice" yes "$(section 'twice ' | sed -n '/^\*\*Other mentions/,$p' | grep -qE '^- pkg2/use\.ts:1: `export const v = twice\(3\)`$' && echo yes || echo no)"
check "f (under 4 characters) gets no other mentions" no "$(section 'f (function)' | grep -q 'Other mentions' && echo yes || echo no)"
check "--max-refs 1 caps the callers" yes "$(OUT=$("$R/bin/review-context" "$BASE" --max-refs 1); has '… 1 more')"

# one fixture per case: `proj NAME` makes a repo with a tsconfig; `commit` commits all; `OUT=$(review NAME)` runs review-context on its last commit
proj() { mkdir -p "$T/$1/node_modules"; cd "$T/$1"; ln -s "$TSDIR" node_modules/typescript; echo node_modules > .gitignore
  echo '{"compilerOptions":{"target":"ES2020","module":"ESNext","moduleResolution":"Bundler","strict":true},"include":["*.ts"]}' > tsconfig.json; }
commit() { G add -A && G commit -qm "$1"; }
review() { "$R/bin/review-context" "${@:-HEAD~1}" 2>&1; }

proj nested; G init -q
printf 'export function outer(v: number): number {\n  const inner = (x: number) => x + 1\n  return inner(v) + 10\n}\n' > a.ts
printf "import { outer } from './a'\nexport const r = outer(1)\n" > b.ts
commit base
printf 'export function outer(v: number): number {\n  const inner = (x: number) => x + 2\n  return inner(v) + 20\n}\n' > a.ts
commit change; OUT=$(review)
check "nested change: the enclosing function and its caller are listed" yes "$(section 'outer ' | grep -q 'b\.ts:2' && echo yes || echo no)"
check "nested change: the nested declaration is listed" yes "$(has '^### inner ')"
printf 'export function outer(v: number): number {\n  const inner = (x: number) => x + 3\n  return inner(v) + 20\n}\n' > a.ts
commit nestedonly; OUT=$(review)
check "nested-only change: the enclosing function is not listed" no "$(has '^### outer ')"

proj anon; G init -q
printf 'export default function (v: number): number {\n  return v + 1\n}\n' > a.ts
printf "import transform from './a'\nexport const r = transform(1)\n" > b.ts
commit base
printf 'export default function (v: number): number {\n  return v + 2\n}\n' > a.ts
commit change; OUT=$(review)
check "anonymous default export: no failure" no "$(has 'context failed')"
check "anonymous default export: the caller under another name is listed" yes "$(section 'default ' | grep -q 'b\.ts:2' && echo yes || echo no)"
printf 'export default class {\n  m() { return 1 }\n}\n' > a.ts
printf "import K from './a'\nexport const k = new K()\n" > b.ts
commit class1
printf 'export default class /* changed */ {\n  m() { return 1 }\n}\n' > a.ts
commit class; OUT=$(review)
check "anonymous default class: no failure" no "$(has 'context failed')"
check "anonymous default class: the caller under another name is listed" yes "$(section 'default ' | grep -q 'b\.ts:2' && echo yes || echo no)"

proj spaces; G init -q
printf 'export function target(): number {\n  return 1\n}\n' > 'some file.ts'
printf 'export function other(): number {\n  return 1\n}\n' > 'q"😀.ts'
printf "import { target } from './some file'\nexport const r = target()\n" > b.ts
commit base
printf 'export function target(): number {\n  return 2\n}\n' > 'some file.ts'
printf 'export function other(): number {\n  return 2\n}\n' > 'q"😀.ts'
commit change; OUT=$(review)
check "path with a space: its symbol and caller are listed" yes "$(section 'target ' | grep -q 'b\.ts:2' && echo yes || echo no)"
check "quoted path with an emoji: its symbol is listed" yes "$(has '^### other ')"

proj siblings; G init -q
printf 'export function one(): number { return 1 }\nexport function two(): number { return 1 }\n' > a.ts
commit base
printf 'export function one(): number { return 2 }\nexport function two(): number { return 2 }\n' > a.ts
commit change; OUT=$(review)
check "two changed functions in one hunk: both are listed" yes "$(has '^### one ' | grep -q yes && has '^### two ')"

proj mixed; G init -q
printf 'export function target(v: number): number {\n  return v\n}\n' > a.ts
printf "import { target } from './a'\ndeclare const runtime: any\nexport const r = target(1)\nexport const s = runtime.target(2)\n" > b.ts
commit base
printf 'export function target(v: number): number {\n  return v + 1\n}\n' > a.ts
commit change; OUT=$(review)
check "a resolved reference leaves the file's other unresolved mention" yes "$(section 'target ' | sed -n '/^\*\*Other mentions/,$p' | grep -q 'b\.ts:4' && echo yes || echo no)"
check "a resolved line is not an unresolved mention" no "$(section 'target ' | sed -n '/^\*\*Other mentions/,$p' | grep -q 'b\.ts:3' && echo yes || echo no)"

proj cap; G init -q
printf 'export function target(v: number): number {\n  return v\n}\n' > a.ts
printf "import { target } from './a'\nexport const r = [target(1), target(2), target(3)]\n" | sed 's/, /,\n  /g' > b.ts
commit base
printf 'export function target(v: number): number {\n  return v + 1\n}\n' > a.ts
commit change; OUT=$(review HEAD~1 --max-refs 1)
check "--max-refs 1 counts every hidden caller" yes "$(has '… 2 more')"
cd "$P"

# a run over its time limit still ends in one line (the heap cap shares this path; no cheap fixture runs out of memory)
OUT=$("$R/bin/review-context" "$BASE" --timeout 0.001 2>&1); code=$?
check "time limit: exit code" 0 "$code"
check "time limit: one line" "review-context: failed (timed out after 0.001 s); no context" "$OUT"

# a TypeScript without the compiler API (TypeScript 7): mergeworthy's own takes over
rm node_modules/typescript; mkdir -p node_modules/typescript; echo 'module.exports = {}' > node_modules/typescript/index.js
OUT=$("$R/bin/review-context" "$BASE" 2>&1)
check "TypeScript 7 in the repo: mergeworthy's TypeScript lists the callers" yes "$(grep -q 'b.ts' <<<"$OUT" && echo yes || echo no)"

# no usable TypeScript anywhere: a copy of the script outside mergeworthy
cp "$R/bin/review-context" "$T/review-context.mjs"
OUT=$(node "$T/review-context.mjs" "$BASE" 2>&1); code=$?
check "no TypeScript: exit code" 0 "$code"
check "no TypeScript: message" "review-context: no TypeScript found in $(readlink -f "$P"); no context" "$OUT"

cd /; rm -rf "$T"
echo "failures: $fails"; [ "$fails" = 0 ]
