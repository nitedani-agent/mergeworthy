#!/usr/bin/env bash
# Tests for bin/disk-sweep. Usage: tests/disk-sweep.sh [repo root]
# Builds a temp HOME with a work folder of worktrees and repos, a ~/.t3/worktrees worktree and a stub `docker` first on PATH,
# ages their files, runs the sweep without --delete (a dry run) and then with it, and checks what each rule removed and kept.
# Docker's prunes run only under the account's real home, so they are tested through prune_docker with that home set to HOME.
# Prints "case: <got> (want <want>)"; exits 0 only when every case gives what it wants.
set -u
R=$(readlink -f "${1:-$(dirname "$0")/..}")
T=$(mktemp -d); export HOME="$T/home" DOCKER_LOG="$T/docker.log"; mkdir -p "$HOME/.claude/agent-jobs" "$T/bin"
cat > "$T/bin/docker" <<'EOF'
#!/bin/sh
# stub docker: records each call; the prunes report what they reclaimed as Docker prints it, or fail when DOCKER_FAIL is set
echo "$*" >> "$DOCKER_LOG"
case "$1 $2" in
  *" prune") [ -z "${DOCKER_FAIL:-}" ] || { echo 'cannot prune: daemon is shutting down' >&2; exit 1; } ;;
esac
case "$1 $2" in
  "image prune") echo 'Total reclaimed space: 1.5MB' ;;
  "builder prune") printf 'ID\tRECLAIMABLE\tSIZE\nTotal:\t2GB\n' ;;
