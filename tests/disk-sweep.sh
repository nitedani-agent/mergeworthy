#!/usr/bin/env bash
# Tests for bin/disk-sweep. Usage: tests/disk-sweep.sh [repo root]
# Builds a temp HOME with a work folder of worktrees and repos, a ~/.t3/worktrees worktree and a stub `docker` first on PATH,
# ages their files, runs the sweep without --delete (a dry run) and then with it, and checks what each rule removed and kept.
# Docker's prunes run only from the watcher daemon of the main watch dir, so run_prunes is called with the recording stub's path.
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
check "without --delete it prints the clean worktree's node_modules and Docker's two prunes, with unknown sizes" "1 2 0" "$(grep -c " $WF/clean/node_modules c-ignored$" "$T/dry.out") $(grep -c '^[^ ]* ? docker:[a-z]* d-docker$' "$T/dry.out") $(wc -c < "$T/dry.err")"
check "without --delete it deletes nothing, writes no log, calls no docker" "kept kept kept no 0" "$(there "$WF/clean/node_modules") $(there "$WF/drafts/node_modules") $(there "$HOME/.t3/worktrees/p/t3wt/node_modules") $([ -e "$HOME/.mergeworthy/disk-sweep.log" ] && echo yes || echo no) $(wc -l < "$DOCKER_LOG")"
check "a second sweep while one runs is refused" "1 1" "$(flock "$HOME/.mergeworthy/disk-sweep.lock" python3 "$R/bin/disk-sweep" 2>"$T/lock.err" >/dev/null; echo $?) $(grep -c 'another sweep is running' "$T/lock.err")"
: > "$DOCKER_LOG"

python3 "$R/bin/disk-sweep" --delete > "$T/run.out" 2>&1; rc=$?
LOG="$HOME/.mergeworthy/disk-sweep.log"
check "a sweep the daemon didn't start exits 0, prints only that Docker is skipped and calls no docker" "0 1 0" "$rc $(wc -l < "$T/run.out") $(wc -l < "$DOCKER_LOG")"
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

# run_prunes with the recording stub: what the daemon's sweep runs
prune() { dsm "m.DRY = False; sys.exit(m.run_prunes('$T/bin/docker'))"; }
: > "$DOCKER_LOG"; prune; rc=$?
check "Docker: the dangling-image and build-cache prunes; never containers or volumes" "0 image prune -f --filter until=24h|builder prune -f --filter until=24h|" "$rc $(tr '\n' '|' < "$DOCKER_LOG")"
check "Docker's reclaimed sizes are logged" "1500000 docker:image|2000000000 docker:builder|" "$(grep d-docker "$LOG" | cut -d' ' -f2,3 | tr '\n' '|')"
DOCKER_FAIL=1 prune 2> "$T/prune.err"; rc=$?
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
HOME="$H2" dsm 'm.DRY = False; p = os.path.join(m.HOME, ".t3/worktrees/p/node_modules"); m.delete(p, os.path.dirname(p), os.lstat(p).st_dev, "c-ignored")'
check "a candidate with a symlink on its path is not deleted" kept "$(there "$T/t3real/worktrees/p/node_modules")"

# a process and a job that appear in a candidate's repo after the sweep's start, and a process that starts there while it runs
H4="$T/home4"; Z="$H4/z-work"; mkdir -p "$H4/.claude/agent-jobs" "$H4/.mergeworthy"
for n in late job during; do G init -q "$Z/$n"; echo node_modules > "$Z/$n/.gitignore"; G -C "$Z/$n" add .gitignore; G -C "$Z/$n" commit -qm base; mkdir -p "$Z/$n/node_modules"; echo x > "$Z/$n/node_modules/x"; done; age "$Z"
HOME="$H4" dsm 'import json, subprocess, time
z, started = os.path.join(m.HOME, "z-work"), []
try:
    started.append(subprocess.Popen(["sleep", "600"], cwd=z + "/late"))
    json.dump({"key": "impl late", "started": time.time(), "brief": "Work in " + z + "/job."}, open(m.HOME + "/.claude/agent-jobs/late.json", "w"))
    measure = m.measure
    def measuring(path, dev):
        if path == z + "/during/node_modules":
            started.append(subprocess.Popen(["sleep", "600"], cwd=z + "/during"))
        return measure(path, dev)
    m.measure = measuring; m.DRY = False; m.sweep_files()
