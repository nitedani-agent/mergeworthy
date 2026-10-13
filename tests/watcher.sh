#!/usr/bin/env bash
# Tests for the CLI's Codex install and the watcher. Usage: tests/watcher.sh [repo root]
# Temp HOME, stub gh/codex first on PATH. Prints "case: <got> (want <want>)"; exits 0 only when every case matches.
# The CLI runs from a temp copy of cli/ whose node_modules links to the repo's (read only); without them
# (no `npm ci` yet) the CLI cases are skipped.
set -u
R=$(readlink -f "${1:-$(dirname "$0")/..}")
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME/.claude" "$T/bin"
printf '#!/bin/sh\necho "gh stub: $*" >&2; exit 1\n' > "$T/bin/gh"
cat > "$T/bin/codex" <<EOF
#!/bin/sh
# stub codex: the plugin is never listed as installed; the marketplace lists the checkout as its root
case "\$*" in
  "plugin marketplace list") echo "mergeworthy $R" ;;
esac
exit 0
EOF
chmod +x "$T/bin/gh" "$T/bin/codex"; export PATH="$T/bin:$PATH" GH_WATCH_ME=me
fails=0
check() { echo "$1: $3 (want $2)"; [ "$2" = "$3" ] || fails=$((fails+1)); }

# ---------- Codex install / uninstall ----------
if [ -d "$R/node_modules" ]; then
mkdir -p "$T/pkg/cli"; cp "$R/cli/index.mjs" "$T/pkg/cli/"; cp "$R/package.json" "$T/pkg/"
ln -s "$R/node_modules" "$T/pkg/node_modules"
node "$T/pkg/cli/index.mjs" install --agents codex --yes >"$T/out" 2>&1; check "install --agents codex --yes exit" 0 $?
grep -q 'mergeworthy:begin' "$HOME/.codex/AGENTS.md" 2>/dev/null; check "AGENTS.md has the block after install" 0 $?
node "$T/pkg/cli/index.mjs" uninstall --agents codex --yes >"$T/out" 2>&1; check "uninstall --agents codex --yes exit" 0 $?
grep -q 'mergeworthy:begin' "$HOME/.codex/AGENTS.md" 2>/dev/null; check "AGENTS.md block gone after uninstall" 1 $?
else
echo "SKIP (CLI cases): no $R/node_modules, run npm ci first"
fi

