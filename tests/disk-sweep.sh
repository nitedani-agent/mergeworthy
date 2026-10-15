#!/usr/bin/env bash
# Tests for bin/disk-sweep. Usage: tests/disk-sweep.sh [repo root]
# Builds a temp HOME with a work folder of worktrees and repos, a ~/.t3/worktrees worktree and a stub `docker` first on PATH,
# ages their files, runs the sweep without --delete (a dry run) and then with it, and checks what each rule removed and kept.
# Prints "case: <got> (want <want>)"; exits 0 only when every case gives what it wants.
set -u
R=$(readlink -f "${1:-$(dirname "$0")/..}")
T=$(mktemp -d); export HOME="$T/home" DOCKER_LOG="$T/docker.log"; mkdir -p "$HOME/.claude/agent-jobs" "$T/bin"
cat > "$T/bin/docker" <<'EOF'
#!/bin/sh
# stub docker: records each call; the prunes report what they reclaimed as Docker prints it
echo "$*" >> "$DOCKER_LOG"
case "$1 $2" in
  "image prune") echo 'Total reclaimed space: 1.5MB' ;;
  "builder prune") printf 'ID\tRECLAIMABLE\tSIZE\nTotal:\t2GB\n' ;;
esac
EOF
chmod +x "$T/bin/docker"; export PATH="$T/bin:$PATH"
fails=0
check() { echo "$1: $3 (want $2)"; [ "$2" = "$3" ] || fails=$((fails+1)); }
G() { git -c user.name=t -c user.email=t@example.invalid "$@"; }
age() { find "$@" -exec touch -h -d '2 days ago' {} +; }
there() { [ -e "$1" ] || [ -L "$1" ] && echo kept || echo removed; }

WF="$HOME/x-work"; mkdir -p "$WF"
G init -q --bare "$T/origin.git"; G init -q -b main "$T/main"
printf 'node_modules\n.env\n' > "$T/main/.gitignore"; echo a > "$T/main/README"
G -C "$T/main" add .gitignore README; G -C "$T/main" commit -qm base
G -C "$T/main" remote add origin "$T/origin.git"; G -C "$T/main" push -q origin main; G -C "$T/main" fetch -q origin
wt() { G -C "$T/main" worktree add -q -b "$(basename "$1")" "$1" origin/main 2>/dev/null; }
for n in clean dirty recent proc job; do wt "$WF/$n"; done
wt "$HOME/.t3/worktrees/p/t3wt"
echo x > "$WF/dirty/untracked.txt"
mkdir -p "$T/outside/node_modules" "$WF/clean/node_modules" "$WF/proc/node_modules" "$WF/job/node_modules" "$WF/recent/node_modules" "$WF/drafts/node_modules" "$WF/fresh/node_modules" "$WF/rec"
echo x > "$T/outside/node_modules/x"; ln -s "$T/outside" "$WF/link"; ln -s "$T/outside/node_modules" "$WF/dirty/node_modules"
echo x > "$WF/clean/.env"; echo x > "$WF/clean/node_modules/x"; echo x > "$WF/proc/node_modules/x"; echo x > "$WF/job/node_modules/x"; echo x > "$WF/recent/node_modules/x"; echo x > "$WF/drafts/node_modules/x"; echo x > "$WF/drafts/notes.md"; echo x > "$WF/fresh/node_modules/x"
G init -q "$WF/tracked"; mkdir -p "$WF/tracked/node_modules"; echo x > "$WF/tracked/node_modules/x"; G -C "$WF/tracked" add node_modules; G -C "$WF/tracked" commit -qm tracked
truncate -s 11M "$WF/rec/old.webm" "$WF/rec/old.zip"
age "$WF" "$HOME/.t3" "$T/outside"
find "$WF/rec" -exec touch -d '8 days ago' {} +
mkdir -p "$HOME/.t3/worktrees/p/t3wt/node_modules"; echo x > "$HOME/.t3/worktrees/p/t3wt/node_modules/x"  # fresh, but git ignores it
touch "$WF/recent/README" "$WF/fresh/new.md"
bash -c "cd '$WF/proc' && exec sleep 600" & SPID=$!
python3 -c 'import json,sys,time; json.dump({"key": "impl proc", "started": time.time(), "brief": "Work in " + sys.argv[1] + "/src."}, open(sys.argv[2], "w"))' "$WF/job" "$HOME/.claude/agent-jobs/j1.json"
sleep 0.2  # the sleep's cwd is set

