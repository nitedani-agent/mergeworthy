#!/usr/bin/env bash
# Tests for bin/disk-sweep. Usage: tests/disk-sweep.sh [repo root]
# Builds a temp HOME with a work folder of worktrees and repos, a ~/.t3/worktrees worktree and a stub `docker` first on PATH,
# ages their files, runs the sweep without --delete (a dry run) and then with it, and checks what each rule removed and kept.
# Docker's prunes run only from the watcher daemon of the main watch dir, so they run in a process tree shaped like the daemon's.
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
for t in pnpm npm pip; do printf '#!/bin/sh\necho "%s $*" >> "%s/tools.log"\n' "$t" "$T" > "$T/bin/$t"; chmod +x "$T/bin/$t"; done  # stub tools: never the machine's
chmod +x "$T/bin/docker"; export PATH="$T/bin:$PATH"; : > "$DOCKER_LOG"
PY=$(python3 -c 'import sys; print(sys.executable)'); python3() { command "$PY" "$@"; }  # no version-manager shim moving its bin ahead of the stubs
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
    def measuring(path, dev, *a):
        if path == z + "/during/node_modules":
            started.append(subprocess.Popen(["sleep", "600"], cwd=z + "/during"))
        return measure(path, dev, *a)
    m.measure = measuring; m.DRY = False; m.sweep_files()
finally:
    for q in started:
        q.kill(); q.wait()'
check "a repo a process started in, or a job named, after the sweep's start, or a process started in while it ran, keeps its node_modules" "kept kept kept" "$(there "$Z/late/node_modules") $(there "$Z/job/node_modules") $(there "$Z/during/node_modules")"

# a sweep killed in the middle of a deletion
mkdir -p "$T/killed/node_modules"; echo x > "$T/killed/node_modules/x"; age "$T/killed"
dsm 'm.DRY = False; m.empty = lambda fd, path=None: os.kill(os.getpid(), 9); p = sys.argv[3]; m.delete(p, os.path.dirname(p), os.lstat(p).st_dev, "c-ignored")' "$T/killed/node_modules"
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
I="$T/inst"; W="$T/watchdir"; mkdir -p "$I/bin" "$I/hooks" "$I/watcher" "$W"; cp "$R/bin/disk-sweep" "$I/bin/"; cp "$R/hooks/agent_jobs.py" "$R/hooks/work_folder.py" "$R/hooks/steward.py" "$I/hooks/";ln -s "$I/watcher/gh-watch.py" "$W/gh-watch.py"
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
# the prunes through the guarded entry, from the daemon's tree with this test's install and watch dir: what the daemon's sweep runs
PRUNE='m.INSTALLED, m.main_watch_dir, m.DRY = sys.argv[2], lambda: sys.argv[3], False; print(m.prune_docker())'
: > "$DOCKER_LOG"; got=$(daemon "$PRUNE" "$I/bin/disk-sweep")
check "Docker from the daemon's tree: version, then every unused image and the build cache older than 14 days; never containers or volumes" "0 version|image prune -a -f --filter until=336h|builder prune -f --filter until=336h|" "$got $(tr '\n' '|' < "$DOCKER_LOG")"
check "Docker's reclaimed sizes are logged" "1500000 docker:image|2000000000 docker:builder|" "$(grep d-docker "$LOG" | cut -d' ' -f2,3 | tr '\n' '|')"
got=$(DOCKER_FAIL=1 daemon "$PRUNE" "$I/bin/disk-sweep" 2> "$T/prune.err")
check "a prune that fails returns 1, its stderr reported, no log line written" "1 2 2" "$got $(grep -c 'daemon is shutting down' "$T/prune.err") $(grep -c d-docker "$LOG")"