esac
EOF
chmod +x "$T/bin/docker"; export PATH="$T/bin:$PATH"; : > "$DOCKER_LOG"
fails=0
check() { echo "$1: $3 (want $2)"; [ "$2" = "$3" ] || fails=$((fails+1)); }
G() { git -c user.name=t -c user.email=t@example.invalid "$@"; }
age() { find "$@" -exec touch -h -d '2 days ago' {} +; }
there() { [ -e "$1" ] || [ -L "$1" ] && echo kept || echo removed; }
dsm() { python3 -c 'import importlib.machinery as M, importlib.util as U, os, sys  # bin/disk-sweep as module m, then the code $1, its arguments after it
l = M.SourceFileLoader("ds", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("ds", l)); l.exec_module(m)
exec(sys.argv[2])' "$R/bin/disk-sweep" "$@"; }

WF="$HOME/x-work"; mkdir -p "$WF"
G init -q --bare "$T/origin.git"; G init -q -b main "$T/main"
printf 'node_modules\n.env\n' > "$T/main/.gitignore"; echo a > "$T/main/README"
G -C "$T/main" add .gitignore README; G -C "$T/main" commit -qm base
G -C "$T/main" remote add origin "$T/origin.git"; G -C "$T/main" push -q origin main; G -C "$T/main" fetch -q origin
wt() { G -C "$T/main" worktree add -q -b "$(basename "$1")" "$1" origin/main 2>/dev/null; }
for n in clean dirty recent proc job writer; do wt "$WF/$n"; done
wt "$HOME/.t3/worktrees/p/t3wt"
echo x > "$WF/dirty/untracked.txt"
mkdir -p "$T/outside/node_modules" "$WF/clean/node_modules" "$WF/proc/node_modules" "$WF/job/node_modules" "$WF/writer/node_modules" "$WF/recent/node_modules" "$WF/drafts/node_modules" "$WF/fresh/node_modules" "$WF/rec"
echo x > "$T/outside/node_modules/x"; ln -s "$T/outside" "$WF/link"; ln -s "$T/outside/node_modules" "$WF/dirty/node_modules"
echo x > "$WF/clean/.env"; echo x > "$WF/clean/node_modules/x"; echo x > "$WF/proc/node_modules/x"; echo x > "$WF/job/node_modules/x"; echo x > "$WF/writer/node_modules/install.log"; echo x > "$WF/recent/node_modules/x"; echo x > "$WF/drafts/node_modules/x"; echo x > "$WF/drafts/notes.md"; echo x > "$WF/fresh/node_modules/x"
G init -q "$WF/tracked"; mkdir -p "$WF/tracked/node_modules"; echo x > "$WF/tracked/node_modules/x"; G -C "$WF/tracked" add node_modules; G -C "$WF/tracked" commit -qm tracked
truncate -s 11M "$WF/rec/old.webm" "$WF/rec/old.zip"
age "$WF" "$HOME/.t3" "$T/outside"
find "$WF/rec" -exec touch -d '8 days ago' {} +
mkdir -p "$HOME/.t3/worktrees/p/t3wt/node_modules"; echo x > "$HOME/.t3/worktrees/p/t3wt/node_modules/x"  # fresh, but git ignores it
touch "$WF/recent/README" "$WF/fresh/new.md"
bash -c "cd '$WF/proc' && exec sleep 600" & SPID=$!
(cd "$T" && exec python3 -c 'import sys, time; f = open(sys.argv[1], "a"); time.sleep(600)' "$WF/writer/node_modules/install.log") & WPID=$!
python3 -c 'import json,sys,time; json.dump({"key": "impl proc", "started": time.time(), "brief": "Work in " + sys.argv[1] + "/src."}, open(sys.argv[2], "w"))' "$WF/job" "$HOME/.claude/agent-jobs/j1.json"
sleep 0.2  # the sleep's cwd is set

python3 "$R/bin/disk-sweep" > "$T/dry.out" 2> "$T/dry.err"; rc=$?
check "without --delete it exits 0" 0 "$rc"
check "without --delete it prints the clean worktree's node_modules; under a temp HOME, no Docker line and one line saying Docker is skipped" "1 0 1" "$(grep -c " $WF/clean/node_modules c-ignored$" "$T/dry.out") $(grep -c docker: "$T/dry.out") $(grep -c Docker "$T/dry.err")"
check "without --delete it deletes nothing, writes no log, calls no docker" "kept kept kept no 0" "$(there "$WF/clean/node_modules") $(there "$WF/drafts/node_modules") $(there "$HOME/.t3/worktrees/p/t3wt/node_modules") $([ -e "$HOME/.mergeworthy/disk-sweep.log" ] && echo yes || echo no) $(wc -l < "$DOCKER_LOG")"
check "a second sweep while one runs is refused" "1 1" "$(flock "$HOME/.mergeworthy/disk-sweep.lock" python3 "$R/bin/disk-sweep" 2>"$T/lock.err" >/dev/null; echo $?) $(grep -c 'another sweep is running' "$T/lock.err")"
: > "$DOCKER_LOG"

python3 "$R/bin/disk-sweep" --delete > "$T/run.out" 2>&1; rc=$?
LOG="$HOME/.mergeworthy/disk-sweep.log"
check "under a temp HOME the sweep exits 0, prints only that Docker is skipped and calls no docker" "0 1 0" "$rc $(wc -l < "$T/run.out") $(wc -l < "$DOCKER_LOG")"
check "a clean, pushed, idle worktree is kept with its ignored .env; its node_modules is removed, logged before and after" "kept kept removed deleting|deleted|" "$(there "$WF/clean") $(there "$WF/clean/.env") $(there "$WF/clean/node_modules") $(grep "^[^ ]* [0-9][0-9]* $WF/clean/node_modules c-ignored " "$LOG" | cut -d' ' -f5 | tr '\n' '|')"
check "a worktree with a file changed in 24 hours is kept, with its node_modules" "kept kept" "$(there "$WF/recent") $(there "$WF/recent/node_modules")"
check "a worktree a process works in keeps its node_modules" kept "$(there "$WF/proc/node_modules")"
check "a worktree an open agent job names a path inside of keeps its node_modules" kept "$(there "$WF/job/node_modules")"
check "a ~/.t3/worktrees worktree is kept, and its ignored node_modules with a file changed in 24 hours" "kept kept" "$(there "$HOME/.t3/worktrees/p/t3wt") $(there "$HOME/.t3/worktrees/p/t3wt/node_modules")"
check "a node_modules a process outside it holds a file open in is kept" kept "$(there "$WF/writer/node_modules")"
check "a tracked node_modules is kept" kept "$(there "$WF/tracked/node_modules")"
check "symlinks to outside the roots are not followed" "kept kept kept" "$(there "$T/outside/node_modules/x") $(there "$WF/link") $(there "$WF/dirty/node_modules")"
check "node_modules outside repos: idle parent removed, recent parent kept" "removed kept" "$(there "$WF/drafts/node_modules") $(there "$WF/fresh/node_modules")"
check "a work folder's .webm and .zip over 10 MB and 8 days old are kept" "kept kept" "$(there "$WF/rec/old.webm") $(there "$WF/rec/old.zip")"

# prune_docker(account home) with the account home set to HOME: what the real home runs
prune() { dsm "m.DRY = '$1' == 'dry'; sys.exit(m.prune_docker(os.environ['HOME']))"; }
: > "$DOCKER_LOG"; prune dry > "$T/prune.out"; rc=$?
check "without --delete Docker's prunes are printed with unknown sizes and not run" "0 2 version|" "$rc $(grep -c '^[^ ]* ? docker:[a-z]* d-docker$' "$T/prune.out") $(tr '\n' '|' < "$DOCKER_LOG")"
: > "$DOCKER_LOG"; prune delete; rc=$?
check "Docker: version, then the dangling-image and build-cache prunes; never containers or volumes" "0 version|image prune -f --filter until=24h|builder prune -f --filter until=24h|" "$rc $(tr '\n' '|' < "$DOCKER_LOG")"
check "Docker's reclaimed sizes are logged" "1500000 docker:image|2000000000 docker:builder|" "$(grep d-docker "$LOG" | cut -d' ' -f2,3 | tr '\n' '|')"
DOCKER_FAIL=1 prune delete 2> "$T/prune.err"; rc=$?
check "a prune that fails exits 1, its stderr reported, no log line written" "1 2 2" "$rc $(grep -c 'daemon is shutting down' "$T/prune.err") $(grep -c d-docker "$LOG")"

# a HOME whose ~/.t3 is a symlink to a folder outside it, with a process already working in the worktree there
H2="$T/home2"; mkdir -p "$H2" "$T/t3real/worktrees"; ln -s "$T/t3real" "$H2/.t3"
G init -q "$T/t3real/worktrees/p"; echo node_modules > "$T/t3real/worktrees/p/.gitignore"; G -C "$T/t3real/worktrees/p" add .gitignore; G -C "$T/t3real/worktrees/p" commit -qm base
mkdir -p "$T/t3real/worktrees/p/node_modules"; echo x > "$T/t3real/worktrees/p/node_modules/x"; age "$T/t3real"
bash -c "cd '$T/t3real/worktrees/p' && exec sleep 600" & S2=$!; sleep 0.2
HOME="$H2" python3 "$R/bin/disk-sweep" --delete 2>/dev/null; rc=$?
check "a worktree under a symlinked ~/.t3, a process working in it, keeps its node_modules" "0 kept" "$rc $(there "$T/t3real/worktrees/p/node_modules")"
kill "$S2"; wait "$S2" 2>/dev/null
mkdir -p "$T/t3real/worktrees/p/node_modules"; echo x > "$T/t3real/worktrees/p/node_modules/x"; age "$T/t3real"
HOME="$H2" dsm 'm.DRY = False; p = os.path.join(m.HOME, ".t3/worktrees/p/node_modules"); m.delete(p, os.lstat(p).st_dev, "c-ignored")'
check "a candidate with a symlink on its path is not deleted" kept "$(there "$T/t3real/worktrees/p/node_modules")"

# a process that starts working in a candidate after the sweep's start, before its deletion
mkdir -p "$T/late/node_modules"; echo x > "$T/late/node_modules/x"; age "$T/late"
bash -c "cd '$T/late/node_modules' && exec sleep 600" & LPID=$!; sleep 0.2
dsm 'm.DRY = False; p = sys.argv[3]; m.delete(p, os.lstat(p).st_dev, "c-ignored")' "$T/late/node_modules"
check "a candidate a process started working in after the sweep's start is kept" kept "$(there "$T/late/node_modules")"

# a sweep killed in the middle of a deletion
mkdir -p "$T/killed/node_modules"; echo x > "$T/killed/node_modules/x"; age "$T/killed"
dsm 'm.DRY = False; m.shutil.rmtree = lambda p: os.kill(os.getpid(), 9); p = sys.argv[3]; m.delete(p, os.lstat(p).st_dev, "c-ignored")' "$T/killed/node_modules"
check "a sweep killed while deleting leaves the deletion's intent in the log" "137 1" "$? $(grep -c "^[^ ]* [0-9][0-9]* $T/killed/node_modules c-ignored deleting$" "$LOG")"

# tests/all.sh, on a root whose first suite leaves a child that calls docker after the suite exits
F="$T/allsh"; mkdir -p "$F/node_modules/typescript" "$F/docs" "$F/tests"; cp -r "$R/tests/refuse" "$F/tests/"
echo 'import subprocess; subprocess.Popen(["sh", "-c", "sleep 0.5; docker version"])' > "$F/docs/build-graphs.py"
bash "$R/tests/all.sh" "$F" > /dev/null 2> "$T/allsh.err"
check "tests/all.sh fails a suite whose child calls docker after the suite exited" "1 1" "$? $(grep -c 'called docker' "$T/allsh.err")"

kill "$SPID" "$WPID" "$LPID"; wait "$SPID" "$WPID" "$LPID" 2>/dev/null
rm -rf "$T"
echo "failures: $fails"; [ "$fails" = 0 ]