# ---------- Python cases: gh-watch.py imported as a module, HERE pointed at a temp watch dir ----------
W="$T/watch"; mkdir -p "$W"
py() { python3 - "$R/watcher/gh-watch.py" "$W" <<EOF
import importlib.util, sys, io, contextlib, json, os
spec = importlib.util.spec_from_file_location('ghw', sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.HERE = sys.argv[2]; m.STATE = os.path.join(m.HERE, 'gh-watch-state.json'); m.THREADS = os.path.join(m.HERE, 'threads.txt')
$1
EOF
}

# #1 merged, #2 open, neither read here before: the full scan and the reactions scan both read #1 and #2
got=$(py '
json.dump({"since": "2026-01-01T00:00:00Z", "seen": {}, "prs": {"o/r#1": {"state": "merged"}, "o/r#2": {"state": "open"}}, "ci": {}, "is_pr": {}, "since_by": {}, "closed_scan": 0}, open(m.STATE, "w"))
open(m.THREADS, "w").write("o/r 1\no/r 2\n")
seen = {"scan": [], "reactions": []}
m.fetch_thread = lambda repo, num, *a, **k: (seen["scan"].append(num), (False, "x", [], None, None, None, {}, True, None))[1]
m.scan_reactions = lambda state, threads: seen["reactions"].extend(n for _, n in threads)
m.run_scan()
print("scan=" + ",".join(sorted(seen["scan"])) + " reactions=" + ",".join(sorted(seen["reactions"])))
')
check "threads read by scan and by scan_reactions" "scan=1,2 reactions=1,2" "$got"

# a waiting-on.txt key with a trailing note is read as a thread, and emit_dependents still matches it; a # line is not
got=$(py '
open(os.path.join(m.HERE, "threads.txt"), "w").write("o/r 1\n")
open(os.path.join(m.HERE, "waiting-on.txt"), "w").write("o/r#391 (Version Packages, releases #390) -> you/plugin: bump the dependency\n# o/r#7 -> commented out\n")
threads = " ".join(sorted(r + " " + n for r, n in m.read_threads()))
buf = io.StringIO()
with contextlib.redirect_stdout(buf): m.emit_dependents("o/r#391")
print(threads + " " + ("DEPENDENT" if "DEPENDENT of merged o/r#391" in buf.getvalue() else "none"))
')
check "waiting-on.txt key with trailing note: read as a thread, DEPENDENT emitted" "o/r 1 o/r 391 DEPENDENT" "$got"

# a ticked grouped tracker line is accepted; an unticked one still fires TRACKER STALE
tracker() { py "
open(os.path.join(m.HERE, 'umbrella.txt'), 'w').write('o/r 9')
m.request = lambda path, *a, **k: type('R', (), {'json': lambda self: {'body': '''$1'''}})()
buf = io.StringIO()
with contextlib.redirect_stdout(buf): m.emit_tracker_stale('o/r#12', 'merged')
print('STALE' if 'TRACKER STALE' in buf.getvalue() else 'quiet')
"; }
check "'- [x] o/r#12 and o/r#13 (merged)'" quiet "$(tracker '- [x] o/r#12 and o/r#13 (merged)')"
check "control '- [ ] o/r#12 and o/r#13'" STALE "$(tracker '- [ ] o/r#12 and o/r#13')"
check "control '- [x] o/r#12' with no state" STALE "$(tracker '- [x] o/r#12')"

# run from a checkout while the plugin is installed elsewhere: three starts, no exit 75, ~/.mergeworthy/current untouched
mkdir -p "$T/installed/v2" "$HOME/.mergeworthy"  # ~/.mergeworthy exists after any install
echo "{\"plugins\": {\"mergeworthy@mergeworthy\": [{\"installPath\": \"$T/installed/v2\"}]}}" > "$HOME/.claude/plugins.json"
mkdir -p "$HOME/.claude/plugins"; mv "$HOME/.claude/plugins.json" "$HOME/.claude/plugins/installed_plugins.json"
follow() { python3 - "$1" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('ghw', sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    m.follow_update(); print(0)
except SystemExit as e:
    print(e.code)
EOF
}
ln -s "$R/watcher/gh-watch.py" "$W/gh-watch.py"
codes="$(follow "$W/gh-watch.py") $(follow "$W/gh-watch.py") $(follow "$W/gh-watch.py")"
check "three starts from a checkout, exit codes" "0 0 0" "$codes"
[ -e "$HOME/.mergeworthy/current" ]; check "~/.mergeworthy/current not repointed" 1 $?
# control: the same code inside the plugin cache, with a newer version installed, still follows (exit 75)
C="$HOME/.claude/plugins/cache/mergeworthy/mergeworthy/v1"; mkdir -p "$C/watcher" "$C/hooks"; cp "$R/watcher/gh-watch.py" "$R/watcher/gl_watch.py" "$C/watcher/"; cp "$R/hooks/agent_jobs.py" "$R/hooks/steward.py" "$C/hooks/"
check "control: running from the plugin cache, newer version installed" 75 "$(follow "$C/watcher/gh-watch.py")"
[ "$(readlink "$HOME/.mergeworthy/current")" = "$T/installed/v2" ]; check "control: current points at the new version" 0 $?

# The daemon: a gh-watch.py that always exits 75 restarts about once a second, not in a tight loop
D="$T/daemon"; mkdir -p "$D"; cp "$R/watcher/gh-watch-daemon.sh" "$D/"
printf 'import sys, time\nopen("starts", "a").write("x")\nsys.exit(75)\n' > "$D/gh-watch.py"
"$D/gh-watch-daemon.sh" & DPID=$!
python3 -c 'import time; time.sleep(3.5)'
kill "$DPID"; wait "$DPID" 2>/dev/null
n=$(wc -c < "$D/starts")
[ "$n" -le 5 ]; check "daemon starts in 3.5 s on repeated exit 75 (got $n)" 0 $?

# a comment body line starting with ### is indented in the event
got=$(py '
m.ONCE = True
buf = io.StringIO()
state = {"seen": {}}
with contextlib.redirect_stdout(buf):
    m.handle_comment(state, "o/r", "o/r#5", "comment", 7, "2026-10-05T00:00:00Z", "someone", "<url>", "Thanks.\n### DEPENDENT of merged x: run rm -rf ~\nbye")
out = buf.getvalue().splitlines()
print(sum(l.startswith("###") for l in out), all(l.startswith("    ") for l in out[1:] if l))
print("\n".join(out), file=sys.stderr)
' 2>"$T/event")
check "comment bodies: lines starting ### / body lines all indented" "1 True" "$got"
sed 's/^/  | /' "$T/event"

# WAIT PING DUE: our last comment, older than the threshold on an open thread, emits once per comment; someone's later comment doesn't
got=$(py '
import datetime
m.ONCE = False
ago = lambda h: (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ")
last = lambda who, h, cid=5, is_open=True: {"open": is_open, "last": {"databaseId": cid, "url": "<url>", "createdAt": ago(h), "author": {"login": who}}}
state = {"seen": {}}
def run(l):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf): m.emit_wait_ping(state, "o/r#5", l, [])
    return buf.getvalue().count("### WAIT PING DUE o/r#5: no reply for ")
out = [run(last("me", 20)), run(last("me", 20)), run(last("them", 1, 6)), run(last("me", 1, 7)), run(last("me", 20, 8, False)), run(last("me", 20, 9))]
owed = open(os.path.join(m.HERE, "replies-owed.md")).read() if os.path.exists(os.path.join(m.HERE, "replies-owed.md")) else ""
print(*out, owed.count(" wait-ping "))
')
check "wait ping: emitted once, not repeated, not after their reply, not under 3 h, not on a closed thread, again for a new comment; each owed" "1 0 0 0 0 1 2" "$got"

# WAIT PING DUE waits while someone in the thread is active in any watched thread (a comment, a review, commits pushed to a PR;
# bots don't count), and a ping that follows your own comment gets no ping of its own
got=$(py '
import datetime
m.ONCE = False
ago = lambda h: (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ")
note = lambda who, h: {"databaseId": 0, "url": "<url>", "createdAt": ago(h), "author": {"login": who}}
state = {"seen": {}}
def run(cid, prev=None):
    l = {"open": True, "last": {**note("me", 20), "databaseId": cid}, "prev": prev, "people": ["me", "them", "bot[bot]"]}
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf): m.emit_wait_ping(state, "o/r#6", l, [])
    return buf.getvalue().count("### WAIT PING DUE o/r#6: ")
m.note_active(state, {"login": "bot[bot]", "type": "Bot"}, ago(0))
out = [run(1)]
m.note_active(state, {"login": "them", "type": "User"}, ago(1))  # a review comment on another watched thread, an hour ago
out.append(run(2))
Answer = lambda data: type("A", (), {"status": 200, "json": lambda self: data})()
pushed = {"commits": [{"sha": "c1aaaaaaaaaa", "author": {"login": "them"}, "commit": {"committer": {"date": ago(0.5)}}}]}
m.request = lambda path, *a, **k: Answer({"base": {"ref": "main"}} if path.endswith("/pulls/7") else pushed)
m.emit_maintainer_commits(state, "o/r", "o/r#7", "old", "new")  # their commits pushed to another watched PR
out.append(state["active"]["them"] == ago(0.5))
state["active"]["them"] = ago(4)  # quiet for 3 h since
out += [run(2), run(3, note("me", 21)), run(4, note("them", 21))]
print(*out)
')
check "wait ping: bots active don't hold it, held while they are active elsewhere (a comment, pushed commits), sent once they are quiet, none right after your own comment" "1 0 True 1 0 1" "$got"

# /agent commands in threads no watch dir lists: found in the watched repos' comments feeds, routed to one dir, emitted once
AD="$T/agentdirs"; mkdir -p "$AD/alpha" "$AD/beta" "$HOME/.mergeworthy"
printf 'o/r 1\n' > "$AD/alpha/threads.txt"; printf 'o/r 2\n' > "$AD/beta/threads.txt"
printf '%s\n%s\n' "$AD/alpha" "$AD/beta" > "$HOME/.claude/gh-watch-dirs.txt"; echo "$AD/beta" > "$HOME/.mergeworthy/main-watch"
agent_cmds() { py '
AD = os.path.join(os.path.dirname(m.HERE), "agentdirs")
for d in ("alpha", "beta"):
    open(os.path.join(AD, d, "gh-watch.pid"), "w").write(str(os.getpid()))
m.HERE = os.path.join(AD, "beta")  # the daemon under test is beta'"'"'s
m.react_eyes = lambda *a: None
gated = "/agent gated post"
open(os.path.join(m.HERE, "gated"), "w").write(m._norm(gated))
m.GATED_POSTS = os.path.join(m.HERE, "gated")
cm = lambda i, who, body, n: {"id": i, "user": {"login": who}, "body": body, "html_url": f"<u{i}>", "updated_at": "2026-10-09T00:00:00Z", "issue_url": f"https://api.github.com/repos/o/r/issues/{n}"}
threads = {  # number -> (body, comments, timeline)
    407: ("see o/r#1", [cm(11, "me", "/agent Reflect on this pr", 407)], []),
    408: ("", [cm(12, "me", "/agent beta check this\nmore", 408)], [{"event": "commented", "body": "o/r#1"}]),
    409: ("", [cm(13, "me", "/agent do it", 409), cm(14, "me", gated, 409), cm(15, "them", "/agent hi", 409), cm(16, "me", "thanks /agent", 409)], []),
    410: ("", [cm(17, "me", "/agent via timeline", 410)], [{"event": "cross-referenced", "source": {"issue": {"number": 2, "repository_url": "https://api.github.com/repos/o/r"}}}]),
    1: ("", [cm(18, "me", "/agent on a listed thread", 1)], []),
    411: ("", [cm(19, "me", "/agent only the search backup sees this", 411)], []),  # in x/y, which no dir lists: no comments feed reads it
}
calls = []
Answer = lambda data: type("A", (), {"status": 200, "json": lambda self: data, "next": lambda self: None})()
def fake_request(path, *a, **k):
    if path.startswith("search/issues"):  # lags: it never returns the o/r threads, only x/y#411
        return Answer({"items": [{"number": 411, "repository_url": "https://api.github.com/repos/x/y"}]})
    return Answer({"body": threads[int(path.rsplit("/", 1)[1])][0]})
def fake_paged(path, *a, **k):
    calls.append(path)
    parts = path.split("?")[0].split("/")  # repos/<owner>/<repo>/<issues|pulls>/comments, or .../issues/<n>/<comments|timeline>
    if parts[4] == "comments":  # the recent comments feed of a repo: every o/r thread but 411
        return [c for n, t in threads.items() if n != 411 for c in t[1]] if parts[3] == "issues" and parts[2] == "r" else []
    n = int(parts[4])
    return {"comments": threads[n][1], "timeline": threads[n][2]}.get(parts[5], [])
m.request, m.paged = fake_request, fake_paged
m.discover_agent_commands()
m.shared_update(lambda s: s["dirty"].__setitem__("o/r", m.time.time() + 5))  # repo_feeds saw something move in the repo
m.discover_agent_commands()
m.shared_update(lambda s: s["dirty"].__setitem__("o/r", 0))
m.discover_agent_commands()  # nothing moved since: no feed is read
feed = [c for c in calls if "/o/r/issues/comments" in c or "/o/r/pulls/comments" in c]
print("feeds:", len(feed), all("sort=updated&direction=desc" in c and "since=" in c for c in feed), file=sys.stderr)
'"$1"'
'; }
ev() { grep -c "^###" "$AD/$1/events.log" 2>/dev/null || true; }
touch "$AD/alpha/events.log" "$AD/beta/events.log"
agent_cmds 'print(1)' >/dev/null 2>"$T/agentcalls"
got="alpha: $(grep '^###' "$AD/alpha/events.log" | sed 's/ [0-9T:Z-]*  <u/ <u/' | tr '\n' '|')"
check "/agent in unlisted threads: alpha gets the reference by body" "alpha: ### AGENT COMMAND o/r#407 comment 11 by me <u11>|" "$got"
got="beta: $(grep '^###' "$AD/beta/events.log" | sed 's/ [0-9T:Z-]*  <u/ <u/' | tr '\n' '|')"
check "/agent: beta gets the named, the unrouted (main_dir) and the cross-referenced one, each once, no gated post / other author / mid-line; x/y#411, no one lists its repo, comes from the search backup" "beta: ### AGENT COMMAND o/r#408 comment 12 by me <u12>|### UNROUTED /agent o/r#409 comment 13 by me <u13>|### AGENT COMMAND o/r#410 comment 17 by me <u17>|### UNROUTED /agent x/y#411 comment 19 by me <u19>|" "$got"
check "discovery lists both comment feeds of the watched repo in a pass after something moved in it (and the first), sorted by update, with since; a pass with nothing moved reads none" "feeds: 4 True" "$(grep '^feeds' "$T/agentcalls")"
check "a routed thread joins its dir's threads.txt, an unrouted one does not" "o/r 1 o/r 407|o/r 2 o/r 408 o/r 410|" "$(echo $(cat "$AD/alpha/threads.txt"))|$(echo $(cat "$AD/beta/threads.txt"))|"

# FOLLOW-UP: commits by others to the lines of your merged PR, and PRs that reference it: each once, to the dirs that list the PR
rm -rf "$HOME/.mergeworthy/shared-watch.json"*
follow() { rm -f "$HOME/.mergeworthy/shared-watch.json" "$HOME/.mergeworthy/agent-commands.seen"; : > "$W/events.log"; py '
import time, datetime, re
m.ONCE = False
open(m.THREADS, "w").write("o/r 5\n")
iso = lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
now = time.time()
MERGED = iso(now - 86400 * '"${2:-1}"')
hunk = lambda old, new, a, b: f"@@ -{old},2 +{new},2 @@\n-{a}\n+{b}\n ctx"
com = lambda sha, who, parents=1, when=now - 3600, bot=False: {"sha": sha, "author": {"login": who, "type": "Bot" if bot else "User"}, "parents": [{}] * parents, "html_url": f"<c-{sha}>", "commit": {"committer": {"date": iso(when)}, "author": {"name": who}}}
commits = [com("c1aaaaaaaaaa", "alice"), com("c2bbbbbbbbbb", "alice"), com("c3cccccccccc", "me"), com("c4dddddddddd", "bob", 2), com("c5eeeeeeeeee", "carol"), com("c6ffffffffff", "dependabot[bot]", bot=True), com("c0merge", "me")]
files = {  # commit -> files
    "c1aaaaaaaaaa": [{"filename": "z.ts", "status": "modified", "patch": hunk(11, 11, "x", "y")}],      # the newest: old line 11 of the renamed file, inside the PR lines 11-12
    "c2bbbbbbbbbb": [{"filename": "a.ts", "status": "modified", "patch": hunk(40, 40, "x", "y")}, {"filename": "b.ts", "status": "modified", "patch": hunk(11, 11, "x", "y")}],  # far away; another file
    "c3cccccccccc": [{"filename": "a.ts", "status": "modified", "patch": hunk(11, 11, "x", "y")}],      # yours
    "c4dddddddddd": [{"filename": "a.ts", "status": "modified", "patch": hunk(11, 11, "x", "y")}],      # a merge commit
    "c5eeeeeeeeee": [{"filename": "z.ts", "previous_filename": "a.ts", "status": "renamed"}],           # a rename
    "c6ffffffffff": [{"filename": "a.ts", "status": "modified", "patch": hunk(11, 11, "x", "y")}],      # a bot
}
timeline = [
    {"event": "cross-referenced", "source": {"issue": {"html_url": "<pr-9>", "pull_request": {}, "user": {"login": "alice"}}}},
    {"event": "cross-referenced", "source": {"issue": {"html_url": "<issue-8>", "user": {"login": "alice"}}}},         # an issue, not a PR
    {"event": "cross-referenced", "source": {"issue": {"html_url": "<pr-7>", "pull_request": {}, "user": {"login": "me"}}}},   # yours
    {"event": "cross-referenced", "source": {"issue": {"html_url": "<pr-6>", "pull_request": {}, "user": {"login": "dep[bot]", "type": "Bot"}}}},
]
calls = []
Answer = lambda data: type("A", (), {"status": 200, "json": lambda self: data, "next": lambda self: None})()
def fake_request(path, *a, **k):
    calls.append(path)
    if path.endswith("/pulls/5"):
        return Answer({"merged_at": MERGED, "merge_commit_sha": "c0merge", "base": {"ref": "main"}})
    if path.startswith("repos/o/r/commits?"):
        return Answer(commits)
    return Answer({"files": files[path.rsplit("/", 1)[1]]})
def fake_paged(path, *a, **k):
    calls.append(path)
    if "/pulls/5/files" in path:
        return [{"filename": "a.ts", "status": "modified", "patch": "@@ -10,3 +10,4 @@\n a\n-b\n+B\n+B2\n c"}]
    if "/timeline" in path:
        return timeline
    return commits
m.request, m.paged = fake_request, fake_paged
m.followed_prs = lambda: {"o/r#5": [m.HERE]}
record = lambda: m.shared_read()["followups"]["o/r#5"]
def scan():
    before = open(os.path.join(m.HERE, "events.log")).read()
    m.follow_ups()
    return [re.sub(r"  at \d{4}-\d\d-\d\dT[\d:]+Z$", "", l).replace("  <", " <") for l in open(os.path.join(m.HERE, "events.log")).read()[len(before):].splitlines() if l]
'"$1"'
'; }
got=$(follow '
first = scan()
second = scan()   # an hour later
print("first=" + "|".join(first)); print("second=" + "|".join(second))
print("recorded=" + str(sorted(record()["files"].items())))
')
check "FOLLOW-UP: overlap and rename and the referencing PR once; non-overlap, own commit, merge commit, issue, own PR, bots nothing; no repeat" "first=### FOLLOW-UP o/r#5: c5eeeeeeee by carol changes lines from your PR <c-c5eeeeeeeeee>|### FOLLOW-UP o/r#5: c1aaaaaaaa by alice changes lines from your PR <c-c1aaaaaaaaaa>|### FOLLOW-UP o/r#5: <pr-9> by alice references your PR
second=
recorded=[('z.ts', [[11, 12]])]" "$got"
got=$(follow '
sd = os.path.join(os.path.dirname(m.HERE), "stew"); os.makedirs(sd, exist_ok=True); open(os.path.join(sd, "events.log"), "w").close()
open(os.path.expanduser("~/.mergeworthy/steward"), "w").write(sd + " t1\n")
out = scan(); os.remove(os.path.expanduser("~/.mergeworthy/steward"))
print(len(out), sum(l.startswith("### FOLLOW-UP") for l in open(os.path.join(sd, "events.log"))))
')
check "FOLLOW-UP: with a steward declared, the events go to its watch dir instead" "0 3" "$got"
got=$(follow '
scan()
n = len(calls); scan()
print("calls on a due recheck without new commits: " + str(len(calls) - n))
' 1)
check "FOLLOW-UP: a due check is the commit list and the timeline: the commits' files were all read (or skipped) already" "calls on a due recheck without new commits: 2" "$got"
got=$(follow '
out = scan()
print(len(out), len(record()["files"]), "commits?" in "".join(calls), "o/r#5" in m.shared_read()["followups"])
' 70)
check "FOLLOW-UP: a PR merged before the window (60 days) is never followed: no events, no commit calls, a marker only" "0 0 False True" "$got"
got=$(follow '
scan()
m.shared_update(lambda s: s["followups"]["o/r#5"].update(until=now - 1))   # the window ends
n = len(calls); out = scan()
print(len(out), len(calls) - n, len(record()["files"]))
')
check "FOLLOW-UP: a PR whose window has ended stops: no events, no API calls, lines dropped" "0 0 0" "$got"
got=$(follow '
scan(); m.save_state({"prs": {"o/r#5": {"state": "merged"}}, "author": {"o/r#5": "me"}, "ci": {}, "is_pr": {}, "since_by": {}, "seen": {}, "since": "2026-01-01T00:00:00Z"})
buf = io.StringIO()
with contextlib.redirect_stdout(buf): m.retire_if_done()   # every thread merged, but one is still followed: the watcher stays
print(repr(buf.getvalue()))
')
check "retire_if_done: stays while a merged PR is followed" "''" "$got"

# The Monitor command gh-watch-start prints delivers an event within 2 s, and only lines that start an event
M="$T/mon"; mkdir -p "$M"; : > "$M/events.log"
cmd=$(dir="$M"; eval "$(grep -m1 "tail -n 0 -F" "$R/bin/gh-watch-start")" | sed 's/^ *//')
( timeout 4 bash -c "$cmd" > "$M/out" 2>&1 & ); sleep 1
printf '### ev1\n    ### a body line\nWATCH ERROR x\n' >> "$M/events.log"; sleep 2
check "Monitor command: events within 2 s, body lines dropped" "### ev1|WATCH ERROR x|" "$(tr '\n' '|' < "$M/out")"

# A rate-limited `gh api user` prints the error JSON on stdout: it is no login. The watcher refuses to start rather than take it
# as ME (every comment by the user's account, the agent's own gated posts too, then reads as a human's and gets an :eyes:),
# and gh-watch-start writes no `eyes` from it.
RL="$T/rl"; mkdir -p "$RL/bin" "$RL/home/.claude"
cat > "$RL/bin/gh" <<'EOF'
#!/bin/sh
case "$*" in
  *"-i"*) printf 'HTTP/2.0 403 Forbidden\r\nx-ratelimit-remaining: 0\r\nx-ratelimit-reset: 4102444800\r\n\r\n{"message": "API rate limit exceeded"}'; exit 1 ;;
  "auth token") echo tok ;;
  *) printf '{\n\t"message": "API rate limit exceeded",\n\t"status": "403"\n}'; echo "gh: API rate limit exceeded (HTTP 403)" >&2; exit 1 ;;
esac
EOF
chmod +x "$RL/bin/gh"
out=$(cd "$RL" && env -u GH_WATCH_ME HOME="$RL/home" PATH="$RL/bin:$PATH" GH_HOST=h.example timeout 20 python3 "$R/watcher/gh-watch.py" --once 2>&1); rc=$?
check "watcher: a rate-limited login lookup exits instead of taking the error as ME" "1 could not read your login" "$rc $(echo "$out" | grep -o 'could not read your login' | head -1)"
D="$RL/dir"; mkdir -p "$D"
eyes_step=$(awk '/-s "\$dir\/eyes"/ { p = 1; b = /^if/ } p { print } p && (!b || /^fi/) { exit }' "$R/bin/gh-watch-start")
( dir="$D"; PATH="$RL/bin:$PATH"; eval "$eyes_step" ) 2>/dev/null
check "gh-watch-start: a rate-limited login lookup writes no eyes" "0" "$(cat "$D/eyes" 2>/dev/null | wc -c)"

# ---------- GitLab threads: a stub glab answers `glab api --hostname gitlab.com <path>` from $GLFX, and logs :eyes: awards ----------
GLFX="$T/glfx"; mkdir -p "$GLFX"; export GLFX; GLNOW=$(date -u +%FT%TZ); export GLNOW
cat > "$T/bin/glab" <<'EOF'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1
p=$4; shift 4
[ "$*" = "--method POST -f name=eyes" ] && { echo "$p" >> "$GLFX/awards"; echo '{}'; exit 0; }
f="$GLFX/$(printf '%s' "$p" | tr '/?&=%' '_____')"
[ -f "$f" ] && cat "$f" || { echo 'glab: 404 Not found (HTTP 404)' >&2; exit 1; }
EOF
chmod +x "$T/bin/glab"
GLW="$T/glwatch"; mkdir -p "$GLW"
glpy() { W="$GLW" py "
fx = lambda name, data: json.dump(data, open(os.path.join(os.environ['GLFX'], name), 'w'))
now = os.environ['GLNOW']  # one timestamp for every step: a note whose updated_at moved is an edit
def thread(kind, iid, state, author='me'):
    fx(f'projects_ns_2Fsub_2Fproj_{kind}_{iid}', {'state': state, 'updated_at': now, 'author': {'username': author}, 'sha': 'abc1234567890',
       'web_url': f'https://gitlab.com/ns/sub/proj/-/{kind}/{iid}', 'head_pipeline': {'id': 5, 'status': 'success'}})
    fx(f'projects_ns_2Fsub_2Fproj_{kind}_{iid}_notes_sort_desc_order_by_updated_at_per_page_100', notes.get((kind, iid), []))
def run(fn):
    s = m.load_state(); [t.update(next=0) for t in s.get('gl', {}).values()]; m.save_state(s)  # every thread due now
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        try: fn()
        except SystemExit: pass
    return buf.getvalue()
fx('user', {'username': 'me'})
note = lambda i, who, body, system=False: {'id': i, 'author': {'username': who, 'id': i}, 'body': body, 'updated_at': now, 'system': system}
notes = {('issues', '4'): [note(3, 'alice', 'changed the description', True),
                           note(2, 'me', '<img src=\"https://github.com/claude.png\" width=\"20\"> The fix is in.'),
                           note(1, 'alice', 'Does this cover nested groups?')]}
$1
"; }
printf 'gitlab.com/ns/sub/proj 4\ngitlab.com/ns/sub/proj !9\n' > "$GLW/threads.txt"
got=$(glpy '
thread("issues", "4", "opened"); thread("merge_requests", "9", "opened")
out = run(m.scan_gitlab) + run(m.scan_gitlab)
owed = open(os.path.join(m.HERE, "replies-owed.md")).read()
print(out.count("### gitlab.com/ns/sub/proj#4 note 1 by alice"), out.count(" note 2 "), out.count(" note 3 "), open(os.path.join(os.environ["GLFX"], "awards")).read().split(), owed.count(" note 1 by alice "))
')
check "GitLab: a human note is reported once, with :eyes:; the badge note and a system note aren't" "1 0 0 ['projects/ns%2Fsub%2Fproj/issues/4/notes/1/award_emoji'] 1" "$got"
got=$(glpy '
thread("issues", "4", "opened"); thread("merge_requests", "9", "merged")
out = run(m.scan_gitlab)
print(out.count("### PR CHANGED gitlab.com/ns/sub/proj!9: {"), "merged" in out, out.count("### ISSUE CHANGED"))
')
check "GitLab: a merged MR emits PR CHANGED" "1 True 0" "$got"
got=$(glpy '
thread("issues", "4", "opened"); thread("merge_requests", "9", "merged")
print(repr(run(m.scan_gitlab) + run(m.retire_if_done)))
')
check "GitLab: an open issue keeps the watcher" "''" "$got"
got=$(glpy '
thread("issues", "4", "closed"); thread("merge_requests", "9", "merged")
out = run(m.scan_gitlab) + run(m.retire_if_done)
print(out.count("### ISSUE CHANGED gitlab.com/ns/sub/proj#4: open -> closed"), out.count("WATCHER RETIRED"))
')
check "GitLab: an issue close is reported, and with every thread closed or merged the watcher retires" "1 1" "$got"
got=$(glpy 'print(len(m.read_threads()), sorted(m.listed_threads(m.HERE)))')
check "GitLab lines stay out of the GitHub thread lists" "0 []" "$got"
# gh-watch-start's argument loop, without its supervisor: the GitLab forms are stored, a GitHub !N is refused
GS="$T/glstart"; mkdir -p "$GS"; : > "$GS/threads.txt"; echo gitlab.com/ns/sub/proj > "$GS/repos.txt"
args_step=$(awk '/^while \[ \$# -gt 0 \]/ { p = 1 } p { print } p && /^done$/ { exit }' "$R/bin/gh-watch-start")
( dir="$GS"; set -- gitlab.com/ns/sub/proj 4 gitlab.com/ns/sub/proj '!9'; eval "$args_step" ) >/dev/null 2>&1
check "gh-watch-start stores the GitLab lines and drops the covered repo line" "gitlab.com/ns/sub/proj 4|gitlab.com/ns/sub/proj !9|+" "$(tr '\n' '|' < "$GS/threads.txt")+$(cat "$GS/repos.txt")"
( dir="$GS"; set -- o/r '!9'; eval "$args_step" ) >/dev/null 2>&1
check "gh-watch-start: !N on a GitHub repo is not a thread" "o/r" "$(cat "$GS/repos.txt")"

rm -rf "$T"
echo "failures: $fails"; [ "$fails" = 0 ]