# a dry run selects as a deleting run does: not a node_modules whose repo a process holds a file in, or starts working in while it runs
H5="$T/home5"; D="$H5/d-work"; mkdir -p "$H5/.mergeworthy"
for n in held during; do G init -q "$D/$n"; echo node_modules > "$D/$n/.gitignore"; G -C "$D/$n" add .gitignore; G -C "$D/$n" commit -qm base; mkdir -p "$D/$n/node_modules"; echo x > "$D/$n/node_modules/dep"; done; age "$D"
HOME="$H5" dsm 'import subprocess
d, started = os.path.join(m.HOME, "d-work"), []
try:
    started.append(subprocess.Popen([sys.executable, "-c", "import sys, time; f = open(sys.argv[1]); time.sleep(600)", d + "/held/node_modules/dep"], cwd="/"))
    time = __import__("time"); time.sleep(0.3)
    measure = m.measure
    def measuring(path, dev, *a):
        if path == d + "/during/node_modules":
            started.append(subprocess.Popen(["sleep", "600"], cwd=d + "/during"))
        return measure(path, dev, *a)
    m.measure = measuring; m.sweep_files()
finally:
    for q in started:
        q.kill(); q.wait()' > "$T/dry5.out"
check "a dry run lists no node_modules whose repo a process holds a file in or started working in while it ran" 0 "$(grep -c "$D/" "$T/dry5.out")"