python3 "$R/bin/disk-sweep" > "$T/dry.out"; rc=$?
check "without --delete it exits 0" 0 "$rc"
check "without --delete it prints the clean worktree's node_modules and Docker's prunes with unknown sizes" "1 2" "$(grep -c " $WF/clean/node_modules c-ignored$" "$T/dry.out") $(grep -c '^[^ ]* ? docker:[a-z]* d-docker$' "$T/dry.out")"
check "without --delete it deletes nothing, writes no log, runs no prune" "kept kept kept no version" "$(there "$WF/clean/node_modules") $(there "$WF/drafts/node_modules") $(there "$HOME/.t3/worktrees/p/t3wt/node_modules") $([ -e "$HOME/.mergeworthy/disk-sweep.log" ] && echo yes || echo no) $(tr '\n' ' ' < "$DOCKER_LOG" | xargs)"
check "a second sweep while one runs is refused" "1 1" "$(flock "$HOME/.mergeworthy/disk-sweep.lock" python3 "$R/bin/disk-sweep" 2>"$T/lock.err" >/dev/null; echo $?) $(grep -c 'another sweep is running' "$T/lock.err")"
: > "$DOCKER_LOG"

python3 "$R/bin/disk-sweep" --delete > "$T/run.out" 2>&1; rc=$?
LOG="$HOME/.mergeworthy/disk-sweep.log"
check "the sweep exits 0 and prints nothing" "0 " "$rc $(cat "$T/run.out")"
check "a clean, pushed, idle worktree is kept with its ignored .env; its node_modules is removed and logged" "kept kept removed 1" "$(there "$WF/clean") $(there "$WF/clean/.env") $(there "$WF/clean/node_modules") $(grep -c "^[^ ]* [0-9][0-9]* $WF/clean/node_modules c-ignored$" "$LOG")"
check "a worktree with a file changed in 24 hours is kept, with its node_modules" "kept kept" "$(there "$WF/recent") $(there "$WF/recent/node_modules")"
check "a worktree a process works in keeps its node_modules" kept "$(there "$WF/proc/node_modules")"
check "a worktree an open agent job names a path inside of keeps its node_modules" kept "$(there "$WF/job/node_modules")"
check "a ~/.t3/worktrees worktree is kept; its ignored node_modules, fresh inside, is removed" "kept removed" "$(there "$HOME/.t3/worktrees/p/t3wt") $(there "$HOME/.t3/worktrees/p/t3wt/node_modules")"
check "a tracked node_modules is kept" kept "$(there "$WF/tracked/node_modules")"
check "symlinks to outside the roots are not followed" "kept kept kept" "$(there "$T/outside/node_modules/x") $(there "$WF/link") $(there "$WF/dirty/node_modules")"
check "node_modules outside repos: idle parent removed, recent parent kept" "removed kept" "$(there "$WF/drafts/node_modules") $(there "$WF/fresh/node_modules")"
check "a work folder's .webm and .zip over 10 MB and 8 days old are kept" "kept kept" "$(there "$WF/rec/old.webm") $(there "$WF/rec/old.zip")"
check "Docker: version, then the dangling-image and build-cache prunes; never containers or volumes" "version|image prune -f --filter until=24h|builder prune -f --filter until=24h|" "$(tr '\n' '|' < "$DOCKER_LOG")"
check "Docker's reclaimed sizes are logged" "1500000 docker:image|2000000000 docker:builder|" "$(grep d-docker "$LOG" | cut -d' ' -f2,3 | tr '\n' '|')"
kill "$SPID"; wait "$SPID" 2>/dev/null
rm -rf "$T"
echo "failures: $fails"; [ "$fails" = 0 ]