finally:
    for q in started:
        q.kill(); q.wait()'
check "a repo a process started in, or a job named, after the sweep's start, or a process started in while it ran, keeps its node_modules" "kept kept kept" "$(there "$Z/late/node_modules") $(there "$Z/job/node_modules") $(there "$Z/during/node_modules")"

# a sweep killed in the middle of a deletion
mkdir -p "$T/killed/node_modules"; echo x > "$T/killed/node_modules/x"; age "$T/killed"
dsm 'm.DRY = False; m.empty = lambda fd: os.kill(os.getpid(), 9); p = sys.argv[3]; m.delete(p, os.path.dirname(p), os.lstat(p).st_dev, "c-ignored")' "$T/killed/node_modules"
check "a sweep killed while deleting leaves the deletion's intent in the log" "137 1" "$? $(grep -c "^[^ ]* [0-9][0-9]* $T/killed/node_modules c-ignored deleting$" "$LOG")"

# data a rebuild can't restore inside a candidate: a nested checkout with an unpushed commit and an edit, a .git file, an unreadable folder
H3="$T/home3"; Y="$H3/y-work"; mkdir -p "$Y"; G init -q "$Y/outer"; echo build/ > "$Y/outer/.gitignore"; G -C "$Y/outer" add .gitignore; G -C "$Y/outer" commit -qm base
G init -q "$Y/outer/build/checkout"; echo a > "$Y/outer/build/checkout/unique.txt"; G -C "$Y/outer/build/checkout" add unique.txt; G -C "$Y/outer/build/checkout" commit -qm local; echo b >> "$Y/outer/build/checkout/unique.txt"
mkdir -p "$Y/loose/node_modules/pkg" "$Y/locked/node_modules/sub" "$Y/plain/node_modules"; echo 'gitdir: /elsewhere' > "$Y/loose/node_modules/pkg/.git"
echo x > "$Y/locked/node_modules/sub/x"; echo y > "$Y/locked/node_modules/y"; echo x > "$Y/plain/node_modules/x"; age "$Y"; chmod 000 "$Y/locked/node_modules/sub"
HOME="$H3" python3 "$R/bin/disk-sweep" --delete 2>/dev/null; chmod 755 "$Y/locked/node_modules/sub"
check "a build folder holding a nested checkout, a node_modules holding a .git file or a folder it can't read are kept; a plain one goes" "kept kept kept removed" "$(there "$Y/outer/build/checkout/.git") $(there "$Y/loose/node_modules/pkg/.git") $(there "$Y/locked/node_modules/y") $(there "$Y/plain/node_modules")"