# every sink refuses by itself, whoever calls it: in a dry run (the default on import); under the account's home and for Docker
# unless the main watch dir's daemon started the sweep
mkdir -p "$T/sink/e/x" "$T/sink/r/x"; echo x > "$T/sink/e/x/f"; echo x > "$T/sink/r/x/f"; AS=$(mktemp -d -p "$AH" .disk-sweep-test.XXXXXX); mkdir -p "$AS/r/x"; echo x > "$AS/r/x/f"; : > "$DOCKER_LOG"
got=$(dsm 'def refused(f, *a):
    try:
        f(*a)
    except (PermissionError, AttributeError) as e:
        return type(e).__name__
    return "ran"
fd = os.open(sys.argv[3] + "/e", os.O_RDONLY | os.O_DIRECTORY)
out = [refused(m.empty, fd), refused(m.remove, sys.argv[3] + "/r", os.lstat(sys.argv[3] + "/r")), refused(getattr(m, "run_docker", None) or m.run_prunes, "docker")]
m.DRY = False
out += [refused(m.remove, sys.argv[4] + "/r", os.lstat(sys.argv[4] + "/r")), refused(getattr(m, "run_docker", None) or m.run_prunes, "docker")]
print(*out)' "$T/sink" "$AS" 2>/dev/null)
check "empty, remove and Docker refuse in a dry run; remove under the account's home and Docker refuse outside the daemon" "PermissionError PermissionError PermissionError PermissionError PermissionError kept kept kept 0" "$got $(there "$T/sink/e/x/f") $(there "$T/sink/r/x/f") $(there "$AS/r/x/f") $(wc -l < "$DOCKER_LOG")"
rm -rf "$AS"

# round 7: build output in any repo under home, tool caches, and a weekly report; each needs 14 untouched days
H7="$T/home7"; mkdir -p "$H7/.mergeworthy"; : > "$T/tools.log"
old() { find "$@" -exec touch -h -d '15 days ago' {} +; }
for r in proj/app proj/young .hidden/r a/b/c/d/e/deep; do repo7="$H7/$r"; G init -q "$repo7"; echo dist > "$repo7/.gitignore"; G -C "$repo7" add .gitignore; G -C "$repo7" commit -qm base; mkdir -p "$repo7/dist"; echo x > "$repo7/dist/x"; done
mkdir -p "$H7/.npm/_cacache/x" "$H7/.cache/yarn/stale/x" "$H7/.cache/yarn/fresh" "$H7/.cache/drafts/x" "$H7/.cache/ms-playwright/chromium_headless_shell-1200" "$H7/.cache/yarn/readnow" "$H7/.cargo/registry/cache/idx" "$H7/.cargo/git/checkouts/c/rev/.git" "$H7/old-stuff/sub"
echo x > "$H7/.npm/_cacache/x/f"; echo x > "$H7/.cache/yarn/stale/x/f"; echo x > "$H7/.cache/drafts/x/f"; echo x > "$H7/.cache/yarn/readnow/f"; echo x > "$H7/.cargo/registry/cache/idx/a.crate"; echo x > "$H7/.cargo/git/checkouts/c/rev/.git/HEAD"
truncate -s 3M "$H7/old-stuff/sub/big"; old "$H7"; touch "$H7/.cache/yarn/fresh/f"; touch -a "$H7/.cache/yarn/readnow/f"; age "$H7/proj/young"
HOME="$H7" python3 "$R/bin/disk-sweep" --delete 2>/dev/null
check "a repo anywhere under home loses its 14-day-old build output; 2 days old, hidden or 6 levels down keeps it" "removed kept kept kept" "$(there "$H7/proj/app/dist") $(there "$H7/proj/young/dist") $(there "$H7/.hidden/r/dist") $(there "$H7/a/b/c/d/e/deep/dist")"
mkdir -p "$H7/proj/app/dist"; echo x > "$H7/proj/app/dist/x"; old "$H7/proj/app/dist"
HOME="$H7" python3 "$R/bin/disk-sweep" --delete 2>/dev/null
check "the home-wide walk runs at most once a day" kept "$(there "$H7/proj/app/dist")"
check "caches: pnpm, npm (stale _cacache) and pip by their own commands; stale tool-cache and cargo entries go, a fresh one, an unnamed ~/.cache folder an old Playwright browser and an old entry read today stay" "npm cache clean --force|pip cache purge|pnpm store prune| removed removed removed kept kept kept kept" "$(sort -u "$T/tools.log" | tr '\n' '|') $(there "$H7/.cache/yarn/stale") $(there "$H7/.cargo/registry/cache/idx") $(there "$H7/.cargo/git/checkouts/c") $(there "$H7/.cache/yarn/fresh") $(there "$H7/.cache/drafts") $(there "$H7/.cache/ms-playwright/chromium_headless_shell-1200") $(there "$H7/.cache/yarn/readnow")"
check "a weekly report names the stale folder no rule covers, and deletes nothing" "1 0 kept" "$(cat "$H7/.mergeworthy/disk-report.md" 2>/dev/null | grep -c "$H7/old-stuff") $(cat "$H7/.mergeworthy/disk-report.md" 2>/dev/null | grep -c "$H7/.cache/yarn") $(there "$H7/old-stuff/sub/big")"

# w-done: what keep() finds in a retired work folder under ~/.mergeworthy/work, with local bare repos as the remotes and a fake GitHub
H8="$T/home8"; W8="$H8/.mergeworthy/work"; mkdir -p "$W8"
G init -q --bare -b main "$T/w-origin.git"; G init -q -b main "$T/w-seed"; printf 'cache/\nnode_modules\n' > "$T/w-seed/.gitignore"; echo a > "$T/w-seed/README"
G -C "$T/w-seed" add .gitignore README; G -C "$T/w-seed" commit -qm base; G -C "$T/w-seed" push -q "$T/w-origin.git" main
mk() { mkdir -p "$W8/$1"; G clone -q "$T/w-origin.git" "$W8/$1/repo"; touch "$W8/$1/retired"; }
for n in clean notretired running steward owed promised untracked modified stash local stale pullref github detached outwt nested jj unread; do mk "$n"; done
mkdir -p "$W8/clean/repo/node_modules"; echo x > "$W8/clean/repo/node_modules/x"; printf '# replies owed\ndone: https://example.invalid/r answered\n' > "$W8/clean/replies-owed.md"
echo 'DONE abc123 PROMISED o/r#1: the fix (d.md)' > "$W8/clean/proposals-open.md"
rm "$W8/notretired/retired"; echo $$ > "$W8/running/gh-watch.pid"; echo "$W8/steward t1" > "$H8/.mergeworthy/steward"
printf '# replies owed\nhttps://example.invalid/c1 by alice\n' > "$W8/owed/replies-owed.md"; echo 'PROMISED o/r#1: the fix (d.md)' > "$W8/promised/proposals-open.md"
echo x > "$W8/untracked/repo/notes.txt"; echo b >> "$W8/modified/repo/README"; echo y >> "$W8/stash/repo/README"; G -C "$W8/stash/repo" stash push -q
G -C "$W8/local/repo" commit -q --allow-empty -m 'only here'
G -C "$W8/stale/repo" checkout -q -b gone; G -C "$W8/stale/repo" commit -q --allow-empty -m gone; G -C "$W8/stale/repo" push -q origin gone
git -C "$T/w-origin.git" update-ref -d refs/heads/gone  # deleted on the remote; the clone's origin/gone stays
G -C "$W8/pullref/repo" checkout -q -b fix; G -C "$W8/pullref/repo" commit -q --allow-empty -m fix; G -C "$W8/pullref/repo" push -q origin fix fix:refs/pull/1/head
git -C "$T/w-origin.git" update-ref -d refs/heads/fix  # squash-merged: the branch is gone, the pull request's head stays
G -C "$W8/github/repo" config url."$T/w-origin.git".insteadOf https://github.com/o/r.git; G -C "$W8/github/repo" remote set-url origin https://github.com/o/r.git
G -C "$W8/github/repo" checkout -q -b a; G -C "$W8/github/repo" commit -q --allow-empty -m a; G -C "$W8/github/repo" checkout -q -b b main; G -C "$W8/github/repo" commit -q --allow-empty -m b
G -C "$W8/detached/repo" worktree add -q --detach "$W8/detached/wt"; G -C "$W8/detached/wt" commit -q --allow-empty -m detached
G -C "$W8/outwt/repo" worktree add -q -b side "$T/outside-wt"
G clone -q "$T/w-origin.git" "$T/user-clone"; mkdir -p "$W8/extwt" "$W8/extdet"; touch "$W8/extwt/retired" "$W8/extdet/retired"
G -C "$T/user-clone" worktree add -q -b wt-branch "$W8/extwt/checkout"; G -C "$W8/extwt/checkout" commit -q --allow-empty -m 'on the clone outside'
G -C "$T/user-clone" worktree add -q --detach "$W8/extdet/checkout"; G -C "$W8/extdet/checkout" commit -q --allow-empty -m 'detached, on no branch'
G init -q "$W8/nested/repo/cache/inner"; echo w > "$W8/nested/repo/cache/inner/w"; mkdir -p "$W8/jj/proj/.jj"; G -C "$W8/unread/repo" remote add gone "$T/no-such.git"
sha() { G -C "$1" rev-parse HEAD | cut -c1-12; }
HOME="$H8" dsm 'calls = []
def fake(repo, sha):
    calls.append(repo + ":" + sha[:12])
    return sha.startswith(sys.argv[3])
for e in sorted(os.scandir(m.work_folder.ROOT), key=lambda e: e.name):
    calls.clear()
    why = [w.replace(os.path.realpath(e.path), ".") for w in m.work_folder.keep(e.path, fake)]
    print(e.name, " | ".join(why) or "-", " ".join(calls), sep="\t")' "$(G -C "$W8/github/repo" rev-parse a)" > "$T/keep.out"
why() { awk -F'\t' -v n="$1" '$1 == n { print $2 }' "$T/keep.out"; }
check "keep: a clean clone with an ignored node_modules, an answered reply and a delivered promise loses nothing, and asks GitHub nothing" "-|" "$(why clean)|$(awk -F'\t' '$1 == "clean" { print $3 }' "$T/keep.out")"
check "keep: a folder without retired" "its watcher has not retired" "$(why notretired)"
check "keep: a folder whose watcher's PID is alive" "its watcher is running" "$(why running)"
check "keep: the steward's watch dir" "it is the steward's watch dir (~/.mergeworthy/steward)" "$(why steward)"
check "keep: an open line in replies-owed.md" "replies-owed.md has an open line" "$(why owed)"
check "keep: a PROMISED line in proposals-open.md" "proposals-open.md has an undelivered PROMISED line" "$(why promised)"
check "keep: an untracked file" "./repo: 1 modified or untracked file(s), e.g. notes.txt" "$(why untracked)"
check "keep: a modified file" "./repo: 1 modified or untracked file(s), e.g. README" "$(why modified)"
check "keep: a stash" "./repo: 1 stash(es)" "$(why stash)"
check "keep: a commit on no remote" "./repo: commit $(sha "$W8/local/repo") is on no remote" "$(why local)"
check "keep: a branch deleted on the remote, its stale tracking ref left" "./repo: commit $(sha "$W8/stale/repo") is on no remote" "$(why stale)"
check "keep: a squash-merged branch whose remote branch is gone, its commit held by the pull request's head ref" "-" "$(why pullref)"
check "keep: tips on no remote with a GitHub remote: the one GitHub has goes, the other stays; GitHub asked once per tip" "./repo: commit $(sha "$W8/github/repo") is on no remote, nor confirmed by GitHub|2" "$(why github)|$(awk -F'\t' '$1 == "github" { print $3 }' "$T/keep.out" | wc -w)"
check "keep: a detached HEAD in a worktree of its repo" 1 "$(why detached | grep -c "commit $(sha "$W8/detached/wt") is on no remote$")"
check "keep: a worktree of its repo outside the folder" "./repo: its worktree $(readlink -f "$T")/outside-wt is outside the folder" "$(why outwt)"
check "keep: a worktree on a branch of a repo outside loses nothing, the branch stays there" "- yes" "$(why extwt) $(G -C "$T/user-clone" rev-parse -q --verify wt-branch >/dev/null && echo yes)"
check "keep: a detached HEAD in a worktree of a repo outside" "./checkout: commit $(sha "$W8/extdet/checkout") is on no remote" "$(why extdet)"
check "keep: a nested repo in an ignored folder with an untracked file" "./repo/cache/inner: 1 modified or untracked file(s), e.g. w" "$(why nested)"
check "keep: another version-control system's data" "./proj: .jj data" "$(why jj)"
check "keep: a remote that can't be read" 1 "$(why unread | grep -c '^./repo: its remote gone could not be read: ')"

# github_has: gh api's status line; nothing asked while the watchers' shared pause holds
cat > "$T/bin/gh" <<'EOF'
#!/bin/sh
# stub gh: `gh api -i repos/<r>/commits/<sha>`: 200 for sha c0ffee, 404 for repo o/missing, no answer for sha down, else 422
echo "$*" >> "$GH_LOG"
case "$3" in */down) exit 1;; repos/o/missing/*) echo 'HTTP/2.0 404 Not Found';; */c0ffee) echo 'HTTP/2.0 200 OK';; *) echo 'HTTP/2.0 422 Unprocessable Entity';; esac
EOF
chmod +x "$T/bin/gh"; export GH_LOG="$T/gh.log"; : > "$GH_LOG"
H6="$T/home6"; mkdir -p "$H6/.mergeworthy"
check "github_has: 200 True, 422 and 404 False, no answer None" "True False False None" "$(HOME="$H6" dsm 'print(*(m.github_has(r, s) for r, s in (("o/r", "c0ffee"), ("o/r", "bad"), ("o/missing", "c0ffee"), ("o/r", "down"))))')"
echo "{\"pause_until\": $(( $(date +%s) + 600 ))}" > "$H6/.mergeworthy/shared-watch.json"; : > "$GH_LOG"
check "github_has: None while the shared pause holds, gh not called" "None 0" "$(HOME="$H6" dsm 'print(m.github_has("o/r", "c0ffee"))') $(wc -l < "$GH_LOG")"