# a repo swapped for a symlink, then for a real directory, after the sweep inspected its node_modules and before it deletes it
swap() { mkdir -p "$T/$1/repo/node_modules" "$T/$1/outside/node_modules"; echo x > "$T/$1/repo/node_modules/x"; echo only > "$T/$1/outside/node_modules/only-copy.txt"; age "$T/$1"
  dsm 'rec = m.record
def record(n, what, rule, state):
    if state == "deleting":
        os.rename(sys.argv[3] + "/repo", sys.argv[3] + "/repo-old")
        os.symlink(sys.argv[3] + "/outside", sys.argv[3] + "/repo") if sys.argv[4] == "symlink" else os.rename(sys.argv[3] + "/outside", sys.argv[3] + "/repo")
    rec(n, what, rule, state)
m.record = record; m.DRY = False; p = sys.argv[3] + "/repo/node_modules"; m.delete(p, os.path.dirname(p), os.lstat(p).st_dev, "c-ignored")' "$T/$1" "$1" 2>/dev/null; }
swap symlink
check "a repo swapped for a symlink to elsewhere before the deletion: neither node_modules is deleted" "kept kept" "$(there "$T/symlink/outside/node_modules/only-copy.txt") $(there "$T/symlink/repo-old/node_modules/x")"
swap dir
check "a repo swapped for another real directory before the deletion: neither node_modules is deleted" "kept kept" "$(there "$T/dir/repo/node_modules/only-copy.txt") $(there "$T/dir/repo-old/node_modules/x")"

# a deleting run anywhere under the account's real home, or a Docker prune, only from the installed watcher's daemon on the main watch dir
AH=$(getent passwd "$(id -u)" | cut -d: -f6); AT=$(mktemp -d -p "$AH" .disk-sweep-test.XXXXXX); V="$AT/home/v-work"
mkdir -p "$AT/home/.mergeworthy" "$V"; G init -q "$V/repo"; echo node_modules > "$V/repo/.gitignore"; G -C "$V/repo" add .gitignore; G -C "$V/repo" commit -qm base
mkdir -p "$V/repo/node_modules" "$V/repo2/node_modules"; echo x > "$V/repo/node_modules/x"; echo x > "$V/repo2/node_modules/x"; age "$AT"
HOME="$AT/home" python3 "$R/bin/disk-sweep" --delete 2> "$T/home.err"; rc=$?
HOME="$AT/home" dsm 'm.DRY = False; p = sys.argv[3]; m.delete(p, os.path.dirname(p), os.lstat(p).st_dev, "c-node_modules")' "$V/repo2/node_modules" 2>/dev/null
check "under the account's home a sweep the daemon didn't start refuses --delete, and delete() deletes nothing there" "2 kept kept" "$rc $(there "$V/repo/node_modules") $(there "$V/repo2/node_modules")"
rm -rf "$AT"
: > "$DOCKER_LOG"; dsm 'os.environ["HOME"] = "/elsewhere"; m.DRY = False; sys.exit(m.prune_docker())' 2> "$T/prune.err"; rc=$?
check "prune_docker in a process the daemon didn't start prunes nothing and says so" "0 0 1" "$rc $(grep -c prune "$DOCKER_LOG") $(grep -c 'Docker skipped' "$T/prune.err")"
# the same check from a process tree shaped like the daemon's: a loop shell that wrote gh-watch.pid, its gh-watch.py, the sweep
I="$T/inst"; W="$T/watchdir"; mkdir -p "$I/bin" "$I/hooks" "$I/watcher" "$W"; cp "$R/bin/disk-sweep" "$I/bin/"; cp "$R/hooks/agent_jobs.py" "$I/hooks/"; ln -s "$I/watcher/gh-watch.py" "$W/gh-watch.py"
LOAD='import importlib.machinery as M, importlib.util as U, sys
l = M.SourceFileLoader("ds", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("ds", l)); l.exec_module(m)
'
printf 'import subprocess, sys\nsubprocess.run([sys.executable, "-c", sys.argv[1], *sys.argv[2:]])\n' > "$I/watcher/gh-watch.py"
daemon() { bash -c 'cd "$1" && echo $$ > gh-watch.pid && python3 -u gh-watch.py "$3" "$4" "$2" "$1"; true' _ "$W" "$I" "$LOAD$1" "$2"; }
daemon=$(daemon 'print(m.from_daemon(sys.argv[2], sys.argv[3]), m.from_daemon(sys.argv[2], "/elsewhere"), m.from_daemon("/elsewhere", sys.argv[3]))' "$I/bin/disk-sweep")
copy=$(daemon 'print(m.from_daemon(sys.argv[2], sys.argv[3]))' "$R/bin/disk-sweep")
direct=$(cd "$W" && python3 -c "$LOAD"'print(m.from_daemon(sys.argv[2], sys.argv[3]))' "$I/bin/disk-sweep" "$I" "$W")
byhand=$(cd "$W" && python3 -u gh-watch.py "$LOAD"'print(m.from_daemon(sys.argv[2], sys.argv[3]))' "$I/bin/disk-sweep" "$I" "$W"; true)
check "from_daemon: the daemon's tree on the main watch dir yes; another main dir, another install, a sweep from another copy, a probe in the watch dir or its gh-watch.py run by hand no" "True False False|False|False|False" "$daemon|$copy|$direct|$byhand"

# tests/all.sh, on a root whose first suite leaves a child that calls docker after the suite exits
F="$T/allsh"; mkdir -p "$F/node_modules/typescript" "$F/docs" "$F/tests"; cp -r "$R/tests/refuse" "$F/tests/"
echo 'import subprocess; subprocess.Popen(["sh", "-c", "sleep 0.5; docker version"])' > "$F/docs/build-graphs.py"
bash "$R/tests/all.sh" "$F" > /dev/null 2> "$T/allsh.err"
check "tests/all.sh fails a suite whose child calls docker after the suite exited" "1 1" "$? $(grep -c 'called docker' "$T/allsh.err")"

kill "$SPID" "$WPID"; wait "$SPID" "$WPID" 2>/dev/null
rm -rf "$T"
echo "failures: $fails"; [ "$fails" = 0 ]