# a whole sweep: the dry run, then a deleting one, over a retired clean folder, a retired one with an untracked file, and a live one
H9="$T/home9"; W9="$H9/.mergeworthy/work"; mkdir -p "$W9" "$H9/.claude/agent-jobs"
for n in done kept live; do G clone -q "$T/w-origin.git" "$W9/$n/repo"; mkdir -p "$W9/$n/repo/node_modules" "$W9/$n/drafts/node_modules"; echo x > "$W9/$n/repo/node_modules/x"; echo x > "$W9/$n/drafts/node_modules/x"; done
touch "$W9/done/retired" "$W9/kept/retired"; echo x > "$W9/kept/repo/notes.txt"; age "$H9"
HOME="$H9" python3 "$R/bin/disk-sweep" > "$T/dry9.out" 2>&1
check "a dry run prints w-done's deletion and the kept folder's row, and deletes nothing" "1 1 kept no" "$(grep -c "^[^ ]* [0-9][0-9]* $W9/done w-done$" "$T/dry9.out") $(grep -c "^- $W9/kept: " "$T/dry9.out") $(there "$W9/done") $([ -e "$H9/.mergeworthy/work-kept.md" ] && echo yes || echo no)"
HOME="$H9" python3 "$R/bin/disk-sweep" --delete > "$T/run9.out" 2>&1
check "w-done deletes a retired folder holding nothing to lose, logged before and after" "removed deleting|deleted|" "$(there "$W9/done") $(grep "^[^ ]* [0-9][0-9]* $W9/done w-done " "$H9/.mergeworthy/disk-sweep.log" | cut -d' ' -f5 | tr '\n' '|')"
check "a retired folder that would lose something stays, with the one row of work-kept.md, as the dry run printed it" "kept 1 same" "$(there "$W9/kept/repo/notes.txt") $(grep -c '^- ' "$H9/.mergeworthy/work-kept.md") $([ "$(grep '^- ' "$T/dry9.out")" = "$(grep '^- ' "$H9/.mergeworthy/work-kept.md")" ] && echo same)"
check "a folder whose watcher didn't retire: w-done leaves it, c-ignored and c-node_modules sweep its build folders" "kept 0 removed removed" "$(there "$W9/live/repo/README") $(grep -c "$W9/live" "$H9/.mergeworthy/work-kept.md") $(there "$W9/live/repo/node_modules") $(there "$W9/live/drafts/node_modules")"

# tests/all.sh, on a root whose first suite leaves a child that calls docker after the suite exits
F="$T/allsh"; mkdir -p "$F/node_modules/typescript" "$F/docs" "$F/tests"; cp -r "$R/tests/refuse" "$F/tests/"
echo 'import subprocess; subprocess.Popen(["sh", "-c", "sleep 0.5; docker version"])' > "$F/docs/build-graphs.py"
bash "$R/tests/all.sh" "$F" > /dev/null 2> "$T/allsh.err"
check "tests/all.sh fails a suite whose child calls docker after the suite exited" "1 1" "$? $(grep -c 'called docker' "$T/allsh.err")"
echo 'import subprocess; subprocess.Popen(["sh", "-c", "sleep 0.5; docker version"], start_new_session=True)' > "$F/docs/build-graphs.py"
bash "$R/tests/all.sh" "$F" > /dev/null 2> "$T/allsh.err"
check "tests/all.sh fails a suite whose child in a session of its own calls docker after the suite exited" "1 1" "$? $(grep -c 'called docker' "$T/allsh.err")"

kill "$SPID" "$WPID"; wait "$SPID" "$WPID" 2>/dev/null
rm -rf "$T"
echo "failures: $fails"; [ "$fails" = 0 ]
