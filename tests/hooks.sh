#!/usr/bin/env bash
# Tests for the hooks: stop-lint, pre-bash-guard's check_turn, post-bash-register. Usage: tests/hooks.sh [repo root]
# Runs every case under a temp HOME with a stub `gh` first on PATH; prints "case: <got> (want <want>)".
# Exits 0 only when every case gives what it wants. Stub URLs are example.invalid on purpose, except where
# post-bash-register must see github.com URLs (those go only into the hook's stdin, never to this script's output).
set -u
R=$(readlink -f "${1:-$(dirname "$0")/..}")
export MERGEWORTHY_PYDEPS=${MERGEWORTHY_PYDEPS:-$HOME/.mergeworthy/pydeps}  # the shell parser the hooks run, installed once outside the temp HOME
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME/.claude" "$T/bin" "$T/fx"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# stub gh: answers `gh api <path>` from $FX/<path with / ? & = replaced by _>; exit 1 when the fixture is missing (a 404)
# ...and `gh pr view [<ref>] --json number` from $FX/pr_view_<ref with / and : replaced by _>, or $FX/pr_view_current without a ref (none: gh's "no pull requests found")
# ...and `gh pr checks <url> --json name,bucket` from $FX/pr_checks_<url with / and : replaced by _> (none: "no checks reported"; a URL not on github.com: gh's "no pull requests found")
# A `--jq .a.b` on a fixture holding a JSON object answers that field, as gh does; any other fixture is the answer as it stands
[ -n "${GH_STUB_PWD:-}" ] && echo "$1 $2 $PWD" >> "$GH_STUB_PWD"  # each call and where it ran, for a check that must run gh in the command's dir
[ "$1 $2" = "config get" ] && { [ ! -f "$FX/login" ] || cat "$FX/login"; exit; }  # the login gh's own config names: $FX/login
[ "$1 $2" = "pr view" ] && [ -n "$GH_STUB_NOHOST" ] &&{ echo 'none of the git remotes configured for this repository point to a known GitHub host' >&2; exit 1; }
if [ "$1 $2" = "pr view" ]; then r=$3; case "$r" in -*|'') r=current;; esac; f="$FX/pr_view_$(printf '%s' "$r" | tr '/:' '__')"; [ -f "$f" ] && cat "$f" && exit 0; echo 'no pull requests found for branch "x"' >&2; exit 1; fi
[ "$1 $2" = "pr checks" ] && [ "${3#https://github.com/}" = "$3" ] && { echo "no pull requests found for branch \"$3\"" >&2; exit 1; }
if [ "$1 $2" = "pr checks" ]; then f="$FX/pr_checks_$(printf '%s' "$3" | tr '/:' '__')"; [ -f "$f" ] && cat "$f" && exit 1; echo "no checks reported on the 'x' branch" >&2; exit 1; fi
[ "$1" = api ] || exit 1
f="$FX/$(printf '%s' "$2" | tr '/?&=' '____')"
for a in "$@"; do case "$a" in o=*) [ -f "${f}_${a#o=}" ] && f="${f}_${a#o=}";; esac; done  # graphql: $FX/graphql_<owner> answers for that owner
[ -n "$GH_STUB_403" ] && { echo 'gh: API rate limit exceeded for user ID 1. (HTTP 403)' >&2; exit 1; }
[ -f "$f" ] || { printf '{"message":"Not Found","status":"404"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }  # gh prints the error's JSON body too
q=; while [ $# -gt 0 ]; do [ "$1" = --jq ] && q=$2; shift; done
python3 -c 'import json, re, sys
raw = open(sys.argv[1]).read(); q = sys.argv[2]
try: v = json.loads(raw)
except ValueError: v = None
if isinstance(v, dict) and re.fullmatch(r"(\.\w+)+", q):
    for k in q.split(".")[1:]: v = v.get(k) if isinstance(v, dict) else None
    print("" if v is None else v if isinstance(v, str) else json.dumps(v))
else: sys.stdout.write(raw)' "$f" "$q"
EOF
chmod +x "$T/bin/gh"; export PATH="$T/bin:$PATH" FX="$T/fx"
fails=0
TASKW="$HOME/.mergeworthy/work/t"; TCO="$TASKW/repo"; mkdir -p "$TASKW"
printf 'Tier: S, because one bounded fix\n\n- [ ] fix the thing https://github.com/o/r/issues/1\n' > "$TASKW/scope.md"
git init -q -b fix "$TCO"; git -C "$TCO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a; git -C "$TCO" remote add origin https://github.com/o/r.git
quick() { # <checkout> [extra log lines]: records its HEAD's quick gates
  local f; f=$(mktemp "$T/quick.XXXXXX"); printf 'pnpm test -> exit 0 (3 tests)\n%s' "${2:-}" > "$f"; (cd "$1" && bash "$R/bin/pr-steps" quick "$f" >/dev/null); }
quick "$TCO"
printf 'Root cause: src/a.ts:3 does it\n| Candidate | Rating | Why |\n|---|---|---|\n| Not building it | 3 | the bug stays |\n| Fix it | 8 | one place |\n\nChosen: Fix it\n' > "$T/approach.md"
(cd "$TCO" && bash "$R/bin/pr-steps" approach "$T/approach.md" >/dev/null)
check() { # name want got
  echo "$1: $3 (want $2)"; [ "$2" = "$3" ] || fails=$((fails+1))
}

# ---------- session-start: the rules arrive framed as the user's instructions ----------
ss_first=$(CLAUDE_PLUGIN_ROOT="$R" bash "$R/hooks/session-start" 2>/dev/null </dev/null | head -1)
check "session-start opens as the user's instructions, like CLAUDE.md" yes "$(printf '%s' "$ss_first" | grep -q '^IMPORTANT: These are the user.s instructions.*OVERRIDE any default behavior' && echo yes || echo no)"
printf 'MERGEWORTHY_BADGE=on\n' > "$HOME/.mergeworthy/settings.env"
CLAUDE_PLUGIN_ROOT="$R" bash "$R/hooks/session-start" >/dev/null 2>&1 </dev/null
check "session-start given no plugin options keeps settings.env" 'MERGEWORTHY_BADGE=on' "$(cat "$HOME/.mergeworthy/settings.env")"
CLAUDE_PLUGIN_ROOT="$R" CLAUDE_PLUGIN_OPTION_BADGE=off bash "$R/hooks/session-start" >/dev/null 2>&1 </dev/null
check "session-start writes the options it is given" 'MERGEWORTHY_BADGE=off' "$(cat "$HOME/.mergeworthy/settings.env")"
rm -f "$HOME/.mergeworthy/settings.env"
check "session-start still carries the always-on rules" yes "$(CLAUDE_PLUGIN_ROOT="$R" bash "$R/hooks/session-start" 2>/dev/null </dev/null | grep -q '^## Always-on rules (mergeworthy)' && echo yes || echo no)"
# ---------- shared state under ~/.mergeworthy changes only from a real input: an empty environment leaves it as it was ----------
EH="$T/emptyhome"; mkdir -p "$EH/.mergeworthy" "$EH/.claude/projects/$(printf '%s' "$EH/cwd" | sed 's/[^A-Za-z0-9]/-/g')" "$EH/cwd"
printf 'MERGEWORTHY_BADGE=on\nMERGEWORTHY_WATCHER=on\n' > "$EH/.mergeworthy/settings.env"; echo /keep > "$EH/.mergeworthy/memory-roots.txt"; echo /keep > "$EH/.mergeworthy/main-watch"
ln -s /keep "$EH/.mergeworthy/current"; snap() { (cd "$EH" && find . -path ./cwd -prune -o -print | sort; cat .mergeworthy/settings.env .mergeworthy/memory-roots.txt .mergeworthy/main-watch; readlink .mergeworthy/current) | md5sum; }
before=$(snap)
(cd "$EH/cwd" && env -i HOME="$EH" PATH="$PATH" bash "$R/hooks/session-start" </dev/null >/dev/null 2>&1
 env -i HOME="$EH" PATH="$PATH" python3 "$R/bin/memory-prep" init "" "" </dev/null >/dev/null 2>&1
 env -i HOME="$EH" PATH="$PATH" bash "$R/bin/gh-watch-start" --main "" </dev/null >/dev/null 2>&1)
check "session-start, memory-prep and gh-watch-start with no input leave ~/.mergeworthy unchanged (settings, roots, main dir, current link, no new files)" "$before" "$(snap)"
check "memory-prep init with an empty folder or thread is refused" 1 "$(cd "$EH/cwd" && env -i HOME="$EH" PATH="$PATH" python3 "$R/bin/memory-prep" init "" t1 </dev/null >/dev/null 2>&1; echo $?)"
(cd "$EH/cwd" && env -i HOME="$EH" PATH="$PATH" CLAUDE_PLUGIN_ROOT="$R" CLAUDE_PLUGIN_OPTION_BADGE=off bash "$R/hooks/session-start" </dev/null >/dev/null 2>&1)
check "session-start writes only the options it was given, keeping the rest" "MERGEWORTHY_BADGE=off MERGEWORTHY_WATCHER=on" "$(sort "$EH/.mergeworthy/settings.env" | xargs)"

# ---------- stop-lint ----------
sleep 600 & SPID=$!
WD="$T/work/x"; mkdir -p "$WD" "$T/work/x-2/sub" "$WD/sub"
echo "$SPID" > "$WD/gh-watch.pid"
echo "$WD" > "$HOME/.claude/gh-watch-dirs.txt"
tr_file() { # final assistant text [work: the session started an agent, so it does mergeworthy work]
  python3 -c 'import json,sys; print(json.dumps({"type":"user","message":{"content":"tidy up the README"}}))
if sys.argv[2:] == ["work"]: print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","id":"a1","input":{"prompt":"x"}}]}}))
print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":sys.argv[1]}]}}))' "$@" > "$T/tr.jsonl"
}
stop() { # cwd (the other checks; the check-in has its own test)
  python3 -c 'import json,sys; print(json.dumps({"transcript_path":sys.argv[1],"cwd":sys.argv[2]}))' "$T/tr.jsonl" "$1" \
    | MERGEWORTHY_STOP_CHECKIN=off python3 "$R/hooks/stop-lint.py" 2>"$T/err"; echo $?
}
checkin() { # stop_hook_active
  python3 -c 'import json,sys; print(json.dumps({"transcript_path":sys.argv[1],"cwd":sys.argv[2],"stop_hook_active":sys.argv[3]=="1"}))' "$T/tr.jsonl" "$T" "$1" \
    | MERGEWORTHY_STOP_CHECKIN=on python3 "$R/hooks/stop-lint.py" 2>"$T/err"; echo $?
}
tr_file "Loop A is done." work
check "the first stop of a turn gets the check-in" 2 "$(checkin 0)"
check "the next stop goes through" 0 "$(checkin 1)"
check "no second check-in within 30 minutes of the last" 0 "$(checkin 0)"
python3 -c 'import json; print(json.dumps({"type":"user","message":{"content":"Act as the review sub-agent for this task.\n\nCheck the diff."}})); print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"CLEAN"}]}}))' > "$T/tr.jsonl"
check "a delegated child ends with its result, no check-in" 0 "$(checkin 0)"
python3 -c 'import json; print(json.dumps({"type":"user","message":{"content":"Act as the review sub-agent for this task.\n\nCheck the diff."}})); print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","id":"a1","input":{"prompt":"x"}}]}})); print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"Should I open the PR?"}]}}))' > "$T/tr.jsonl"
check "a delegated child's result is the main session's to judge: a question in it is no hand-back" 0 "$(stop "$T")"
forks() { python3 -c 'import json,sys
print(json.dumps({"type":"user","message":{"content":"status?"}}))
for t in sys.argv[1:]: print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":t}]}}))' "$@" > "$T/tr.jsonl"; }
forks $'#20 is in review.\n\nGENUINE-FORK: publish as 0.1.0, or 1.0.0; I recommend 0.1.0.' $'#21 is ready.\n\nGENUINE-FORK: publish as 0.1.0, or 1.0.0; I recommend 0.1.0.'; f1=$(stop "$T"); f1e=$(grep -c 'already sent' "$T/err")
forks $'#20 is in review.\n\nGENUINE-FORK: publish as 0.1.0, or 1.0.0; I recommend 0.1.0.' $'#21 is ready.\n\nGENUINE-FORK: publish now as 0.1.0, or after #20 lands; I recommend after #20.'; f2=$(stop "$T")
check "BLOCK: a GENUINE-FORK line already sent this session; one with changed options passes" "2 1 0" "$f1 $f1e $f2"
tr_file "The watcher runs and the Monitor is armed."
check "no replies-owed.md, cwd=watch dir" 0 "$(stop "$WD")"
F40=$(date -u -d '-40 minutes' +%FT%TZ); F10=$(date -u -d '-10 minutes' +%FT%TZ)
printf '### FOLLOW-UP o/r#5, #6: abcdef1234 by carol changes lines from your PR  <c>  at %s\n### FOLLOW-UP o/r#5: https://github.com/o/r/pull/9 by alice references your PR  at %s\n' "$F40" "$F10" > "$WD/events.log"
check "BLOCK: a FOLLOW-UP unsorted after 30 minutes, named; a newer one waits" "2 1 0" "$(stop "$WD") $(grep -c abcdef1234 "$T/err") $(grep -c pull/9 "$T/err")"
printf '### MAINTAINER REVIEW o/r#5: https://github.com/o/r/pull/5#pullrequestreview-71 by magne reviews your PR  at %s\n' "$F40" >> "$WD/events.log"
check "BLOCK: a MAINTAINER REVIEW unsorted after 30 minutes, named" "2 1" "$(stop "$WD") $(grep -c pullrequestreview-71 "$T/err")"
echo "abcdef1234 nothing to act on" > "$WD/followups-sorted.txt"
check "BLOCK: 'nothing to act on' is not a verdict" 2 "$(stop "$WD")"
printf 'abcdef1234567 TASTE https://example.invalid/notes\nhttps://github.com/o/r/pull/5#pullrequestreview-71 MISS https://example.invalid/ledger\n' > "$WD/followups-sorted.txt"
check "a verdict line in followups-sorted.txt sorts it" 0 "$(stop "$WD")"
rm "$WD/events.log" "$WD/followups-sorted.txt"
printf '### FOLLOW-UP o/r#5: https://github.com/o/r/pull/5#rename-2026-10-14T10:00:00Z by brillout renames your PR: "fix: a" -> "fix(core): a"  at %s\n' "$F40" > "$WD/events.log"
check "BLOCK: the watcher's PR-rename FOLLOW-UP unsorted after 30 minutes, named" "2 1" "$(stop "$WD") $(grep -c 'pull/5#rename-2026-10-14T10:00:00Z' "$T/err")"
rm "$WD/events.log"
echo "o/r 1 comment 42 by someone" > "$WD/replies-owed.md"
check "control: open owed line, cwd=watch dir" 2 "$(stop "$WD")"
check "control: open owed line, cwd=inside watch dir" 2 "$(stop "$WD/sub")"
echo "holding: https://github.com/o/r/issues/1#issuecomment-9 $(date -u -d '+1 hour' +%FT%TZ)" > "$WD/replies-owed.md"
check "a holding line whose ETA is ahead passes" 0 "$(stop "$WD")"
echo "holding: https://github.com/o/r/issues/1#issuecomment-9 $(date -u -d '-1 hour' +%FT%TZ)" > "$WD/replies-owed.md"
check "BLOCK: a holding line past its ETA is owed again" 2 "$(stop "$WD")"
echo "drafting: https://github.com/o/r/issues/1#issuecomment-9 $(date -u -d '+1 hour' +%FT%TZ)" > "$WD/replies-owed.md"
check "a drafting line whose ETA is ahead passes" 0 "$(stop "$WD")"
echo "drafting: https://github.com/o/r/issues/1#issuecomment-9 $(date -u -d '-1 hour' +%FT%TZ)" > "$WD/replies-owed.md"
check "BLOCK: a drafting line past its ETA is owed again" 2 "$(stop "$WD")"
ev0=$(cat "$WD/events.log" 2>/dev/null); printf '%s\n### gitlab.com/g/p!99 note 4041083988 by owner %s  https://gitlab.com/g/p/-/merge_requests/99#note_4041083988\n' "$ev0" "$(date -u -d '-20 minutes' +%FT%TZ)" > "$WD/events.log"
echo "drafting: https://gitlab.com/g/p/-/merge_requests/99#note_4041083988 $(date -u -d '+150 minutes' +%FT%TZ)" > "$WD/replies-owed.md"
d1=$(stop "$WD"); d1e=$(grep -c 'holding reply now' "$T/err")
echo "drafting: https://gitlab.com/g/p/-/merge_requests/99#note_4041083988 $(date -u -d '+5 minutes' +%FT%TZ)" > "$WD/replies-owed.md"
check "BLOCK: a drafting line due 170 minutes after the comment wants a holding reply; one due within 30 minutes passes" "2 1 0" "$d1 $d1e $(stop "$WD")"
printf '%s\n' "$ev0" > "$WD/events.log"
rm "$WD/replies-owed.md"; mkdir -p "$WD/hold/drafts"
printf 'PROMISED o/r#1: post the fix by %s (reply.md)\nPROMISED o/r#1: a docs PR on OK (docs.md)\n' "$(date -u -d '+1 hour' +%FT%H:%MZ)" > "$WD/proposals-open.md"
check "a PROMISED line whose time is ahead, or with no time, passes" 0 "$(stop "$WD")"
printf 'PROMISED o/r#1: post the fix by %s (reply.md)\n' "$(date -u -d '-1 hour' +%FT%H:%MZ)" > "$WD/proposals-open.md"
check "BLOCK: a PROMISED line past its time, naming it" "2 1" "$(stop "$WD") $(grep -c 'post the fix' "$T/err")"
printf 'DONE https://github.com/o/r/pull/2 PROMISED o/r#1: post the fix by %s (reply.md)\n' "$(date -u -d '-1 hour' +%FT%H:%MZ)" > "$WD/proposals-open.md"
check "the same line cleared by its delivering link passes" 0 "$(stop "$WD")"
rm "$WD/proposals-open.md"; echo 'PROMISED o/r#1: come back with the result (holding.md)' > "$WD/hold/proposals-open.md"
printf "I'm checking each server. By %s UTC I'll come back with what works where.\n" "$(date -u -d '-1 hour' +%H:%M)" > "$WD/hold/drafts/holding.md"; touch -d '-2 hours' "$WD/hold/drafts/holding.md"
check "BLOCK: the time is in the draft the line names, in a draft folder's proposals-open.md" "2 1" "$(stop "$WD") $(grep -c 'come back with the result' "$T/err")"
touch -d '-30 minutes' "$WD/hold/drafts/holding.md"
check "a bare time of day earlier than the draft's writing falls due the next day" 0 "$(stop "$WD")"
rm -r "$WD/hold"
echo "o/r 1 comment 42 by someone" > "$WD/replies-owed.md"
tr_file "README tidied."
check "open owed line, cwd=parent of watch dir" 0 "$(stop "$T/work")"
check "open owed line, cwd=prefix sibling x-2" 0 "$(stop "$T/work/x-2/sub")"
tr_cmd() { # a Bash command the session ran, then the final text
  python3 -c 'import json,sys; print(json.dumps({"type":"user","message":{"content":"go"}})); print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":"t1","input":{"command":sys.argv[1]}}]}})); print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}))' "$1" > "$T/tr.jsonl"
}
tr_cmd "ls $WD && grep -n gate-pass notes.md"
check "a session that only mentioned the watch dir doesn't own its owed replies" 0 "$(stop "$T/work")"
tr_cmd "gate-pass $WD/drafts/r.md $WD/drafts/r.review.out"
check "BLOCK: a session that gate-passed a draft there owns them" 2 "$(stop "$T/work")"
tr_cmd "gh api graphql -f query='query(\$n:Int!){repository(owner:\"o\",name:\"r\"){issue(number:\$n){body}}}' -F n=49"
check "a GraphQL query is a read, not a post" 0 "$(stop "$T/work")"
tr_cmd "gh api repos/o/r/issues -X GET -F per_page=100"
check "an explicit GET with fields is a read" 0 "$(stop "$T/work")"
# a steward pass (gh-watch-start --round) leaves no daemon: a post still needs a live watcher, and the dir's owed replies hold its session's turn
PD="$T/passdir"; mkdir -p "$PD"; echo "$PD" >> "$HOME/.claude/gh-watch-dirs.txt"; echo 'Tier: S, because one fix' > "$PD/scope.md"  # a posting session works on a scoped task
stop_as() { python3 -c 'import json,sys; print(json.dumps({"transcript_path":sys.argv[1],"cwd":sys.argv[2],"session_id":sys.argv[3]}))' "$T/tr.jsonl" "$T" "$1" \
  | MERGEWORTHY_STOP_CHECKIN=off python3 "$R/hooks/stop-lint.py" 2>"$T/err"; echo $?; }
tr_cmd "gh issue comment 5 --repo o/r --body-file $PD/drafts/r.md"
check "BLOCK: a post with no Monitor and no pass" 2 "$(stop_as s-p)"
python3 -c 'import json,sys; print(json.dumps({"type":"user","message":{"content":"Act as the implementation sub-agent for this task."}})); print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":"t1","input":{"command":sys.argv[1]}}]}})); print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}))' "gh issue comment 5 --repo o/r --body-file $PD/drafts/r.md" > "$T/tr.jsonl"
check "a delegated child's post needs no watcher of its own: its main session watches" 0 "$(stop_as s-p)"
tr_cmd "gh issue comment 5 --repo o/r --body-file $PD/drafts/r.md"
echo s-p > "$PD/passed"
check "BLOCK: a post in the session whose pass round ran: nothing wakes it on a reply, so it says to start a watcher" "2 1" "$(stop_as s-p) $(grep -c 'gh-watch-start <your work folder>' "$T/err")"
tr_cmd "gh api repos/o/r/issues -X GET -F per_page=100"
echo "o/r 5 comment 77 by someone" > "$PD/replies-owed.md"
check "BLOCK: the pass dir's owed reply holds the turn though no daemon runs there; answered, the turn ends" "2 0" "$(stop_as s-p) $(rm "$PD/replies-owed.md"; stop_as s-p)"
rm "$PD/passed"
tr_cmd "gh issue comment 5 --repo o/r --body-file $WD/drafts/r.md"
check "BLOCK: a post with no Monitor on the watcher" 2 "$(stop "$T/work")"
# under T3 Code a live watcher whose t3-thread is the session's thread wakes it (gh-watch.py's wake_thread): no Monitor, and its owed replies are the session's
mkdir -p "$HOME/.t3/userdata"; python3 -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("create table orchestration_v2_projection_provider_threads (provider_thread_id text, thread_id text, payload_json text)")
c.execute("create table orchestration_v2_projection_subagents (subagent_id text, thread_id text, child_thread_id text)")
c.execute("""insert into orchestration_v2_projection_provider_threads values ('"'p1', 'thr-h', '{\"nativeThreadRef\":{\"nativeId\":\"s-t3\"}}'"')"""); c.commit()' "$HOME/.t3/userdata/statev2.sqlite"
mv "$WD/replies-owed.md" "$T/owed.keep"; echo 'Tier: S, because one fix' > "$WD/scope.md"; b1=$(stop_as s-t3); b1e=$(grep -c 'wakes this T3 thread itself' "$T/err"); echo thr-other > "$WD/t3-thread"; b2=$(stop_as s-t3); echo thr-h > "$WD/t3-thread"
check "under T3 Code a post passes once the session's watcher wakes its thread, not before nor for another thread; the block says no Monitor is needed" "2 1 2 0 2" "$b1 $b1e $b2 $(stop_as s-t3) $(stop_as s-other)"
printf 'Tier: S, because one fix\n\n- [ ] answer the review\n' > "$WD/scope.md"
check "that watcher counts as what wakes the session for an open scope.md box" 0 "$(stop_as s-t3)"
echo 'Tier: S, because one fix' > "$WD/scope.md"; mv "$T/owed.keep" "$WD/replies-owed.md"
check "BLOCK: that watcher's owed reply holds the session's turn, from any cwd" "2 1" "$(stop_as s-t3) $(grep -c 'still has an owed reply' "$T/err")"
rm "$WD/t3-thread"; echo s-t3 > "$WD/session"  # the session's watcher dropped its thread (gh-watch.py's wake_thread fallback)
check "BLOCK: under T3, a post whose own watcher dropped its t3-thread says that watcher stopped waking the thread, not that it wakes it" "2 1 0" \
  "$(stop_as s-t3) $(grep -c "watcher in $WD stopped waking this T3 thread" "$T/err") $(grep -c 'wakes this T3 thread itself' "$T/err")"
mv "$WD/replies-owed.md" "$T/owed.keep"; mkdir -p "$HOME/.mergeworthy"; echo "$WD tid" > "$HOME/.mergeworthy/steward"
b1=$(stop_as s-t3); b1e=$(grep -c "watcher in $WD stopped waking this T3 thread" "$T/err"); echo thr-h > "$WD/t3-thread"
check "BLOCK: the steward's watcher, though it delivers only new mergeworthy issues, needs working delivery like any: unbound, the post blocks; bound to its T3 thread, it passes" "2 1 0" "$b1 $b1e $(stop_as s-t3)"
rm "$WD/t3-thread"
rm "$HOME/.mergeworthy/steward"; mv "$T/owed.keep" "$WD/replies-owed.md"
rm "$WD/session" "$WD/scope.md" "$HOME/.t3/userdata/statev2.sqlite"
tr_cmd "mw post $WD/drafts/r.md -- gh pr comment 5 --repo o/r --body-file $WD/drafts/r.md"
check "BLOCK: a post through mw post" 2 "$(stop "$T/work")"
tr_cmd "sed -i 's/x/\`gh pr edit 5 --body-file b.md\`/' skills/a.md"
check "a gh post quoted inside another command is text, not a post" 0 "$(stop "$T/work")"
tr_cmd "$(printf "cat > a.md <<'EOF'\n- Post it: gh pr edit 5 --body-file b.md\nEOF")"
check "a gh post inside a heredoc is a file's text, not a post" 0 "$(stop "$T/work")"
kill "$SPID"; wait "$SPID" 2>/dev/null

# ---------- pre-bash-guard check_turn ----------
ctx() { printf '# Thread context: %s\n- root: %s\n- latest-human-comment: id=0 at=0\n' "$2" "$2" > "$1/thread-context.md"; }  # the record the guard asks for (its content is tested below)
tcbind() { echo "tc $(sha256sum "$(dirname "$1")/thread-context.md" | cut -d' ' -f1)" >> "$1.gate"; }  # gate-pass records the thread context it gated with
D="$T/drafts"; mkdir -p "$D"; ctx "$D" o/r#5
gate() { printf '%s\n' "$2" > "$D/$1.md"; sha256sum "$D/$1.md" | cut -d' ' -f1 > "$D/$1.md.gate"; tcbind "$D/$1.md"
         python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1]).read().replace("\r\n","\n").strip().encode()).hexdigest())' "$D/$1.md" >> "$HOME/.claude/gated-posts.txt"; }
gate a1 "Agent comment one."
gate a2 "Agent comment two."
gate new "Agent answer."
now=$(date -u +%Y-%m-%dT%H:%M:%SZ); old=$(date -u -d '-4 hours' +%Y-%m-%dT%H:%M:%SZ); hour=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)
comments() { # body1 body2 created2 [author2]
  echo '{"number":5,"comments":2}' > "$FX/repos_o_r_issues_5"
  python3 -c 'import json,sys; print(json.dumps([{"body":sys.argv[1],"created":sys.argv[3],"url":"https://example.invalid/c1","user":"nitedani"},{"body":sys.argv[2],"created":sys.argv[3],"url":"https://example.invalid/c2","user":sys.argv[4]}]))' \
    "$1" "$2" "$3" "${4:-nitedani}" > "$FX/repos_o_r_issues_5_comments_per_page_100_page_1"
}
echo nitedani > "$FX/user"
guard() { # extra args
  rm -f "$D/new.md.posted"
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":" ".join(["gh","issue","comment","5","--repo","o/r","--body-file",sys.argv[2]]+sys.argv[3:])},"cwd":sys.argv[1]}))' "$T" "$D/new.md" "$@" > "$T/in.json"
  python3 "$R/hooks/pre-bash-guard.py" < "$T/in.json" 2>"$T/err"; echo $?
}
A1="Agent comment one."; A2="Agent comment two."
comments "$A1" "/ai please also cover the edge case" "$now"
check "last comment is the user's own (same login, not gated)" 0 "$(guard)"
comments "Maintainer question" "$A2" "$now"
check "only the last comment is the agent's" 0 "$(guard)"
comments "$A1" "$A2" "$now"
date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ > "$FX/repos_o_r_pulls_5_reviews_per_page_100"
check "last two are the agent's but a review came after" 0 "$(guard)"
rm "$FX/repos_o_r_pulls_5_reviews_per_page_100"
check "--help on a comment command" 0 "$(guard --help)"
comments "$A1" "$A2" "$old"
check "last two are the agent's, last is 4 hours old (wait ping)" 0 "$(guard)"
comments "$A1" "$A2" "$hour"
check "BLOCK: last two are the agent's, last is 1 hour old" 2 "$(guard)"
comments "$A1" "$A2" "$now"
check "BLOCK: last two are the agent's gated posts, recent, no review (issue 404)" 2 "$(guard)"
comments "$A1" "$A2" "$now" maint
check "a maintainer's comment is a reply, even when its text matches a gated draft" 0 "$(guard)"
comments "$A1" "$A2" "$now"
echo nitedani > "$FX/user"
date -u -d '+1 minute' +'maint %Y-%m-%dT%H:%M:%SZ' > "$FX/repos_o_r_pulls_5_commits_per_page_100"
check "a maintainer's push after the last two comments counts as a reply" 0 "$(guard)"
date -u -d '+1 minute' +'nitedani %Y-%m-%dT%H:%M:%SZ' > "$FX/repos_o_r_pulls_5_commits_per_page_100"
check "BLOCK: your own push is not a reply" 2 "$(guard)"
rm -f "$FX/repos_o_r_pulls_5_commits_per_page_100" "$FX/user"
grep -o 'your last two comments.*' "$T/err" | sed 's#https\?://[^ )]*#<url>#'

# ---------- thread-context: the record a reply is drafted from, and the guard that requires it current ----------
BADGE='<img src=\"https://github.com/claude.png\" alt=\"Claude\">'
tc_fx() { # name json
  printf '%s' "$2" > "$FX/$1"; }
tc_fx repos_o_r_issues_41 '{"number":41,"id":1,"title":"Root","html_url":"https://example.invalid/o/r/issues/41","state":"open","updated_at":"2026-10-01T10:00:00Z","created_at":"2026-09-30T10:00:00Z","user":{"login":"maint"},"body":"Proposal. See o/r#42 and #43. Not #99."}'
tc_fx repos_o_r_issues_41_comments_per_page_100 "[
 {\"id\":101,\"user\":{\"login\":\"maint\"},\"created_at\":\"2026-10-01T09:00:00Z\",\"html_url\":\"https://example.invalid/o/r/issues/41#c101\",\"body\":\"I prefer option A, not B.\"},
 {\"id\":102,\"user\":{\"login\":\"nitedani\"},\"created_at\":\"2026-10-01T09:10:00Z\",\"html_url\":\"https://example.invalid/o/r/issues/41#c102\",\"body\":\"$BADGE\\nSounds good, I agree with the rule you proposed.\"},
 {\"id\":103,\"user\":{\"login\":\"changeset-bot\",\"type\":\"Bot\"},\"created_at\":\"2026-10-01T09:20:00Z\",\"html_url\":\"https://example.invalid/o/r/issues/41#c103\",\"body\":\"see #99\"},
 {\"id\":104,\"user\":{\"login\":\"maint\"},\"created_at\":\"2026-10-01T09:30:00Z\",\"html_url\":\"https://example.invalid/o/r/issues/41#c104\",\"body\":\"Agreed, let's go with option A.\"}]"
tc_fx repos_o_r_issues_42 '{"number":42,"id":2,"title":"Linked issue","html_url":"https://example.invalid/o/r/issues/42","state":"closed","updated_at":"2026-09-01T10:00:00Z","created_at":"2026-09-01T09:00:00Z","user":{"login":"other"},"body":"Rename it."}'
tc_fx repos_o_r_issues_42_comments_per_page_100 '[{"id":90,"user":{"login":"other"},"created_at":"2026-09-01T11:00:00Z","html_url":"https://example.invalid/o/r/issues/42#c90","body":"I disagree with the rename."}]'
tc_fx repos_o_r_issues_43 '{"number":43,"id":3,"title":"Linked PR","html_url":"https://example.invalid/o/r/pull/43","state":"open","updated_at":"2026-09-02T10:00:00Z","created_at":"2026-09-02T09:00:00Z","user":{"login":"other"},"body":"Implements it.","pull_request":{}}'
tc_fx repos_o_r_issues_43_comments_per_page_100 '[]'
tc_fx repos_o_r_pulls_43_reviews_per_page_100 '[{"id":7,"user":{"login":"other"},"submitted_at":"2026-09-02T12:00:00Z","html_url":"https://example.invalid/o/r/pull/43#r7","state":"CHANGES_REQUESTED","body":"Please keep the old name."}]'
tc_fx repos_o_r_pulls_43_comments_per_page_100 '[{"id":8,"user":{"login":"other"},"created_at":"2026-09-02T12:05:00Z","html_url":"https://example.invalid/o/r/pull/43#c8","path":"a.ts","line":3,"body":"This line stays."}]'
tc_fx repos_o_r_issues_41_timeline_per_page_100 '[{"id":55,"event":"renamed","actor":{"login":"maint"},"created_at":"2026-10-01T09:40:00Z","rename":{"from":"feat: old","to":"fix: his title"}}]'
TC="$T/ctx/thread-context.md"; mkdir -p "$T/ctx"
"$R/bin/thread-context" o/r#41 --out "$TC" >/dev/null
tcg() { grep -c "$1" "$TC"; }
check "thread-context records the root" 1 "$(tcg '^- root: o/r#41 ')"
check "it records the latest human comment, not the agent's or the bot's" 1 "$(tcg '^- latest-human-comment: id=104 at=2026-10-01T09:30:00Z')"
check "it lists the linked issue and PR, not the bot's #99" "2 0" "$(echo "$(tcg '^  - o/r#4[23] ') $(tcg 'o/r#99 ')")"
check "the ledger has the maintainer's agreement with a permalink" 1 "$(tcg '^- 2026-10-01 @maint \[agree/propose\] "Agreed, let.s go with option A." https://example.invalid/o/r/issues/41#c104$')"
check "the ledger has the linked thread's rejection" 1 "$(tcg '^- 2026-09-01 @other \[reject\] "I disagree with the rename."')"
check "the agent's own agreement is not in the ledger" 0 "$(tcg '^- .* @nitedani \[')"
check "the transcript marks the agent's post" 1 "$(tcg '@nitedani AGENT')"
check "the PR's review body and review comment are in" "1 1" "$(echo "$(tcg 'Please keep the old name') $(tcg 'This line stays')")"
check "a bot's comment is not in the transcript" 0 "$(tcg '^see #99')"
check "--verify accepts it for its thread" 0 "$("$R/bin/thread-context" --verify "$TC" --target o/r#41 2>/dev/null; echo $?)"
check "a maintainer's retitle is in the ledger and the transcript, and isn't the latest comment" "1 1" "$(echo "$(tcg '@maint \[title\] "Retitled "feat: old" to "fix: his title"."') $(tcg 'maint, retitled')")"
check "--latest" "104 2026-10-01T09:30:00Z" "$("$R/bin/thread-context" --latest o/r#41)"
tc_fx repos_o_r_issues_45 '{"number":45,"id":5,"title":"Code in a list","html_url":"https://example.invalid/o/r/issues/45","state":"open","updated_at":"2026-10-02T10:00:00Z","created_at":"2026-10-02T09:00:00Z","user":{"login":"maint"},"body":"- The log:\n  ```\n  see o/r#42\n  ```"}'
tc_fx repos_o_r_issues_45_comments_per_page_100 '[{"id":105,"user":{"login":"maint"},"created_at":"2026-10-02T09:30:00Z","html_url":"https://example.invalid/o/r/issues/45#c105","body":"- The bot said:\n  ```\n  I disagree with the rename.\n  ```"}]'
"$R/bin/thread-context" o/r#45 --out "$T/ctx/tc45.md" >/dev/null
check "a ref and a rejection inside a code block in a list item are code: not followed, not in the ledger" "0 0" "$(grep -c '^  - o/r#42 ' "$T/ctx/tc45.md") $(grep -c '\[reject\]' "$T/ctx/tc45.md")"

# the guard: a post on the thread needs thread-context.md in the draft's folder, current
TD="$T/tdrafts/o-r-41"; mkdir -p "$TD"
printf 'Agreed, option A it is.\n' > "$TD/r.md"; sha256sum "$TD/r.md" | cut -d' ' -f1 > "$TD/r.md.gate"
tcguard() { # post to #41 from $TD/r.md
  rm -f "$TD/r.md.posted"
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh issue comment 41 --repo o/r --body-file "+sys.argv[2]},"cwd":sys.argv[1]}))' "$T" "$TD/r.md" > "$T/in.json"
  python3 "$R/hooks/pre-bash-guard.py" < "$T/in.json" 2>"$T/err"; echo $?
}
check "BLOCK: a comment on the thread without thread-context.md" 2 "$(tcguard)"
grep -o 'no thread-context.md at.*' "$T/err" | sed "s#$T#<T>#g; s/ (mergeworthy.*//"
cp "$TC" "$TD/thread-context.md"
check "BLOCK: a thread-context.md made after the gate (the draft wasn't written or reviewed from it)" 2 "$(tcguard)"
sha256sum "$TD/r.md" | cut -d' ' -f1 > "$TD/r.md.gate"; tcbind "$TD/r.md"
check "a current thread-context.md lets the post through" 0 "$(tcguard)"
sed 's/^- root: o\/r#41/- root: o\/r#7/' "$TC" > "$TD/thread-context.md"
check "BLOCK: a thread-context.md of another thread" 2 "$(tcguard)"
cp "$TC" "$TD/thread-context.md"
tc_fx repos_o_r_issues_41 '{"number":41,"id":1,"title":"Root","html_url":"https://example.invalid/o/r/issues/41","state":"open","updated_at":"2026-10-02T10:00:00Z","created_at":"2026-09-30T10:00:00Z","user":{"login":"maint"},"body":"Proposal. See o/r#42 and #43. Not #99."}'
tc_fx repos_o_r_issues_41_comments_per_page_100 "$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c.append({"id":105,"user":{"login":"maint"},"created_at":"2026-10-02T09:00:00Z","html_url":"https://example.invalid/o/r/issues/41#c105","body":"Wait, I changed my mind."}); print(json.dumps(c))' "$FX/repos_o_r_issues_41_comments_per_page_100")"
check "BLOCK: the thread has a newer human comment than the recorded one" 2 "$(tcguard)"
grep -o 'records the latest comment.*' "$T/err" | sed "s#$T#<T>#g; s/ (mergeworthy.*//"
"$R/bin/thread-context" o/r#41 --out "$TD/thread-context.md" >/dev/null
check "BLOCK: a thread-context.md regenerated after the gate needs a new review" 2 "$(tcguard)"
sha256sum "$TD/r.md" | cut -d' ' -f1 > "$TD/r.md.gate"; tcbind "$TD/r.md"
check "the regenerated thread-context.md passes once gated again" 0 "$(tcguard)"
# the .posted marker: written once the post succeeded (PostToolUse), so a post another hook blocked, or that failed, can be retried
postreg() { # tool_response json: post-bash-register after `gh issue comment 41 ... --body-file $TD/r.md`
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh issue comment 41 --repo o/r --body-file "+sys.argv[2]},"cwd":sys.argv[1],"tool_response":json.loads(sys.argv[3])}))' "$T" "$TD/r.md" "$1" \
    | python3 "$R/hooks/post-bash-register.py"; [ -f "$TD/r.md.posted" ] && echo marker || echo none; }
check "a post the guard let through but that never ran (blocked by another hook) leaves no marker" none "$([ -f "$TD/r.md.posted" ] && echo marker || echo none)"
check "a failed post leaves no marker" none "$(postreg '"Error: Exit code 1\ngh: Not Found (HTTP 404)"')"
check "an interrupted post leaves no marker" none "$(postreg '{"stdout":"","stderr":"","interrupted":true}')"
check "a successful post writes the marker" marker "$(postreg '{"stdout":"https://example.invalid/c","stderr":"","interrupted":false}')"
rm "$TD/r.md.posted"
check "a post naming its draft by a variable the command set writes the marker too, as the guard reads that path" marker \
  "$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[2]},"cwd":sys.argv[1],"tool_response":{"stdout":"https://example.invalid/c"}}))' "$T" "F=$TD/r.md; gh issue comment 41 --repo o/r --body-file \"\$F\"" \
    | python3 "$R/hooks/post-bash-register.py"; [ -f "$TD/r.md.posted" ] && echo marker || echo none)"
python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh issue comment 41 --repo o/r --body-file "+sys.argv[2]},"cwd":sys.argv[1]}))' "$T" "$TD/r.md" > "$T/in.json"
check "BLOCK: the same draft posted again as new" 2 "$(python3 "$R/hooks/pre-bash-guard.py" < "$T/in.json" 2>"$T/err"; echo $?)"
grep -c 'was already posted' "$T/err"
python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh pr edit 41 --repo o/r --body-file "+sys.argv[2]},"cwd":sys.argv[1]}))' "$T" "$TD/r.md" > "$T/in.json"
check "an edit from a posted draft may repeat" 0 "$(python3 "$R/hooks/pre-bash-guard.py" < "$T/in.json" 2>/dev/null; echo $?)"
touch -d '+1 minute' "$TD/r.parent.md"
check "a parent saved after a record that holds the thread's latest comment passes" 0 "$(tcguard)"
rm "$TD/r.parent.md"
printf 'Tracking: x\n' > "$T/tdrafts/t.md"; sha256sum "$T/tdrafts/t.md" | cut -d' ' -f1 > "$T/tdrafts/t.md.gate"; echo "--kind tracker" > "$T/tdrafts/t.md.lint"
python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh issue comment 41 --repo o/r --body-file "+sys.argv[2]},"cwd":sys.argv[1]}))' "$T" "$T/tdrafts/t.md" > "$T/in.json"
check "a tracker draft needs no thread-context.md" 0 "$(python3 "$R/hooks/pre-bash-guard.py" < "$T/in.json" 2>/dev/null; echo $?)"
printf 'Tracking: x\n' > "$T/tdrafts/u.md"; sha256sum "$T/tdrafts/u.md" | cut -d' ' -f1 > "$T/tdrafts/u.md.gate"
python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh pr edit 41 --repo o/r --body-file "+sys.argv[2]},"cwd":sys.argv[1]}))' "$T" "$T/tdrafts/u.md" > "$T/in.json"
check "BLOCK: a PR body edit is covered too" 2 "$(python3 "$R/hooks/pre-bash-guard.py" < "$T/in.json" 2>/dev/null; echo $?)"

# gate-pass wants the same file beside a reply draft
GD="$T/gdrafts/x"; mkdir -p "$GD"; printf 'Agreed, option A it is.\n' > "$GD/r.md"; echo CLEAN > "$GD/r.review.out"
gp() { touch -d "${RT:-+10 minutes}" "$GD/r.review.out"; MERGEWORTHY_BADGE=off GATED_POSTS="$T/gp.txt" "$R/bin/gate-pass" "$GD/r.md" "$GD/r.review.out" --kind reply --parent none >"$T/gp.out" 2>&1; echo $?; }
check "BLOCK: gate-pass on a reply without thread-context.md" 1 "$(gp)"
grep -c 'no thread-context.md' "$T/gp.out"
cp "$TD/thread-context.md" "$GD/thread-context.md"; touch -d 2026-10-01T00:00:00Z "$GD/r.md"
check "BLOCK: gate-pass with a thread-context.md holding a human comment newer than the review" "1 1" "$(RT=2026-10-01T12:00:00Z gp) $(grep -c 'newer than the review' "$T/gp.out")"
check "gate-pass passes a draft saved before a human comment the review's record holds (a PR body gated before the thread's comments)" 0 "$(gp)"
touch -d 2026-10-03T00:00:00Z "$GD/r.md"
check "gate-pass passes with a thread-context.md made after the draft whose comments all predate it" 0 "$(gp)"
touch -d '+1 minute' "$GD/r.md"
check "gate-pass passes with thread-context.md beside the draft, written before it" 0 "$(gp)"
touch -d '+5 minutes' "$GD/r.parent.md"
check "gate-pass passes with the parent saved after a current thread-context.md" 0 "$(gp)"
cp "$GD/thread-context.md" "$T/gd-tc.md"; cp "$TC" "$GD/thread-context.md"; touch -d '+30 seconds' "$GD/r.md"; touch -d '+5 minutes' "$GD/r.parent.md"
check "BLOCK: gate-pass with the parent saved after a record the thread has outgrown" "1 1" "$(gp) $(grep -c 'records the latest comment' "$T/gp.out")"
mv "$T/gd-tc.md" "$GD/thread-context.md"; rm "$GD/r.parent.md"; touch -d '+1 minute' "$GD/r.md"
check "gate-pass records the thread context in the gate" 1 "$(grep -c '^tc ' "$GD/r.md.gate")"
printf 'The test checks that "I'"'"'ll switch it once X is released" passes.\n' > "$GD/r.md"; touch -d '+2 minutes' "$GD/r.md"
check "a quoted \"I'll\" is someone else's words, not a promise" 0 "$(gp)"
printf 'The lint says:\n\n```\nsay what is being done ('"'"'I'"'"'ll merge …'"'"')\n```\n' > "$GD/r.md"; touch -d '+150 seconds' "$GD/r.md"
check "an \"I'll\" inside a fenced code block is a tool's output, not a promise" 0 "$(gp)"
printf 'The build fails:\n\n```\n3 foo();\n  ~~~\n```\n\nI'"'"'ll fix it in a follow-up PR.\n' > "$GD/r.md"; touch -d '+160 seconds' "$GD/r.md"
check "BLOCK: a promise after a code block whose output holds a fence-like line (tsc's ~~~ underline)" "1 1" "$(gp) $(grep -c 'promises work' "$T/gp.out")"
printf -- '- Run it:\n- ```bash\n  # I'"'"'ll open a PR for it\n  ```\n' > "$GD/r.md"; touch -d '+162 seconds' "$GD/r.md"
check "an \"I'll\" inside a code block opened on a list line is not a promise" 0 "$(gp)"
printf -- '- ```bash\n\t# I'"'"'ll open a PR for it\n\t```\n' > "$GD/r.md"; touch -d '+163 seconds' "$GD/r.md"
check "an \"I'll\" in a list item's code block indented with tabs is not a promise" 0 "$(gp)"
printf 'The fix:\n\n    # I'"'"'ll open a PR for it\n\nDone.\n' > "$GD/r.md"; touch -d '+164 seconds' "$GD/r.md"
check "an \"I'll\" in an indented code block is not a promise" 0 "$(gp)"
printf -- '10. ```bash\n    echo hello\n    ```\n\nI'"'"'ll open a PR for it.\n' > "$GD/r.md"; touch -d '+165 seconds' "$GD/r.md"
check "BLOCK: a promise after a code block opened on a list line, closed at the item's content column" "1 1" "$(gp) $(grep -c 'promises work' "$T/gp.out")"
printf -- '- ```bash\n  make\n\nI'"'"'ll open a PR for it.\n' > "$GD/r.md"; touch -d '+166 seconds' "$GD/r.md"
check "BLOCK: a promise after a list item whose code block is never closed: the block ends with the item" "1 1" "$(gp) $(grep -c 'promises work' "$T/gp.out")"
printf -- '- Run it:\n  ```bash\n  make\n\nI'"'"'ll open a PR for it.\n' > "$GD/r.md"; touch -d '+167 seconds' "$GD/r.md"
check "BLOCK: a promise after a list item whose code block opens on a continuation line and is never closed" "1 1" "$(gp) $(grep -c 'promises work' "$T/gp.out")"
printf 'The lint says:\n\n~~~\nI'"'"'ll merge it once green\n~~~\n' > "$GD/r.md"; touch -d '+170 seconds' "$GD/r.md"
check "an \"I'll\" inside a ~~~ code block is not a promise either" 0 "$(gp)"
printf "I'll open a PR for it.\n" > "$GD/r.md"; touch -d '+3 minutes' "$GD/r.md"
check "BLOCK: the draft's own \"I'll\" needs a PROMISED line" "1 1" "$(gp) $(grep -c 'promises work' "$T/gp.out")"
WP="$T/wp"; mkdir -p "$WP"; echo sess1 > "$WP/session"; echo "$WP" >> "$HOME/.claude/gh-watch-dirs.txt"; echo "PROMISED o/r#1: a PR (r.md)" > "$WP/proposals-open.md"
check "a PROMISED line in the session's watch dir counts, wherever the draft lives" 0 "$(CLAUDE_CODE_SESSION_ID=sess1 gp)"

# ---------- a status post (post step 3): post-lint checks it in place of a review, and gate-pass takes `none` for it alone ----------
FUT=$(date -u -d '+1 day' +%Y-%m-%dT%H:%MZ); PAST=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%MZ)
# sl <finding> <draft> [badge]: the lines naming <finding>; with '' post-lint's exit code, so a crash isn't a pass
sl() { printf '%s\n' "$2" > "$T/st.md"; local out rc; out=$(MERGEWORTHY_BADGE="${3:-off}" python3 "$R/bin/post-lint" "$T/st.md" --kind status --parent none 2>/dev/null); rc=$?; [ -n "$1" ] || { echo "$rc"; return; }; printf '%s\n' "$out" | grep -c "$1"; }
check "status: what is being done and by when, in UTC, passes" 0 "$(sl '' "@brillout On it: I'm rating everything this PR adds or changes against your refactor skill, with one commit per refactor. The table of old ⇒ new ratings comes by $FUT.")"
check "status: a time of day (UTC, or with a date beside it), one that passed, a lowercase ISO one (stop-lint can't parse it), a relative one (hedged too), and none at all are findings" "1 1 1 1 1 1 1 1" "$(sl 'time of day' 'The table comes by 16:00.') $(sl 'time of day' "I'll merge it by 23:30 UTC on October 27th.") $(sl 'has passed' "The table comes by $PAST.") $(sl 'say by when' "The table comes by ${PAST,,}.") $(sl 'relative time' "The table comes tomorrow, the rest by $FUT.") $(sl 'relative time' "The table comes by $FUT (in about an hour).") $(sl 'relative time' "The rest comes in a few days, the table by $FUT.") $(sl 'say by when' 'On it.')"
check "status: a date, a month or a number in the prose is no time: those pass" "0 0 0" "$(sl '' "I'm reviewing the May release, the JUnit 5 suite and 3 decisions. The report comes by $FUT.") $(sl '' "I'll mark 2 items done before $FUT.") $(sl '' "I'm checking the 2026-10-27 run. The report comes by $FUT.")"
check "status: a sha, a count, a result word, a reason (because, \", since\", now that, not the time \"since\"), a table and a question each need the review" "1 1 1 1 1 1 0 1 1" "$(sl 'is a claim' "Fixed in abc1234, the rest by $FUT.") $(sl 'is a claim' "12 tests to go, done by $FUT.") $(sl 'is a claim' "It passes now, the docs come by $FUT.") $(sl 'is a claim' "I'm switching to the new parser because the old one is slow. The report comes by $FUT.") $(sl 'is a claim' "I'm rerunning the suite, since the cache was the cause. The report comes by $FUT.") $(sl 'is a claim' "I'm rerunning the suite now that the patch is in. The report comes by $FUT.") $(sl '' "I'm reading what changed since the last pass. The report comes by $FUT.") $(sl 'is a claim' "$(printf '| a | b |\n|---|---|\n| 1 | 2 |\n\nBy %s.' "$FUT")") $(sl 'question or a decision' "Should it cover X? I recommend yes, by $FUT.")"
check "status: a fenced code block, with backticks or tildes, needs the review" "1 1" "$(sl 'code block' "$(printf 'I am rerunning the suite.\n\n```\nok\n```\n\nThe report comes by %s.' "$FUT")") $(sl 'code block' "$(printf 'I am rerunning the suite.\n\n~~~\nok\n~~~\n\nThe report comes by %s.' "$FUT")")"
check "status: each sentence says what is being done or by when; any other needs the review" "1 1 0" "$(sl 'says neither' "The docs are updated. The report comes by $FUT.") $(sl 'says neither' "I checked it and the cache was the cause. The report comes by $FUT.") $(sl '' "Next, I'll rebase onto main. Then I'm rerunning the gates, and the report comes by $FUT.")"
check "status: 'I'm seeing …' or 'I'm getting …' reports a result: it needs the review" "1 1 1 0" "$(sl 'says neither' "I'm seeing the expected output. The report comes by $FUT.") $(sl 'says neither' "We are still getting the correct output. The report comes by $FUT.") $(sl 'says neither' "I'm seeing matching output. The report comes by $FUT.") $(sl '' "I'm still reviewing the patch. The report comes by $FUT.")"
check "status: a list of actions and their deadline passes, an item that is neither does not" "0 0 1" "$(sl '' "$(printf -- "- I'm reviewing the patch.\n- I'll send the report by %s." "$FUT")") $(sl '' "$(printf -- "1. I'm reviewing the patch\n2. I'll send the report by %s" "$FUT")") $(sl 'says neither' "$(printf -- "- I'm reviewing the patch\n- The docs are updated\n- I'll send the report by %s" "$FUT")")"
check "status: a time not after by or before (stop-lint's form), a link to code, a GENUINE-FORK line and over 100 words are findings" "1 1 1 1" "$(sl 'say by when' "The table comes at $FUT.") $(sl 'is a claim' "See https://github.com/o/r/commit/abc, the rest by $FUT.") $(sl 'question or a decision' "$(printf 'The rest by %s.\nGENUINE-FORK: a or b; I recommend a' "$FUT")") $(sl '> 100' "$(printf 'word %.0s' $(seq 101)) by $FUT.")"
check "status: a badge naming a reviewer is a finding" 1 "$(sl 'names only the writer' "$(printf '<img src="https://github.com/claude.png" width="20" height="20" alt="Claude"> *Opus 5.5 (low effort) wrote this; Opus 5.5 (low effort) reviewed it.*\nThe table comes by %s.' "$FUT")" on)"
GS="$T/sdrafts/x"; mkdir -p "$GS"; cp "$TD/thread-context.md" "$GS/"; printf 'The table of old ⇒ new ratings comes by %s.\n' "$FUT" > "$GS/s.md"; touch -d '+1 minute' "$GS/s.md"
sg() { MERGEWORTHY_BADGE=off GATED_POSTS="$T/gp.txt" "$R/bin/gate-pass" "$GS/s.md" none --kind "$1" --parent none >"$T/gp.out" 2>&1; echo $?; }
check "BLOCK: gate-pass without a review for anything but a status post" "1 1" "$(sg reply) $(grep -c 'only a status post' "$T/gp.out")"
check "BLOCK: a status post needs its PROMISED line" "1 1" "$(sg status) $(grep -c 'promises work' "$T/gp.out")"
printf 'The rebase lands by %s, and then I'"'"'ll merge.\n' "$FUT" > "$GS/s.md"; touch -d '+2 minutes' "$GS/s.md"
check "BLOCK: a status post needs its PROMISED line even when it says it will merge" "1 1" "$(sg status) $(grep -c 'promises work' "$T/gp.out")"
printf 'The table of old ⇒ new ratings comes by %s.\n' "$FUT" > "$GS/s.md"; touch -d '+3 minutes' "$GS/s.md"
echo "PROMISED o/r#1: the ratings table (s.md)" > "$T/sdrafts/proposals-open.md"
check "gate-pass gates a status post with no review once its PROMISED line is there" "0 yes" "$(sg status) $([ "$(sha256sum "$GS/s.md" | cut -d' ' -f1)" = "$(head -1 "$GS/s.md.gate")" ] && echo yes)"

# ---------- post-bash-register: only a real gh post registers, and only the thread it posted to ----------
sleep 600 & SPID=$!
WD="$T/reg"; mkdir -p "$WD"; echo "$SPID" > "$WD/gh-watch.pid"; echo sess-r > "$WD/session"
echo "$WD" > "$HOME/.claude/gh-watch-dirs.txt"
U5='https://github.com/o/r/issues/5#issuecomment-1'
register() { # command stdout -> the watch dir's threads.txt, space-joined
  rm -f "$WD/threads.txt"
  python3 -c 'import json,sys; print(json.dumps({"session_id":"sess-r","tool_input":{"command":sys.argv[1]},"tool_response":{"stdout":sys.argv[2]}}))' "$1" "$2" \
    | python3 "$R/hooks/post-bash-register.py"
  [ -f "$WD/threads.txt" ] && paste -sd' ' "$WD/threads.txt" || echo none
}
printf 'The posted body, with ![shot](https://user-images.example/1.png)' > "$FX/repos_o_r_issues_comments_77"
register "gh issue comment 5 --repo o/r --body-file /x/d.md --attach /x/1.png" 'https://github.com/o/r/issues/5#issuecomment-77' >/dev/null
want=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1]).read().strip().encode()).hexdigest())' "$FX/repos_o_r_issues_comments_77")
check "the body actually posted (after --attach) is registered as the agent's" 1 "$(grep -c "$want" "$HOME/.claude/gated-posts.txt")"
check "printf that mentions a comment command, URL in output" none \
  "$(register "printf '%s' 'gh issue comment 5 --repo o/r' > in.json; python3 hook.py < in.json" "$U5")"
check "grep for a comment command, URL in output" none \
  "$(register "grep -rn 'gh issue comment 5 --repo o/r' ." "x.md: $U5")"
check "real gh issue comment" "o/r 5" \
  "$(register "gh issue comment 5 --repo o/r --body-file x" "$U5")"
check "real gh issue comment, another thread's URL also printed" "o/r 5" \
  "$(register "gh issue comment 5 --repo o/r --body-file x && cat log" "$U5 https://github.com/o/r/issues/6 https://github.com/p/q/pull/5")"
check "real gh pr create, number not named" "o/r 7" \
  "$(register "gh pr create --repo o/r --fill" "https://github.com/o/r/pull/7")"
check "gh api POST comment" "o/r 5" \
  "$(register "gh api repos/o/r/issues/5/comments -F body=@x.md" "{\"html_url\": \"$U5\"}")"
check "gh api read (-X GET with fields)" none \
  "$(register "gh api -X GET repos/o/r/issues -f state=open" "$U5")"
check "gh --help on a comment command" none \
  "$(register "gh issue comment 5 --repo o/r --help" "$U5")"
# Two live dirs cover o/r: an older one whose session is gone, then the posting session's (gh-watch-start recorded it)
D1="$T/reg-old"; D2="$T/reg-own"; mkdir -p "$D1" "$D2"
for d in "$D1" "$D2"; do echo "$SPID" > "$d/gh-watch.pid"; echo o/r > "$d/repos.txt"; done
echo sess-2 > "$D2/session"; printf '%s\n' "$D1" "$D2" > "$HOME/.claude/gh-watch-dirs.txt"
python3 -c 'import json; print(json.dumps({"session_id":"sess-2","tool_input":{"command":"gh pr create --repo o/r --fill"},"tool_response":{"stdout":"https://github.com/o/r/pull/8"}}))' \
  | python3 "$R/hooks/post-bash-register.py"
check "a new PR joins the posting session's dir, not an older dir covering the repo" "o/r 8|none" \
  "$(cat "$D2/threads.txt" 2>/dev/null)|$(cat "$D1/threads.txt" 2>/dev/null || echo none)"
check "the thread replaces that dir's bare repo line" "|o/r" "$(cat "$D2/repos.txt")|$(cat "$D1/repos.txt")"
# a dir a steward pass read today (its passed file names the session) has no daemon to wake anyone: the session's live dir gets the thread
D3="$T/reg-pass"; D4="$T/reg-live"; mkdir -p "$D3" "$D4"; echo o/r > "$D3/repos.txt"; echo 'o/r 5' > "$D3/threads.txt"; echo sess-3 > "$D3/passed"
echo "$SPID" > "$D4/gh-watch.pid"; echo sess-3 > "$D4/session"; printf '%s\n' "$D3" "$D4" > "$HOME/.claude/gh-watch-dirs.txt"
preg() { python3 -c 'import json,sys; print(json.dumps({"session_id":"sess-3","tool_input":{"command":sys.argv[1]},"tool_response":{"stdout":sys.argv[2]}}))' "$1" "$2" \
  | python3 "$R/hooks/post-bash-register.py"; cat "$D4/threads.txt" 2>/dev/null || echo none; rm -f "$D4/threads.txt"; }
check "a new PR, and a comment on a thread only the passed dir lists, join the session's live dir, not the dir its steward pass read" "o/r 9|o/r 5|o/r 5" \
  "$(preg 'gh pr create --repo o/r --fill' https://github.com/o/r/pull/9)|$(preg 'gh issue comment 5 --repo o/r --body-file x' https://github.com/o/r/issues/5#issuecomment-1)|$(cat "$D3/threads.txt")"
# the steward's live dir may list a new mergeworthy issue first: it wakes no one on its closing, so the opener's dir still gets it
SL="$T/reg-steward"; mkdir -p "$SL" "$HOME/.mergeworthy"; echo "$SPID" > "$SL/gh-watch.pid"; echo 'nitedani/mergeworthy 12' > "$SL/threads.txt"; echo "$SL tid" > "$HOME/.mergeworthy/steward"
printf '%s\n' "$SL" "$D4" > "$HOME/.claude/gh-watch-dirs.txt"
check "an issue the session opens on mergeworthy joins its own dir though the steward's lists it" "nitedani/mergeworthy 12" \
  "$(preg 'gh issue create --repo nitedani/mergeworthy --title t --body-file x' https://github.com/nitedani/mergeworthy/issues/12)"
rm "$HOME/.mergeworthy/steward"
kill "$SPID"; wait "$SPID" 2>/dev/null

# ---------- finality trigger: the third proposal on a thread needs a thread map ----------
AR="$T/art"; mkdir -p "$AR/drafts/r1" "$AR/maps"; ctx "$AR/drafts/r1" o/r#9
rm -f "$HOME/.claude/proposal-rounds.txt"; echo '{"number":9,"comments":0}' > "$FX/repos_o_r_issues_9"
prop() { # n: a gated proposal draft, as gate-pass leaves it
  printf 'Proposal %s\n' "$1" > "$AR/drafts/r1/p$1.md"; sha256sum "$AR/drafts/r1/p$1.md" | cut -d' ' -f1 > "$AR/drafts/r1/p$1.md.gate"; tcbind "$AR/drafts/r1/p$1.md"
  echo "--kind proposal --repo o/r --parent none" > "$AR/drafts/r1/p$1.md.lint"
}
pguard() { # n -> exit code of the pre-bash-guard on posting proposal n to o/r#9
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh issue comment 9 --repo o/r --body-file "+sys.argv[1]},"cwd":sys.argv[2]}))' "$AR/drafts/r1/p$1.md" "$T" \
    | python3 "$R/hooks/pre-bash-guard.py" 2>"$T/err"; echo $?
}
pposted() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh issue comment 9 --repo o/r --body-file "+sys.argv[1]},"tool_response":{"stdout":"https://example.invalid/x"}}))' "$AR/drafts/r1/p$1.md" \
    | python3 "$R/hooks/post-bash-register.py"; }
for n in 1 2 3; do prop $n; done
check "the 1st proposal passes" 0 "$(pguard 1)"; pposted 1
check "the 2nd proposal passes" 0 "$(pguard 2)"; pposted 2
check "BLOCK: the 3rd proposal without a thread map" 2 "$(pguard 3)"
grep -o 'maps/[^ ]*' "$T/err" | head -1
check "the finality block points to the WIP comment, not a restated design" 1 "$(grep -c "update the thread's WIP comment" "$T/err")"
touch -d '+1 minute' "$AR/maps/o-r-9.md"
check "the 3rd proposal with a fresh map passes" 0 "$(pguard 3)"
touch -d '-1 hour' "$AR/maps/o-r-9.md"
check "BLOCK: a map older than the last proposal" 2 "$(pguard 3)"
# ---------- post-lint: the badge is icons, then a line break ----------
blint() { printf '%s' "$1" > "$T/badge.md"; python3 "$R/bin/post-lint" "$T/badge.md" --parent none 2>&1 | grep -c 'badge'; }
check "icons, the italic model line, then a line break pass" 0 "$(blint $'<img src="https://github.com/claude.png" width="20" height="20" alt="Claude"> <img src="https://github.com/openai.png" width="20" height="20" alt="Codex"> *Opus 5.5 (medium effort) wrote this; GPT-6.1-Sol (high effort) reviewed it.*\nFixed in abc1234.\n')"
check "BLOCK: icons without the model line" 1 "$(blint $'<img src="https://github.com/claude.png" width="20" height="20" alt="Claude">\nFixed in abc1234.\n')"
check "a **Claude:** label is flagged" 1 "$(blint $'<img src="https://github.com/claude.png" width="20" height="20" alt="Claude"> **Claude:** Fixed in abc1234.\n')"
check "no badge is flagged" 1 "$(blint $'Fixed in abc1234.\n')"
elint() { printf '%s %s\nFixed in abc1234.\n' '<img src="https://github.com/claude.png" width="20" height="20" alt="Claude">' "$1" > "$T/effort.md"; python3 "$R/bin/post-lint" "$T/effort.md" --parent none 2>&1 | grep -c 'without effort'; }
check "BLOCK: a model line naming a model without its effort" 1 "$(elint '*Opus 5.5 wrote this.*')"
check "BLOCK: one model of two without its effort" 1 "$(elint '*Opus 5.5 (high effort) wrote this; GPT-6.1-Sol (Codex) reviewed it.*')"
check "BLOCK: a model line with no versioned model and no effort" 1 "$(elint '*Claude wrote this.*')"
check "the effort right after each model passes, every level" 0 "$(elint '*Opus 5.5 (low effort) wrote this; Haiku 5.5 (medium effort) tested it; Opus 5.5 (xhigh effort), Opus 5.5 (max effort) and Opus 5.5 (ultra effort) reviewed it.*')"
check "the effort inside the model's parenthesis passes" 0 "$(elint '*Opus 5.5 (high effort) wrote this; GPT-6.1-Sol (Codex, high effort) reviewed it.*')"
check "a link to the WIP comment isn't read as a model" 0 "$(elint '*Opus 5.5 (high effort) wrote this. [WIP](https://github.com/vikejs/vike/issues/3407#issuecomment-6100167145)*')"
# ---------- post-lint: a reply doesn't defer a quick win ----------
qlint() { printf '%s' "$1" > "$T/quick.md"; python3 "$R/bin/post-lint" "$T/quick.md" --kind reply --parent none 2>&1 | grep -c 'defers work'; }
check "BLOCK: I'll do the fix after it" 1 "$(qlint $'Neither blocks Vike. So I\'ll do the Universal Middleware fix after it.\n')"
check "BLOCK: I'll send it later" 1 "$(qlint $'I\'ll send the PR later.\n')"
printf 'Why not removing the stub?\n' > "$T/sp.parent.md"; printf 'Done in abc1234: the stub is gone, and the tests run against real Vike.\n' > "$T/sp.md"
python3 -c 'print("Done in abc1234. " + "The tests now start the dev server and check each case on its own. " * 8)' > "$T/sl.md"; cp "$T/sp.parent.md" "$T/sl.parent.md"
check "a short answer to a one-line question passes; a long one is flagged, naming the cap" "0 1" "$(MERGEWORTHY_BADGE=off python3 "$R/bin/post-lint" "$T/sp.md" --kind reply >/dev/null 2>&1; echo $?) $(MERGEWORTHY_BADGE=off python3 "$R/bin/post-lint" "$T/sl.md" --kind reply 2>&1 | grep -c 'answering a 5-word comment (cap 80)')"
check "post-lint prints a draft's word count and cap for the post review, for any kind" "1 1" "$(MERGEWORTHY_BADGE=off python3 "$R/bin/post-lint" "$T/sp.md" --kind reply 2>&1 >/dev/null | grep -c '^length: [0-9]* words, cap 80$') $(MERGEWORTHY_BADGE=off python3 "$R/bin/post-lint" "$T/sp.md" --kind inline --parent none 2>&1 >/dev/null | grep -c '^length: [0-9]* words, ')"
printf 'In the HTML it writes a meta tag into the stream; after a client navigation, its error boundary calls `navigate()`.\n' > "$T/semi.md"; printf 'In the HTML it writes a meta tag into the stream. After a client navigation, its error boundary calls `a; b`.\n' > "$T/semi2.md"
check "post-lint flags a semicolon joining two steps in prose; one inside code passes" "1 0" "$(MERGEWORTHY_BADGE=off python3 "$R/bin/post-lint" "$T/semi.md" --kind reply --parent none 2>/dev/null | grep -c 'semicolon joins') $(MERGEWORTHY_BADGE=off python3 "$R/bin/post-lint" "$T/semi2.md" --kind reply --parent none 2>/dev/null | grep -c 'semicolon joins')"
printf "Nothing's blocking you, correct? So let's postpone this.\n" > "$T/ack.parent.md"; printf '@brillout Correct, nothing is blocking me, so postponing is good.\n' > "$T/ack.md"; printf '@brillout One thing changed since: the fix needs your field after all, because the meta reads it.\n' > "$T/ack2.md"; cp "$T/ack.parent.md" "$T/ack2.parent.md"
check "post-lint: agreeing with a short comment is a 👍, not a reply; news for them passes" "1 0" "$(MERGEWORTHY_BADGE=off python3 "$R/bin/post-lint" "$T/ack.md" --kind reply 2>/dev/null | grep -c 'only agrees') $(MERGEWORTHY_BADGE=off python3 "$R/bin/post-lint" "$T/ack2.md" --kind reply 2>/dev/null | grep -c 'only agrees')"
check "naming what it waits on passes" 0 "$(qlint $'I\'ll switch the adapters once vikejs/vike#3594 is released.\n')"

# ---------- gate-pass: a reply in a repo whose maintainers asked to see mergeworthy's changes links them ----------
S="$T/mwsrc"; git init -q "$S"; for m in one two three; do git -C "$S" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$m"; done
mkdir -p "$HOME/.mergeworthy/harness-shown"; h1=$(git -C "$S" rev-parse --short=7 HEAD~2); h3=$(git -C "$S" rev-parse --short=7 HEAD); echo "$h1" > "$HOME/.mergeworthy/harness-shown/acme"
printf 'Fixed the bug.\n' > "$T/hs.md"
check "post-lint doesn't ask a reply to list the commits" 0 "$(MERGEWORTHY_BADGE=off MERGEWORTHY_SRC="$S" python3 "$R/bin/post-lint" "$T/hs.md" --kind reply --repo acme/x --parent none >/dev/null 2>&1; echo $?)"
hg() { printf 'Agreed, option A it is.\n' > "$GD/r.md"; touch -d '+1 minute' "$GD/r.md"; touch -d '+10 minutes' "$GD/r.review.out"; MERGEWORTHY_SRC="$S" MERGEWORTHY_BADGE=off GATED_POSTS="$T/gp.txt" "$R/bin/gate-pass" "$GD/r.md" "$GD/r.review.out" --kind "${2:-reply}" --repo "$1" --parent none >"$T/gp.out" 2>&1; echo $?; }
check "gate-pass of an inline comment adds no line and records nothing" "0 0 $h1" "$(hg acme/x inline) $(grep -c 'Harness changes' "$GD/r.md") $(cat "$HOME/.mergeworthy/harness-shown/acme")"
check "gate-pass appends the compare link after the review, gates the draft with it, and records the installed commit" "0 1 yes $h3" "$(hg acme/x) $(grep -cxF "Harness changes since my last note: <https://github.com/nitedani/mergeworthy/compare/$h1...$h3>" "$GD/r.md") $([ "$(sha256sum "$GD/r.md" | cut -d' ' -f1)" = "$(head -1 "$GD/r.md.gate")" ] && echo yes) $(cat "$HOME/.mergeworthy/harness-shown/acme")"
check "gating that draft again passes post-lint with the line, and adds none" "0 1" "$(MERGEWORTHY_SRC="$S" MERGEWORTHY_BADGE=off GATED_POSTS="$T/gp.txt" "$R/bin/gate-pass" "$GD/r.md" "$GD/r.review.out" --kind reply --repo acme/x --parent none >"$T/gp.out" 2>&1; echo $?) $(grep -c 'Harness changes' "$GD/r.md")"
echo "$h1" > "$HOME/.mergeworthy/harness-shown/acme"  # a gate-pass that appended the line, then failed before recording it
check "a draft that already has the line gets no second one" "0 1" "$(MERGEWORTHY_SRC="$S" MERGEWORTHY_BADGE=off GATED_POSTS="$T/gp.txt" "$R/bin/gate-pass" "$GD/r.md" "$GD/r.review.out" --kind reply --repo acme/x --parent none >/dev/null 2>&1; echo $?) $(grep -c '^Harness changes since my last note: ' "$GD/r.md")"
check "the next reply, nothing new since, gets no line; another owner's repo none" "0 0 0 0" "$(hg acme/x) $(grep -c 'Harness changes' "$GD/r.md") $(hg other/x) $(grep -c 'Harness changes' "$GD/r.md")"

check "a badge followed on its line by an italic model line passes, model names included" 0 "$(printf '%s\n\nFixed the bug.\n' '<img src="https://github.com/claude.png" width="20" height="20" alt="Claude"><img src="https://github.com/openai.png" width="20" height="20" alt="Codex"> *Opus 5.5 (medium effort) wrote this; a second Opus 5.5 (high effort) reviewed it; GPT-6.1-Sol (Codex, high effort) reviewed it.*' > "$T/ml.md"; MERGEWORTHY_BADGE=on python3 "$R/bin/post-lint" "$T/ml.md" --kind reply --parent none >/dev/null 2>&1; echo $?)"
check "the writing skill's badge, a WIP link inside the italics, passes" 0 "$(sed -n 's/^  \(<img src=.*\)$/\1/p' "$R/skills/writing/SKILL.md" > "$T/wb.md"; printf '\nFixed the bug.\n' >> "$T/wb.md"; python3 "$R/bin/post-lint" "$T/wb.md" --parent none 2>&1 | grep -c 'badge')"
# ---------- post-lint: a limitation names what imposes it (core 1.1.11) ----------
llint() { printf '| Note | Kind | Blocks merge | Next |\n|---|---|---|---|\n| %s | limitation | no | nothing |\n' "$1" > "$T/lim.md"; python3 "$R/bin/post-lint" "$T/lim.md" --kind pr --parent none 2>&1 | grep -c 'names nothing that imposes it'; }
check "a limitation our own design could create is flagged" 1 "$(llint 'Joins past 100 at once fail with a contention error')"
check "a limitation imposed by an outside system passes" 0 "$(llint 'Receipts omit receivers, imposed by Redis Cluster: PUBLISH counts one node')"
# ---------- post-lint: a decision is a block with code and lettered options, never a table row (writing) ----------
dtlint() { printf '| Note | Kind | Blocks merge | Next |\n|---|---|---|---|\n| Bump srvx minor or patch | %s | no | nothing |\n' "$2" > "$T/dt.md"; python3 "$R/bin/post-lint" "$T/dt.md" --kind "$1" --parent none 2>&1 | grep -c 'decision as a table row'; }
for k in pr proposal reply; do check "a decision-needed row in a $k is flagged" 1 "$(dtlint $k 'decision needed')"; done
check "a not-a-regression row passes" 0 "$(dtlint pr 'not a regression')"
bal() { printf '%b' "$1" > "$T/ba.md"; python3 "$R/bin/post-lint" "$T/ba.md" --kind pr --parent none 2>&1 | grep -c 'not in a before/after pair'; }
check "a PR body's screenshot outside a table, or in a table with no before/after columns, is flagged; the badge isn't media; videos pair under Before/After labels" "1 1 0 0 0 1" "$(bal 'The picker works.\n\n![after](a.png)\n') $(bal '| What | Shot |\n|---|---|\n| picker | ![](a.png) |\n') $(bal '| What | Before (main) | After (this PR) |\n|---|---|---|\n| picker | ![](b.png) | ![](a.png) |\n') $(bal '<img src="https://github.com/claude.png" width="20"> *Opus wrote this.*\n\nFixes the picker.\n') $(bal '**Before (main)**\n\n![](b.mp4)\n\n**After (this PR)**\n\n![](a.mp4)\n') $(bal 'The flow:\n\n![](a.mp4)\n')"
dblint() { printf '%s' "$1" > "$T/db.md"; python3 "$R/bin/post-lint" "$T/db.md" --kind pr --parent none 2>&1 | grep -c 'decision block'; }
check "a decision block in words only is flagged" 1 "$(dblint $'### Decision: who runs after a 401\n\nEither every middleware runs, or only post-handler ones. I picked the second because six servers do it.\n')"
check "a decision block with code but no lettered options is flagged" 1 "$(dblint $'### Decision: who runs after a 401\n\n```js\napply(app, [auth, log])\n```\n\nI picked skipping log because six servers do it.\n')"
check "options before the code are flagged" 1 "$(dblint $'### Decision: who runs after a 401\n\n(a) log runs\n(b) log is skipped\n\n```js\napply(app, [auth, log])\n```\n\nI picked (b) because six servers do it.\n')"
check "a decision block without a pick is flagged" 1 "$(dblint $'### Decision: who runs after a 401\n\n```js\napply(app, [auth, log])\n```\n\n(a) `log` runs\n(b) `log` is skipped\n')"
check "code, then (a) (b), then a pick passes" 0 "$(dblint $'### Decision: who runs after a 401\n\n```sh\n# auth answers 401\ncurl localhost:3000/\n```\n\n```js\napply(app, [auth, log])\n```\n\n- (a) `log` runs: `logRequest ran`\n- (b) `log` is skipped: nothing logged\n\nI picked (b) because six of the eight servers already skip it.\n\n### What you should see\n\nNo code here.\n')"
# ---------- post-lint: each list item is its own sentence ----------
B=$'<img src="https://github.com/claude.png" width="20" height="20" alt="Claude">\n'
loclint() { printf '%s\n' "$1" > "$T/loc.md"; python3 "$R/bin/post-lint" "$T/loc.md" --parent none 2>&1 | grep -c 'code location without a link'; }
check "a bare file:line, a bare line number, a linked one, one in a code block" "1 1 0 0" "$(loclint 'It breaks in `src/adapter/utils.ts:160`.') $(loclint 'Elysia copies them at line 160.') $(loclint 'Elysia copies them ([line 160](https://github.com/o/r/blob/abc1234/src/u.ts#L160)).') $(loclint $'```\nat src/u.ts:160\n```')"
check "a line number inside inline code quotes a message, not a location" 0 "$(loclint 'The hook fails with `Expecting value: line 1 column 1` on every call.')"
phlint() { printf '%s\n' "$1" > "$T/ph.md"; python3 "$R/bin/post-lint" "$T/ph.md" --parent none 2>&1 | grep -c '^placeholder'; }
check "an ALLCAPS placeholder left in a draft is flagged, a name in inline code is not" "2 0" "$(phlint $'Posted at POST_TIME.\n\nGATES_LINE') $(phlint 'The `MERGEWORTHY_BADGE` setting stays.')"
lint() { python3 "$R/bin/post-lint" "$1" --kind issue --parent none 2>&1 | grep -c 'word sentence'; }
items=$(for i in 1 2 3 4 5 6 7; do echo "  - item number $i with a few short words;"; done)
printf '%s A list of short items follows here:\n%s\n' "$B" "$items" > "$T/list.md"
check "a list of short items: no long sentence" 0 "$(lint "$T/list.md")"
printf '%s A list follows:\n- %s\n' "$B" "$(printf 'word %.0s' $(seq 45))" > "$T/long.md"
check "one list item over 40 words is flagged" 1 "$(lint "$T/long.md")"
printf '%s The spec now warns for W2 and W5.\n' "$B" > "$T/lab.md"
check "an internal label is flagged" 2 "$(python3 "$R/bin/post-lint" "$T/lab.md" --kind issue --parent none 2>&1 | grep -c 'internal label')"
printf '%s The build is uploaded to S3 and served from Cloudflare R2 on my M2 Mac.\n' "$B" > "$T/lab2.md"
check "product names like S3, R2 and M2 are not labels" 0 "$(python3 "$R/bin/post-lint" "$T/lab2.md" --kind issue --parent none 2>&1 | grep -c 'internal label')"
printf '%s Two answers follow.\n\n- **Fetch pipeline:** not needed.\n- **The option:** it stays private, as you asked, under its current name.\n' "$B" > "$T/frag.md"
check "a bold label with a fragment is flagged, a full sentence is not" 1 "$(python3 "$R/bin/post-lint" "$T/frag.md" --kind issue --parent none 2>&1 | grep -c 'bold label with a fragment')"
printf '%s Here is the PR.\n\n**Problem.** `apply()` runs one list differently per server.\n\n**Fix:** it now runs the same.\n\n**1.** The template numbered evidence item stays fine.\n\n**A fully bold sentence that the reader should not miss stays fine.**\n' "$B" > "$T/plab.md"
check "a paragraph opening with a bold label is flagged" 2 "$(python3 "$R/bin/post-lint" "$T/plab.md" --kind pr --parent none 2>&1 | grep -c 'opening with a bold label')"
mkdir -p "$T/cx"; printf '%s Fixed in abc1234.\n' "$B" > "$T/cx/reply.md"; printf 'model: gpt-x\nCLEAN\n' > "$T/cx/review.log"
check "a post Codex reviewed needs the Codex icon" 1 "$(python3 "$R/bin/post-lint" "$T/cx/reply.md" --parent none 2>&1 | grep -c 'badge without Codex')"
printf '<img src="https://github.com/claude.png" width="20" height="20" alt="Claude"><img src="https://github.com/openai.png" width="20" height="20" alt="Codex">\n\nFixed in abc1234.\n' > "$T/cx/reply.md"
check "with the Codex icon it passes" 0 "$(python3 "$R/bin/post-lint" "$T/cx/reply.md" --parent none 2>&1 | grep -c 'badge without Codex')"
printf 'Refactor this PR. Print the lists again with old rating => new rating.\n' > "$T/rp.parent.md"
printf '%s Done, the lists are below.\n\n<details>\n<summary>Lists</summary>\n\nS1 and S2 were rated in the refactor pass. %s\n</details>\n' "$B" "$(printf 'word %.0s' $(seq 400))" > "$T/rp.md"
check "lists a maintainer asked for, in <details>, are not linted or counted" 0 "$(python3 "$R/bin/post-lint" "$T/rp.md" --kind pr --parent "$T/rp.parent.md" 2>&1 | grep -c 'internal label\|words >\|process in the thread')"
printf 'Please give 100 questions here with A/B/C choices.\n' > "$T/q.parent.md"; { echo "One plan line."; echo "<details><summary>Q</summary>"; echo; for n in $(seq 1 300); do echo "- [ ] A: option number $n of a long questionnaire"; done; echo; echo "</details>"; } > "$T/q.md"
check "a questionnaire the reader asked for, in <details>, is not counted; unasked it is" "0 1" "$(python3 "$R/bin/post-lint" "$T/q.md" --kind proposal --parent "$T/q.parent.md" 2>&1 | grep -c 'words >') $(python3 "$R/bin/post-lint" "$T/q.md" --kind proposal --parent none 2>&1 | grep -c 'words >')"
{ echo "One plan line."; for n in $(seq 1 100); do echo "$n. **Question number $n of a long questionnaire?**"; for x in A B C; do echo "     - [ ] $x: option $x of question $n in the list"; done; done; } > "$T/q2.md"
check "the same questionnaire open (no <details>, which GitHub closes on every tick) is not counted either" 0 "$(python3 "$R/bin/post-lint" "$T/q2.md" --kind proposal --parent "$T/q.parent.md" 2>&1 | grep -c 'words >')"
check "the same lists nobody asked for are" 4 "$(python3 "$R/bin/post-lint" "$T/rp.md" --kind pr --parent none 2>&1 | grep -c 'internal label\|words >\|process in the thread')"
printf 'The code came from Sonnet subagents, and Codex (gpt-6.1-sol) reviewed every post.\n' > "$T/pm.md"
printf 'What AI model did you use? Explain the agent orchestration.\n' > "$T/pm.parent.md"
check "a maintainer who asks about models and agents gets them named" 0 "$(python3 "$R/bin/post-lint" "$T/pm.md" --kind reply --parent "$T/pm.parent.md" 2>&1 | grep -c 'process in the thread')"
printf 'Can you fix the typo?\n' > "$T/pm2.parent.md"
check "the same reply to an unrelated comment is flagged" 3 "$(python3 "$R/bin/post-lint" "$T/pm.md" --kind reply --parent "$T/pm2.parent.md" 2>&1 | grep -c 'process in the thread')"
printf 'Why is the review effort different every time?\n' > "$T/pm3.parent.md"
check "a question about effort gets models named; the methodology's own repo always does" "0 0" "$(python3 "$R/bin/post-lint" "$T/pm.md" --kind reply --parent "$T/pm3.parent.md" 2>&1 | grep -c 'process in the thread') $(python3 "$R/bin/post-lint" "$T/pm.md" --kind reply --repo nitedani/mergeworthy --parent "$T/pm2.parent.md" 2>&1 | grep -c 'process in the thread')"
printf 'Apply https://example.invalid/refactor/SKILL.md to this PR.\n' > "$T/rt.parent.md"
printf 'Done in abc1234 and def5678. I rated every file and function. The summary is below.\n\n| Item | Old ⇒ new | Commit |\n|---|---|---|\n| load() | 7/10 ⇒ 9/10 | abc1234 |\n| /cloudflare | 6 ⇒ 9 | def5678 |\n\nThe whole diff is at https://example.invalid/compare/a...b.\n' > "$T/rt.md"
check "an unasked old ⇒ new rating table in a Done reply passes, its /10 and 'rated every' with it" 0 "$(MERGEWORTHY_BADGE=off python3 "$R/bin/post-lint" "$T/rt.md" --kind reply --parent "$T/rt.parent.md" >/dev/null 2>&1; echo $?)"
check "without the table, the same words are process, and the fix text keeps a rating table" "1 1" "$(sed -i '/^|/d' "$T/rt.md"; python3 "$R/bin/post-lint" "$T/rt.md" --kind reply --parent "$T/rt.parent.md" 2>&1 | grep -c 'process in the thread') $(python3 "$R/bin/post-lint" "$T/rt.md" --kind reply --parent "$T/rt.parent.md" 2>&1 | grep -c 'put the ratings in an old ⇒ new table in this post')"
mkdir -p "$T/rr"; cp "$(dirname "$0")/fixtures/rating-reply.md" "$(dirname "$0")/fixtures/rating-reply.parent.md" "$T/rr/"  # an earlier draft of vikejs/vike#3609's refactor result: a summary table and three collapsed rating tables
check "the #3609 result draft to 'Apply <skill>' passes, no length or rating finding: each exempt rated cell is within 45 words, and the rest fits the cap" 0 "$(MERGEWORTHY_BADGE=on python3 "$R/bin/post-lint" "$T/rr/rating-reply.md" --kind reply --repo vikejs/vike 2>/dev/null | grep -c 'words\|/10\|rated')"
cp "$(dirname "$0")/fixtures/rating-body.md" "$T/rr/"  # #3609's PR body with its three rating tables under their own titles, Why cells past 15 words
check "the #3609 PR body with its rating tables under their own titles passes the budget: each exempt rated cell is within 45 words" 0 "$(MERGEWORTHY_BADGE=on python3 "$R/bin/post-lint" "$T/rr/rating-body.md" --kind pr --repo vikejs/vike 2>&1 | grep -c 'words >')"
{ echo "The page fails to load on Cloudflare."; echo; for n in $(seq 1 30); do echo "Step $n of the fix keeps the install line."; done; printf '\n<details>\n<summary>Review</summary>\n\n| Item | Old ⇒ new | Commit |\n|---|---|---|\n| /cloudflare | 6 ⇒ 9 | 6a1a1f5d8d |\n\nA quality pass rated every changed file and docs section; it added the install line on /cloudflare and left nothing worth changing.\n</details>\n'; } > "$T/rv.md"
check "a PR body over budget by a pass block titled 'Review' names the titles post-lint exempts; titled 'Refactor pass' it passes" "1 0" "$(python3 "$R/bin/post-lint" "$T/rv.md" --kind pr 2>&1 | grep -c "'Review' block's words count toward 300: .*Approach, Loop A, Loop B, Refactor pass, Fresh read, Gates") $(sed -i 's/<summary>Review/<summary>Refactor pass/' "$T/rv.md"; python3 "$R/bin/post-lint" "$T/rv.md" --kind pr 2>&1 | grep -c "words >\|block's words")"
printf 'Can you look at my five commits?\n' > "$T/cr.parent.md"; for n in $(seq 1 32); do echo "Commit number $n keeps the install line in the page."; done > "$T/cr0.md"
{ head -12 "$T/cr0.md"; printf '\n| Commit | What it does, and the idea behind it | Rating |\n|---|---|---|\n'; for n in 1 2 3 4 5; do echo "| abc12${n}0 | Moves the wrapper comment into the source so the generated file stays short and readable for users who open it, and the reason for the fallback lives next to the code | 9/10 (one case untested) |"; done; } > "$T/cr.md"
check "a reply's commit-review table (reply §Maintainer commits) of short rated rows leaves the count: 120 words of prose with it pass, 320 without it fail" "0 1" "$(MERGEWORTHY_BADGE=off python3 "$R/bin/post-lint" "$T/cr.md" --kind reply --parent "$T/cr.parent.md" >/dev/null 2>&1; echo $?) $(python3 "$R/bin/post-lint" "$T/cr0.md" --kind reply --parent "$T/cr.parent.md" 2>&1 | grep -c 'words > 300 for a reply')"
# only rated rows (and their header) leave the count, and each lifts the short-comment cap by 20 words: prose below a rated row, an unrated review table and prose outside a one-row table all count
printf 'Can you do it now?\n' > "$T/tk.parent.md"; WHY='This sentence explains how the code works inside in great detail so the reader has to wade through it again and again.'
{ printf 'Done in abc1234567.\n\n| Item | Notes |\n|---|---|\n| `a.ts` | 7 ⇒ 9 |\n'; for n in $(seq 1 30); do echo "| Why $n | $WHY |"; done; } > "$T/tk1.md"
{ printf 'Done in abc1234567.\n\n| Commit | Notes | Rating |\n|---|---|---|\n'; for n in $(seq 1 30); do echo "| x$n | $WHY | ok |"; done; } > "$T/tk2.md"
{ for n in $(seq 1 10); do echo "$WHY"; done; printf '\n| `a.ts` | 7 ⇒ 9 |\n'; } > "$T/tk3.md"
tk() { MERGEWORTHY_BADGE=off python3 "$R/bin/post-lint" "$T/$1.md" --kind reply --parent "$T/tk.parent.md" 2>&1 | grep -c "$2"; }
check "BLOCK: prose rows under one rated row, a commit-review table with no rating, and one row under 220 words answering a short comment" "1 1 1" "$(tk tk1 'words > 300') $(tk tk2 'words > 300') $(tk tk3 'answering a 5-word comment (cap 100 with 20 words for its 1 rated row)')"
# one count: the cap's rated rows come from the text the count reads, so a block's title changes neither; a rated row or its header
# leaves the count only up to 45 words a cell; these cases cover a column-0 triple fence and a lone hidden row (other fences and the mixed case below)
sed 's/<summary>[^<]*<\/summary>/<summary>Refactor pass<\/summary>/' "$T/rr/rating-reply.md" > "$T/rr/canon.md"; cp "$T/rr/rating-reply.parent.md" "$T/rr/canon.parent.md"
check "the #3609 result with its blocks titled 'Refactor pass' passes, as it does under its own titles" 0 "$(MERGEWORTHY_BADGE=off python3 "$R/bin/post-lint" "$T/rr/canon.md" --kind reply --repo vikejs/vike >/dev/null 2>&1; echo $?)"
P=$(for n in $(seq 1 20); do printf '%s ' "$WHY"; done)
printf 'Done in abc1234567.\n\n| %s | Old ⇒ new |\n|---|---|\n| `a.ts` | 7 ⇒ 9 |\n' "$P" > "$T/tk4.md"; printf 'Done in abc1234567.\n\n| Item | Old ⇒ new | Why |\n|---|---|---|\n| `a.ts` | 7 ⇒ 9 | %s |\n' "$P" > "$T/tk5.md"
printf 'Done in abc1234567. I rated every file.\n\n```\n| a.ts | 7 ⇒ 9 |\n```\n' > "$T/tk6.md"; printf 'Done in abc1234567. I rated every file.\n\n<!--\n| a.ts | 7 ⇒ 9 |\n-->\n' > "$T/tk7.md"
check "BLOCK: 440 words in a rated table's header, or in a rated row's reason, count past 45 a cell; a row in code or a comment excuses no 'rated every'" "1 1 1 1" "$(tk tk4 'words > 300') $(tk tk5 'words > 300') $(tk tk6 "process in the thread: 'rated every'") $(tk tk7 "process in the thread: 'rated every'")"
# cells split as GitHub renders them (an escaped \| stays inside its cell), a header exempt up to 45 words in all, and an item the pass added rated new ⇒ N
ESC=$(for n in $(seq 1 16); do printf '%s \\| ' "$WHY"; done); WIDE=$(for n in $(seq 1 18); do printf '| %s ' "$WHY"; done)
printf 'Done in abc1234567.\n\n| Item | Old ⇒ new | Why |\n|---|---|---|\n| `a.ts` | 7 ⇒ 9 | %s |\n' "$ESC" > "$T/tk8.md"
{ printf 'Done in abc1234567.\n\n%s|\n' "$WIDE"; printf '|---%.0s' $(seq 1 18); printf '|\n| `a.ts` | 7 ⇒ 9 |\n'; } > "$T/tk9.md"
{ printf 'Done in abc1234567. I rated every file.\n\n| Item | Old ⇒ new | Why |\n|---|---|---|\n'; for n in $(seq 1 20); do echo "| \`f$n.ts\` | new ⇒ 9 | The pass added this file to hold one step the loader did before, now named. |"; done; } > "$T/tk10.md"
check "BLOCK: 350 words behind escaped pipes in one reason cell, or an 18-cell header, count; 20 added items rated new ⇒ 9 are rated rows" "1 1 0" "$(tk tk8 'words > 300') $(tk tk9 'words > 300') $(MERGEWORTHY_BADGE=off python3 "$R/bin/post-lint" "$T/tk10.md" --kind reply --parent "$T/tk.parent.md" >/dev/null 2>&1; echo $?)"
# code fences as CommonMark draws them: indented up to 3 spaces, closed only by a fence of the same character at least as long
printf 'Done in abc1234567. I rated every file.\n\n  ```\n  | a.ts | 7 ⇒ 9 |\n  ```\n' > "$T/tk11.md"; printf 'Done in abc1234567. I rated every file.\n\n````md\n```\n| a.ts | 7 ⇒ 9 |\n````\n' > "$T/tk12.md"
printf 'Done in abc1234567. I rated every file.\n\n| Commit | What it does, and the idea behind it | Rating |\n|---|---|---|\n| abc1234567 | Splits the loader. | 9/10 |\n\n<!--\n| a.ts | 7 ⇒ 9 |\n-->\n' > "$T/tk13.md"
check "BLOCK: a rated row in an indented fence or a four-backtick fence isn't shown; nor is a hidden row next to a shown review table" "1 1 1" "$(tk tk11 "process in the thread: 'rated every'") $(tk tk12 "process in the thread: 'rated every'") $(tk tk13 "process in the thread: 'rated every'")"
printf '%s #3557 follows the rule you agreed to, with the proxy inside.\n' "$B" > "$T/cr.md"
check "an agreement credited without a link is flagged" 1 "$(python3 "$R/bin/post-lint" "$T/cr.md" --parent none 2>&1 | grep -c 'credit without a link')"
printf '%s #3557 follows the rule you agreed to ([here](https://github.com/o/r/issues/1#issuecomment-2)).\n' "$B" > "$T/cr2.md"
check "with a link it passes" 0 "$(python3 "$R/bin/post-lint" "$T/cr2.md" --parent none 2>&1 | grep -c 'credit without a link')"
printf '%s Done: eight commits, none changing behavior.\n\nOne change I didn'"'"'t make: the handler stays.\n' "$B" > "$T/lbl.md"
check "a label opening a sentence is flagged" 2 "$(python3 "$R/bin/post-lint" "$T/lbl.md" --parent none 2>&1 | grep -c 'a label opening a sentence')"
printf '%s I landed eight commits at 14:52, and here is the plan I see:\n\n1. Fix it.\n' "$B" > "$T/lbl2.md"
check "a time, or a colon before a list, is not a label" 0 "$(python3 "$R/bin/post-lint" "$T/lbl2.md" --parent none 2>&1 | grep -c 'a label opening a sentence')"
printf '%s Fixes the leak.\n\n<details>\n<summary>Refactor pass, run 2 (head abc1234)</summary>\n\nS1 and S2. %s\n</details>\n' "$B" "$(printf 'word %.0s' $(seq 300))" > "$T/rpb.md"
printf '%s Fixes the leak.\n\n<details>\n<summary>Approach (head abc1234)</summary>\n\n%s\n</details>\n' "$B" "$(printf 'word %.0s' $(seq 300))" > "$T/apb.md"
check "an Approach block collapsed in a PR body is not counted" 0 "$(python3 "$R/bin/post-lint" "$T/apb.md" --kind pr --parent none 2>&1 | grep -c 'words >')"
check "the converge steps' runs collapsed in a PR body are not linted or counted" 0 "$(python3 "$R/bin/post-lint" "$T/rpb.md" --kind pr --parent none 2>&1 | grep -c 'internal label\|words >')"
# a PR body of 280 prose words plus <extra>: prose moved into a table or a code block still counts, data doesn't
tblint() { printf 'Fixes the leak. %s\n\n%s\n' "$(printf 'word %.0s' $(seq 280))" "$1" > "$T/tb.md"; python3 "$R/bin/post-lint" "$T/tb.md" --kind pr --parent none 2>&1 | grep -c 'words >'; }
SETUP='Each run started from a cold cache on the same laptop with nothing else running, three warmups first, and the median of ten runs reported.'
check "a prose sentence moved into a table row counts" 1 "$(tblint "$(printf '| Run | main | head |\n|---|---|---|\n| setup | %s | same |\n| p50 | 22.6 s | 6.1 s |' "$SETUP")")"
check "a note in a one-cell table counts" 1 "$(tblint "$(printf '| Note |\n|---|\n| The old cache path stays readable for one more release, so that a rollback to the previous version keeps finding its files. |')")"
check "a data table of numbers, names and statuses stays free" 0 "$(tblint "$(printf '| Test | main | head | Result |\n|---|---|---|---|\n'; for i in $(seq 40); do printf '| `case-%s` | 22.6 s, peak 1008 MiB | 6.1 s, peak 329 MiB | pass |\n' "$i"; done)")"
check "prose lines in a code block count" 1 "$(tblint "$(printf '```\n%s\n%s\n```' "$SETUP" "$SETUP")")"
check "commands, paths and results in a code block stay free" 0 "$(tblint "$(printf '```bash\npnpm --filter api test -- stats\ncat /tmp/bench/out.txt\npnpm test -> exit 0\nrequests per second 1204 1187 1199 1210\n```')")"
printf '%s Draft until the release ships.\n\nThe fix.\n' "$B" > "$T/st.md"
check "a PR body that opens with its status is flagged" 1 "$(python3 "$R/bin/post-lint" "$T/st.md" --kind pr --parent none 2>&1 | grep -c 'opens with its status')"
printf '%s Routes after vike(app) skip the auth +middleware. This PR runs it first.\n\nDraft until the release ships.\n' "$B" > "$T/st2.md"
check "status after the opening is fine" 0 "$(python3 "$R/bin/post-lint" "$T/st2.md" --kind pr --parent none 2>&1 | grep -c 'opens with its status')"
# ---------- post-lint + pre-bash-guard: a draft PR's body says why it's a draft, on a bold State line under the badge ----------
# ---------- post-lint: a ready PR body follows pull-request §Body's template ----------
printf 'Compression stopped after sirv() answered; this PR runs it.\n\nA wall of prose about it.\n' > "$T/s7a.md"
printf 'Compression stopped after sirv() answered; this PR runs it.\n\n### What you should see\n\n**1.** main, then this PR:\n\n```\ncurl -sI /a.js | grep content-encoding\n```\n' > "$T/s7b.md"
check "a ready PR body without What you should see is flagged" 1 "$(python3 "$R/bin/post-lint" "$T/s7a.md" --kind pr --parent none 2>&1 | grep -c 'pull-request §Body')"
check "one with numbered evidence passes" 0 "$(python3 "$R/bin/post-lint" "$T/s7b.md" --kind pr --parent none 2>&1 | grep -c 'pull-request §Body')"
printf 'Compression stopped after sirv() answered; this PR runs it.\n\n### What you should see\n\n**1.** the asset arrives compressed:\n\n<img width="600" alt="gzip" src="https://example.invalid/a.png" />\n' > "$T/s7c.md"
check "an uploaded image counts as the evidence" 0 "$(python3 "$R/bin/post-lint" "$T/s7c.md" --kind pr --parent none 2>&1 | grep -c 'pull-request §Body')"
printf 'Compression stopped after sirv() answered; this PR runs it.\n\n<details><summary>Evidence</summary>\n\n### What you should see\n\n**1.** main, then this PR:\n\n```\ncurl -sI /a.js\n```\n</details>\n' > "$T/s7d.md"
check "evidence only inside <details> is flagged" 1 "$(python3 "$R/bin/post-lint" "$T/s7d.md" --kind pr --parent none 2>&1 | grep -c 'pull-request §Body')"
printf 'Compression stopped after sirv() answered; this PR runs it.\n\n### What you should see\n\nThe asset arrives compressed now, as the curl output shows when you run it.\n' > "$T/s7e.md"
check "a section without numbered evidence is flagged" 1 "$(python3 "$R/bin/post-lint" "$T/s7e.md" --kind pr --parent none 2>&1 | grep -c 'pull-request §Body')"
check "a draft's body needn't have it yet" 0 "$(printf '**State: draft** (waits on the release)\n\nCompression stopped after sirv() answered.\n' > "$T/s7f.md"; python3 "$R/bin/post-lint" "$T/s7f.md" --kind pr --draft --parent none 2>&1 | grep -c 'pull-request §Body')"
dlint() { python3 "$R/bin/post-lint" "$T/ds.md" --kind pr --parent none "$@" 2>&1 | grep -c "State line\|State: draft\|opens with its status"; }
printf '%s\n**State: draft** (waits on the Vike release with vikejs/vike#3594)\n\nRoutes after vike(app) skip the auth +middleware. This PR runs it first.\n' "$B" > "$T/ds.md"
check "a draft's body with its State line passes" 0 "$(dlint --draft)"
check "the same line in a body that isn't a draft is flagged" 1 "$(dlint)"
sed -i 's/^\*\*State: draft\*\* (.*)$/**State: draft** ( )/' "$T/ds.md"
check "a State line with no reason is flagged" 1 "$(dlint --draft)"
sed -i '/^\*\*State:/d' "$T/ds.md"
check "a draft's body without its State line is flagged" 1 "$(dlint --draft)"
check "a body that isn't a draft needs no State line" 0 "$(dlint)"
printf '%s\n**State: draft** (my bug check is still running)\n\nDraft: waits on the release.\n\nThe fix.\n' "$B" > "$T/ds.md"
check "under the State line, a status opener is still flagged" 1 "$(dlint --draft)"
mkdir -p "$T/dsd"; printf '%s *Opus 5.5 (high effort) wrote this.*\n**State: draft** (my bug check is still running)\n\nRoutes after vike(app) skip the auth +middleware. This PR runs it first.\n' '<img src="https://github.com/claude.png" width="20" height="20" alt="Claude">' > "$T/dsd/pr.md"
echo CLEAN > "$T/dsd/review.out"; touch -d '+1 minute' "$T/dsd/review.out"; python3 "$R/bin/post-lint" "$T/dsd/pr.md" --kind pr --parent none --draft >/dev/null 2>&1
check "gate-pass replays --draft from the .lint record (without it the State line fails)" 0 "$(bash "$R/bin/gate-pass" "$T/dsd/pr.md" "$T/dsd/review.out" >/dev/null 2>&1; echo $?)"
touch -d '+2 minutes' "$T/dsd/pr.md"
check "BLOCK: gate-pass on a draft edited after its review (a trim to the ceiling), naming post steps 2 and 3" "1 1" "$(bash "$R/bin/gate-pass" "$T/dsd/pr.md" "$T/dsd/review.out" >"$T/dsd/gp.out" 2>&1; echo $?) $(grep -c 'changed after its review.*post step 2.*post step 3' "$T/dsd/gp.out")"
dguard() { # body file -> exit code of the guard on `gh pr create --draft`
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh pr create --draft --repo o/r --title \"$(cat /w/drafts/title.md)\" --body-file "+sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$TCO" \
    | MERGEWORTHY_WATCHER=off python3 "$R/hooks/pre-bash-guard.py" 2>"$T/err"; echo $?
}
printf '%s\nRoutes after vike(app) skip the auth +middleware. This PR runs it first.\n' "$B" > "$T/dg.md"; sha256sum "$T/dg.md" | cut -d' ' -f1 > "$T/dg.md.gate"
check "BLOCK: gh pr create --draft with a body that doesn't say why it's a draft" "2 1" "$(dguard "$T/dg.md") $(grep -c 'State: draft' "$T/err")"
printf '%s\n**State: draft** (my bug check is still running)\n\nRoutes after vike(app) skip the auth +middleware. This PR runs it first.\n' "$B" > "$T/dg.md"; sha256sum "$T/dg.md" | cut -d' ' -f1 > "$T/dg.md.gate"
check "gh pr create --draft with the State line, gated, passes" 0 "$(dguard "$T/dg.md")"
# ---------- post-lint + pre-bash-guard: a repo whose project file says `Language: hu` gets its checks in Hungarian ----------
mkdir -p "$HOME/.mergeworthy/projects/acme"; HUP="$HOME/.mergeworthy/projects/acme/hu.md"
cat > "$T/hu.md" <<'EOF'
<img src="https://github.com/claude.png" width="20" height="20" alt="Claude"> *Az Opus 5.5 (közepes erőfeszítés) írta ezt és a kódot; egy második Opus 5.5 (nagyon magas erőfeszítés) ellenőrizte.*
**Állapot: piszkozat** (a CI futtatója nem működik)

A feltöltés elakad nagy fájloknál. Ez az MR darabokban küldi a fájlt.

| Megjegyzés | Fajta | Blokkolja a beolvasztást | Következő |
|---|---|---|---|
| A régi kliens nem darabol | hiba | nem | javítva: abc1234 |

### Döntés: darabméret

```py
CHUNK = 5 * 1024 * 1024
```

(a) 5 MB: kevesebb kérés.
(b) 1 MB: gyorsabb újrapróbálás.

Az (a) lehetőséget választottam, mert kevesebb kérést küld.

<details>
<summary>Ellenőrzések (head abc1234)</summary>

pytest unit_tests -> exit 0
</details>
EOF
cp "$T/hu.md" "$T/hu0.md"
hulint() { MERGEWORTHY_BADGE=on python3 "$R/bin/post-lint" "$T/hu.md" --kind pr --draft --repo acme/hu --parent none >"$T/hu.out" 2>&1; echo $?; }
printf '# acme/hu\n\n## PR conventions\n- Language: hu\n' > "$HUP"
check "a Hungarian draft PR body passes post-lint under Language: hu" 0 "$(hulint)"
printf '# acme/hu\n\n## PR conventions\n- Titles: sentence case.\n' > "$HUP"
check "BLOCK: the same body with no Language line, on its State line and effort words" "1 1 1" "$(hulint) $(grep -c 'State: draft' "$T/hu.out") $(grep -c 'model line without effort' "$T/hu.out")"
printf '# acme/hu\n\nLanguage: hu\n' > "$HUP"
check "BLOCK: under Language: hu, an English State line and a decision without its Hungarian pick" "1 1 1" "$(sed -i 's/^\*\*Állapot: piszkozat\*\*/**State: draft**/; s/^Az (a) lehetőséget választottam/I picked (a)/' "$T/hu.md"; hulint) $(grep -c 'Állapot: piszkozat' "$T/hu.out") $(grep -c 'választottam' "$T/hu.out")"
printf '%s\nA feltöltés elakad nagy fájloknál. Ez az MR darabokban küldi a fájlt.\n\n### Amit látni fogsz\n\n**1.** Egy 50 MB-os fájl feltöltése:\n\n```\nPOST /upload -> 201\n```\n' "$B" > "$T/hus.md"
check "a ready Hungarian body's evidence heading passes under Language: hu, not without it" "0 1" "$(python3 "$R/bin/post-lint" "$T/hus.md" --kind pr --repo acme/hu --parent none 2>&1 | grep -c 'pull-request §Body') $(python3 "$R/bin/post-lint" "$T/hus.md" --kind pr --repo acme/en --parent none 2>&1 | grep -c 'pull-request §Body')"
hdguard() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh pr create --draft --repo acme/hu --title \"$(cat /w/drafts/title.md)\" --body-file "+sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$TCO" \
    | MERGEWORTHY_WATCHER=off python3 "$R/hooks/pre-bash-guard.py" 2>"$T/err"; echo $?; }
printf '%s\n**Állapot: piszkozat** (a CI futtatója nem működik)\n\nA feltöltés elakad nagy fájloknál.\n' "$B" > "$T/hdg.md"; sha256sum "$T/hdg.md" | cut -d' ' -f1 > "$T/hdg.md.gate"
check "gh pr create --draft without --repo takes the language of GH_REPO, not of the checkout's origin" 0 "$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"GH_REPO=acme/hu gh pr create --draft --title \"$(cat /w/drafts/title.md)\" --body-file "+sys.argv[1]},"cwd":sys.argv[2]}))' "$T/hdg.md" "$TCO" \
  | MERGEWORTHY_WATCHER=off python3 "$R/hooks/pre-bash-guard.py" 2>"$T/err"; echo $?)"
check "gh pr create --draft accepts the Hungarian State line under Language: hu, and blocks it without" "0 2" "$(hdguard "$T/hdg.md") $(printf '# acme/hu\n' > "$HUP"; hdguard "$T/hdg.md")"
# without --repo (the livekit session's calls), the language comes from the draft's watch dir: the repos.txt above it
LK="$T/lkw"; mkdir -p "$LK/drafts"; cp "$T/hu0.md" "$LK/drafts/mr.md"; echo CLEAN > "$LK/drafts/mr.review.out"; printf '# acme/hu\n\nLanguage: hu\n' > "$HUP"
lkgp() { (cd "$T" && MERGEWORTHY_BADGE=on python3 "$R/bin/post-lint" "$LK/drafts/mr.md" --kind pr --draft >/dev/null 2>&1; touch -d '+1 minute' "$LK/drafts/mr.review.out"; MERGEWORTHY_BADGE=on GATED_POSTS="$T/gp.txt" bash "$R/bin/gate-pass" "$LK/drafts/mr.md" "$LK/drafts/mr.review.out" >"$T/lk.out" 2>&1; echo $?); }  # gate-pass reruns post-lint with the flags it passed with
echo 'gitlab.com/acme/hu' > "$LK/repos.txt"
check "a Hungarian draft linted and gate-passed with --kind pr --draft and no --repo passes: its watch dir's repos.txt names the repo" 0 "$(lkgp)"
printf 'gitlab.com/acme/hu\nacme/en\n' > "$LK/repos.txt"; printf 'acme/en 3\n' > "$LK/threads.txt"
check "BLOCK: a watch dir with two repos where threads.txt names the English one, so the English checks apply" "1 1" "$(lkgp) $(grep -c 'State: draft' "$T/lk.out")"
printf 'gitlab.com/acme/hu 184\nacme/en 3\n' > "$LK/threads.txt"
check "BLOCK: two repos that threads.txt doesn't single out: a finding asking for --repo" "1 1" "$(lkgp) $(grep -c 'pass --repo' "$T/lk.out")"
printf 'gitlab.com/acme/hu 184\n' > "$LK/threads.txt"
check "two repos, threads.txt naming one: that one's language" 0 "$(lkgp)"
# the umbrella's headings in the repo's language (task §Umbrella)
printf '## Döntések\n\nMinden eddigi döntés, a forrásával.\n\n### Folyamat és követelmények\n- Minden magyarul ([link](https://example.invalid/1))\n\n### Elfogadva\n- A darabméret 5 MB ([link](https://example.invalid/2))\n' > "$T/hud.md"
check "BLOCK: a Hungarian Decisions comment without its '### Nyitott' section, under Language: hu" 1 "$(python3 "$R/bin/post-lint" "$T/hud.md" --kind tracker --repo acme/hu --parent none 2>&1 | grep -c "needs a '### Nyitott' section")"
printf 'Title: Követés: kárbejelentés\n\n## Folyamatban\n- [ ] gitlab.com/acme/hu!3: a feltöltés\n' > "$T/hut.md"
check "a Hungarian umbrella title 'Követés: …' passes under Language: hu" 0 "$(python3 "$R/bin/post-lint" "$T/hut.md" --kind tracker --repo acme/hu --parent none 2>&1 | grep -c "the title starts")"
rm -f "$HUP"
printf '%s Two fundamental issues remain.\n' "$B" > "$T/fund.md"
check "a difficulty word without its scope is flagged" 1 "$(python3 "$R/bin/post-lint" "$T/fund.md" --kind issue --parent none 2>&1 | grep -c 'what it.s hard for')"
# the budget grows with the questions in the comment answered
printf 'One? Two? Three?\n' > "$T/q.parent.md"
printf '%s %s\n' "$B" "$(printf 'word %.0s' $(seq 350))" > "$T/q.md"
check "a reply of 350 words is over the ceiling, however many questions" 1 "$(python3 "$R/bin/post-lint" "$T/q.md" --parent "$T/q.parent.md" 2>&1 | grep -c 'for a reply')"
printf 'One?\n' > "$T/q1.parent.md"
check "the same reply to one question is over budget" 1 "$(python3 "$R/bin/post-lint" "$T/q.md" --parent "$T/q1.parent.md" 2>&1 | grep -c 'for a reply')"
printf 'See https://x.io/a?b=1 and https://x.io/c?d=2.\n```\na ? b : c ? d : e\n```\nOK?\n' > "$T/q2.parent.md"
check "question marks in URLs and code don't count" 1 "$(python3 "$R/bin/post-lint" "$T/q.md" --parent "$T/q2.parent.md" 2>&1 | grep -c 'for a reply')"
cp "$T/q.parent.md" "$T/q3.parent.md"; cp "$T/q.md" "$T/q3.md"
check "--parent none ignores a parent file next to the draft" 1 "$(python3 "$R/bin/post-lint" "$T/q3.md" --parent none 2>&1 | grep -c 'for a reply')"
for s in 'Fundamental problems remain in this design.' 'It is impossible to fix this.' 'The fix is impossible.'; do
  printf '%s %s\n' "$B" "$s" > "$T/fund3.md"
  check "flagged: $s" 1 "$(python3 "$R/bin/post-lint" "$T/fund3.md" --kind issue --parent none 2>&1 | grep -c 'what it.s hard for')"
done
for s in 'This fundamentally changes the public API.' 'The guard covers an impossible state.' 'A fundamental issue for the adapter remains.'; do
  printf '%s %s\n' "$B" "$s" > "$T/fund3.md"
  check "passes: $s" 0 "$(python3 "$R/bin/post-lint" "$T/fund3.md" --kind issue --parent none 2>&1 | grep -c 'what it.s hard for')"
done
printf '%s A problem fundamental to one injection point; "fundamental" was the wrong word.\n' "$B" > "$T/fund2.md"
check "a scoped or quoted difficulty word passes" 0 "$(python3 "$R/bin/post-lint" "$T/fund2.md" --kind issue --parent none 2>&1 | grep -c 'what it.s hard for')"
# ---------- post-lint: an issue a newcomer can find (open-issue, evidence) ----------
ilint() { python3 "$R/bin/post-lint" "$1" --kind issue --parent none 2>&1 | grep -c "$2"; }
printf '%s The invoice keeps the winning account, not the typed one.\n' "$B" > "$T/i0.md"
check "a badge alone is no evidence" 1 "$(ilint "$T/i0.md" 'no evidence')"
check "an issue needs How to reproduce" 1 "$(ilint "$T/i0.md" 'no .### How to reproduce')"
printf '%s The list shows the winning account.\n\n### How to reproduce\n\n1. Log in as a manager, open /invoices\n2. See the account column\n\n![list](/abs/list.png)\n' "$B" > "$T/i1.md"
check "one screen in a screenshot passes" 0 "$(python3 "$R/bin/post-lint" "$T/i1.md" --kind issue --parent none 2>&1 | grep -c 'evidence\|How to reproduce\|video')"
printf '%s The saved invoice drops the typed account.\n\n### How to reproduce\n\n1. Log in as a manager\n2. Open a won job\n3. Create an invoice with another account\n4. Save, then see the list\n\n![list](/abs/list.png)\n' "$B" > "$T/i2.md"
check "a multi-step flow in stills needs a video" 1 "$(ilint "$T/i2.md" 'record a video')"
sed 's#/abs/list.png#/abs/flow.mp4#' "$T/i2.md" > "$T/i3.md"
check "the flow as a video passes" 0 "$(ilint "$T/i3.md" 'video\|evidence')"
printf '%s CI runs no tests.\n\n### How to reproduce\n\n1. Run the backend tests\n\n```\n$ pnpm test\nUnknown option --threads\n```\n' "$B" > "$T/i4.md"
check "no screen: the command and output pass" 0 "$(ilint "$T/i4.md" 'evidence')"
{ printf '%s Who picks the payout account?\n\n### How to reproduce\n\n1. Open /invoices\n\n![list](/abs/list.png)\n\n### Options\n\n' "$B"; printf 'word %.0s' $(seq 120); echo; } > "$T/i5.md"
check "a decision issue gets a word budget, not 400 characters" 0 "$(ilint "$T/i5.md" 'for an issue\|decision issue')"
# ---------- pre-bash-guard: no foreground waits ----------
wait_guard() { # command background(true|false)
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1],"run_in_background":sys.argv[2]=="true"},"cwd":sys.argv[3]}))' "$1" "$2" "$T" \
    | python3 "$R/hooks/pre-bash-guard.py" 2>/dev/null; echo $?
}
check "BLOCK: a foreground until-sleep loop" 2 "$(wait_guard 'until [ -s out.md ]; do sleep 20; done; cat out.md' false)"
check "the same loop in the background passes" 0 "$(wait_guard 'until [ -s out.md ]; do sleep 20; done; cat out.md' true)"
check "a plain sleep passes" 0 "$(wait_guard 'sleep 2; ls' false)"
check "a loop written into a file by a heredoc passes: nothing waits" 0 "$(wait_guard "$(printf 'cat > x.md <<EOF\nuntil done; do sleep 5; done\nEOF')" false)"
check "a loop in a quoted argument passes" 0 "$(wait_guard "jq -n --arg s 'while true; do sleep 1; done' '\$s'" false)"
check "BLOCK: a loop a shell runs from a heredoc" 2 "$(wait_guard "$(printf 'bash <<EOF\nuntil [ -s out.md ]; do sleep 5; done\nEOF')" false)"
check "BLOCK: a loop running sleep by its path" 2 "$(wait_guard 'while true; do /usr/bin/sleep 1; done' false)"
check "BLOCK: a loop in bash -c" 2 "$(wait_guard "bash -c 'while true; do sleep 1; done'" false)"
check "BLOCK: a loop running bash -c or a heredoc script with a sleep" "2 2" "$(wait_guard "while true; do bash -c 'sleep 1'; done" false) $(wait_guard "$(printf 'while true; do bash <<EOF\nsleep 1\nEOF\ndone')" false)"
check "BLOCK: a loop sent to the background in a foreground command" 2 "$(wait_guard '(until [ -s out.md ]; do sleep 20; done) & wait' false)"
check "BLOCK: a loop with sleep in a command that doesn't parse" 2 "$(wait_guard 'until [ -s out.md ]; do sleep 20; done; echo "x' false)"
# ---------- pre-agent-dedupe: one agent per job ----------
launch_in() { python3 -c 'import json,sys,time; print(json.dumps({"tool_name":"mcp__t3-code__delegate_task","tool_input":{"task":sys.argv[1],"title":"t","clientRequestId":f"t-{time.time_ns()}-r1"}}))' "$1"; }
launch() { # task text; a launch that passes runs, so the PostToolUse half registers it
  launch_in "$1" | python3 "$R/hooks/pre-agent-dedupe.py" 2>/dev/null; local rc=$?
  [ $rc = 0 ] && launch_in "$1" | python3 "$R/hooks/pre-agent-dedupe.py" register; echo $rc
}
check "first launch of a ticket passes" 0 "$(launch 'Execute the ticket at /tmp/x/ticket-check.md exactly')"
check "BLOCK: a second launch of the same ticket" 2 "$(launch 'Retry: execute /tmp/x/ticket-check.md')"
check "another ticket passes" 0 "$(launch 'Execute /tmp/x/other.md')"
launch_in 'Execute /tmp/x/blocked.md' | python3 "$R/hooks/pre-agent-dedupe.py" >/dev/null 2>&1
check "a launch another hook blocked (never ran) leaves no job" 0 "$(launch 'Execute /tmp/x/blocked.md')"
refused() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"mcp__t3-code__delegate_task","tool_input":{"task":sys.argv[1],"title":"t"},"tool_response":[{"type":"text","text":"code: parent_not_active"}]}))' "$1" | python3 "$R/hooks/pre-agent-dedupe.py" register; }
check "a launch T3 refused (parent_not_active) says what to do and leaves no job" "1 0" "$(refused 'Execute /tmp/x/refused.md' | grep -c 'do the step yourself') $(launch 'Execute /tmp/x/refused.md')"
python3 "$R/bin/agent-job" done /tmp/x/ticket-check.md >/dev/null
check "after agent-job done the ticket launches again" 0 "$(launch 'Execute /tmp/x/ticket-check.md')"
check "agent-job done takes a ticket path relative to the cwd" 0 "$(mkdir -p /tmp/x && touch /tmp/x/ticket-check.md && cd /tmp/x && python3 "$R/bin/agent-job" done ticket-check.md >/dev/null; echo $?)"
check "a ~/ ticket path is the job's key, expanded" "$HOME/x-tilde-ticket.md" "$(launch 'Execute ~/x-tilde-ticket.md' >/dev/null; python3 "$R/bin/agent-job" list | grep -o "$HOME/x-tilde-ticket.md")"
python3 "$R/bin/agent-job" done "$HOME/x-tilde-ticket.md" >/dev/null
check "an installed skill a brief names is no part of its job's key" "/tmp/x/rev-a.md t" "$(launch 'Execute /tmp/x/rev-a.md by ~/.mergeworthy/current/skills/review/SKILL.md' >/dev/null; python3 "$R/bin/agent-job" list | grep rev-a | sed 's/^ *[0-9]* min  //')"
python3 "$R/bin/agent-job" done /tmp/x/rev-a.md >/dev/null
fan() { # task title
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"mcp__t3-code__delegate_task","tool_input":{"task":sys.argv[1],"title":sys.argv[2]}}))' "$1" "$2" > "$T/fan.json"
  python3 "$R/hooks/pre-agent-dedupe.py" < "$T/fan.json" 2>/dev/null; local rc=$?
  [ $rc = 0 ] && python3 "$R/hooks/pre-agent-dedupe.py" register < "$T/fan.json"; echo $rc; }
check "a fan-out on one brief passes, one launch per title; the same brief and title again is blocked" "0 0 2" "$(fan $'Topic: cost\nFollow /tmp/x/fan.md' 'fan: cost') $(fan $'Topic: security\nFollow /tmp/x/fan.md' 'fan: security') $(fan $'Topic: cost\nFollow /tmp/x/fan.md' 'fan: cost')"
check "agent-job done with the shared brief path releases neither; each job releases by its full key" "1 0 0" "$(python3 "$R/bin/agent-job" done /tmp/x/fan.md >/dev/null 2>&1; echo $?) $(python3 "$R/bin/agent-job" done '/tmp/x/fan.md fan: cost' >/dev/null; echo $?) $(python3 "$R/bin/agent-job" done '/tmp/x/fan.md fan: security' >/dev/null; echo $?)"
fan 'Follow /tmp/x/fan.md' "the user's ask" >/dev/null; python3 "$R/hooks/pre-agent-dedupe.py" < "$T/fan.json" 2>"$T/err"
check "the block's release command, run as printed, releases a job whose title has an apostrophe" "0 0" "$(eval "$(grep -o 'agent-job done [^\`]*' "$T/err" | sed "s|^agent-job|python3 $R/bin/agent-job|")" >/dev/null; echo $?) $(python3 "$R/bin/agent-job" list | grep -c "user's ask")"
cid_in() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"mcp__t3-code__delegate_task","tool_input":{"task":"x","clientRequestId":sys.argv[1]}}))' "$1"; }
cid() { # clientRequestId
  cid_in "$1" | python3 "$R/hooks/pre-agent-dedupe.py" 2>/dev/null; local rc=$?
  [ $rc = 0 ] && cid_in "$1" | python3 "$R/hooks/pre-agent-dedupe.py" register; echo $rc
}
check "a new clientRequestId passes" 0 "$(cid r-1)"
check "a retry of the same clientRequestId within 10 minutes passes" 0 "$(cid r-1)"
python3 -c 'import json,os,time; p=os.path.expanduser("~/.claude/agent-client-request-ids.json"); d=json.load(open(p)); d["r-1"]=time.time()-3600; json.dump(d,open(p,"w"))'
check "BLOCK: a clientRequestId reused later (T3 replays the old result)" 2 "$(cid r-1)"
for i in $(seq 40); do (cid_in "c-$i" | python3 "$R/hooks/pre-agent-dedupe.py" register 2>/dev/null || echo crash) & done > "$T/cid.out"; wait
check "40 launches registering at once: none crashes, none is lost" "0 40" "$(grep -c crash "$T/cid.out") $(python3 -c 'import json,os; print(sum(k.startswith("c-") for k in json.load(open(os.path.expanduser("~/.claude/agent-client-request-ids.json")))))')"
rnd() { # clientRequestId task [role]
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"mcp__t3-code__delegate_task","tool_input":{"task":sys.argv[2],"role":sys.argv[3],"clientRequestId":sys.argv[1]}}))' "$1" "$2" "${3:-review}" | python3 "$R/hooks/pre-agent-dedupe.py" 2>/dev/null; echo $?; }
agent_rnd() { # description prompt
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Agent","tool_input":{"description":sys.argv[1],"prompt":sys.argv[2]}}))' "$1" "$2" | python3 "$R/hooks/pre-agent-dedupe.py" 2>/dev/null; echo $?; }
check "a review launch at any round, or naming none, passes: rounds aren't capped, the loop stops when a round finds only nits" "0 0 0" "$(rnd loop-a-r7 'Follow /tmp/x/rr.md') $(rnd loop-a 'Follow /tmp/x/rr.md') $(agent_rnd fresh-r5 'Review it. Final message: exactly CLEAN, or the findings.')"
J="$HOME/.claude/agent-jobs"; mkdir -p "$J"
printf '{"key": "/x/a.md /x/shared.md", "started": 1}' > "$J/aj1.json"; printf '{"key": "/x/b.md /x/shared.md", "started": 2}' > "$J/aj2.json"
check "agent-job done with a path two jobs hold releases neither" "1 2" "$(python3 "$R/bin/agent-job" done /x/shared.md >/dev/null 2>&1; echo $? $(ls "$J"/aj*.json | wc -l))"
check "agent-job done with the full key releases only that job" 1 "$(python3 "$R/bin/agent-job" done '/x/a.md /x/shared.md' >/dev/null; ls "$J"/aj*.json | wc -l)"
rm -f "$J"/aj*.json
# agent-job done lists what the agent may have left running where it worked, and kills nothing
git init -q -b main "$T/lr"; git -C "$T/lr" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m one
git -C "$T/lr" worktree add -q -b lw "$T/lw"; mkdir -p "$T/lw/app" "$T/lwork" "$T/lother"
printf 'Goal: fix it.\nWork in %s.\n' "$T/lw" > "$T/lwork/brief.md"
launch "Follow $T/lwork/brief.md exactly" >/dev/null
PY=$(python3 -c 'import sys; print(sys.executable)')  # a pyenv shim would stay the parent of the listening process
(cd "$T/lw/app" && exec "$PY" -c 'import socket,time; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(); time.sleep(600)') & LPID=$!
(cd "$T/lwork" && exec sleep 600) & WPID=$!; (cd "$T/lother" && exec sleep 600) & OPID=$!; sleep 0.5
python3 "$R/bin/agent-job" done "$T/lwork/brief.md" > "$T/aj.out"
check "agent-job done lists the process left in the job's worktree with its port, the one in its brief's folder, not one elsewhere, and kills none" "1 1 0 0" "$(grep -c "^  $LPID listening on 127.0.0.1:[0-9]*: $PY -c import socket" "$T/aj.out") $(grep -c "^  $WPID: sleep 600 (in $T/lwork)" "$T/aj.out") $(grep -c "^  $OPID" "$T/aj.out") $(kill $LPID $WPID $OPID; echo $?)"
wait $LPID $WPID $OPID 2>/dev/null
# at most 3 agents open at once per session
cap_in() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"mcp__t3-code__delegate_task","session_id":sys.argv[1],"tool_input":{"task":sys.argv[2],"title":sys.argv[2][:40]}}))' "$1" "$2"; }
cap() { cap_in "$1" "$2" | python3 "$R/hooks/pre-agent-dedupe.py" 2>"$T/err"; local rc=$?; [ $rc = 0 ] && cap_in "$1" "$2" | python3 "$R/hooks/pre-agent-dedupe.py" register; echo $rc; }
check "BLOCK: a fourth agent open at once in one session, naming the three" "0 0 0 2 3" "$(cap capS 'Execute /tmp/x/cap1.md') $(cap capS 'Execute /tmp/x/cap2.md') $(cap capS 'Execute /tmp/x/cap3.md') $(cap capS 'Execute /tmp/x/cap4.md') $(grep -c '^/tmp/x/cap[123].md' "$T/err")"
check "another session, and a memory refresh in this one, pass" "0 0" "$(cap capT 'Execute /tmp/x/cap5.md') $(cap capS 'Follow skills/delegate/memory-refresh.md on /tmp/x/mem-lines.md')"
check "a fifth brief naming its fan-out step passes; one naming another step does not" "0 2" "$(cap capS $'Execute /tmp/x/cap8.md\nFan-out: converge §Running the agents') $(cap capS $'Execute /tmp/x/cap9.md\nFan-out: review step 2')"
cap_impl() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"mcp__t3-code__delegate_task","session_id":"capS","tool_input":{"task":sys.argv[1],"title":"impl","role":"implementation"}}))' "$1" | python3 "$R/hooks/pre-agent-dedupe.py" 2>/dev/null; echo $?; }
check "BLOCK: an implementation brief carrying the fan-out line still counts" 2 "$(cap_impl $'Execute /tmp/x/cap10.md\nFan-out: converge §Running the agents')"
FB="$HOME/.mergeworthy/work/fx/verify-1.md"; mkdir -p "${FB%/*}"; printf 'Verify slice 1.\nFan-out: converge §Running the agents\n' > "$FB"
check "a fifth launch following a work-folder brief that holds the fan-out line passes" 0 "$(cap capS "Follow $FB exactly")"
python3 "$R/bin/agent-job" done "$(python3 -c 'import sys; print(sys.argv[1][:40])' "Follow $FB exactly")" >/dev/null  # its key: the title
python3 "$R/bin/agent-job" done /tmp/x/cap8.md >/dev/null; python3 "$R/bin/agent-job" done /tmp/x/cap1.md >/dev/null
check "a released job no longer counts" 0 "$(cap capS 'Execute /tmp/x/cap4.md')"
python3 -c 'import glob,json,os,time; [json.dump({**json.load(open(f)), "started": time.time() - 3600}, open(f + ".n", "w")) or os.replace(f + ".n", f) for f in glob.glob(os.path.expanduser("~/.claude/agent-jobs/*")) if "cap2.md" in open(f).read()]'
mkdir -p "$HOME/.claude/projects/-cap"; python3 -c 'import json,sys; w=lambda o: print(json.dumps(o)); w({"type":"user","message":{"content":"Execute /tmp/x/cap2.md"}}); w({"type":"assistant","message":{"content":[{"type":"text","text":"Report written."}]}})' > "$HOME/.claude/projects/-cap/cap2.jsonl"
touch -d '5 minutes ago' "$HOME/.claude/projects/-cap/cap2.jsonl"
check "BLOCK: a job whose agent finished (its transcript quiet) no longer counts; the fourth open one still blocks" "0 2" "$(cap capS 'Execute /tmp/x/cap6.md') $(cap capS 'Execute /tmp/x/cap7.md')"
for k in cap2 cap3 cap4 cap5 cap6 mem-lines; do python3 "$R/bin/agent-job" done "/tmp/x/$k.md" >/dev/null; done; rm -r "$HOME/.claude/projects/-cap"
# ---------- the memory file: session-memory injects its Standing digest and says when it is behind; the guards read it ----------
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
OC="$T/orch"; MR="$T/mem"; LD="$HOME/.claude/projects/$(printf '%s' "$OC" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$OC" "$LD"
check "memory-prep init refuses a checkout with no session logs" 1 "$(cd "$T" && python3 "$R/bin/memory-prep" init "$MR" thread-1 >/dev/null 2>&1; echo $?)"
(cd "$OC" && CLAUDE_CODE_SESSION_ID=orch python3 "$R/bin/memory-prep" init "$MR" thread-1 >/dev/null)
mlog() { # file hours-ago text [thread] [extra fields as JSON]: one user prompt; with a thread, T3's handoff naming it first
  python3 -c 'import json,sys,datetime as d; f,h,txt=sys.argv[1:4]; t=(d.datetime.now(d.timezone.utc)-d.timedelta(hours=float(h))).strftime("%Y-%m-%dT%H:%M:%S.000Z")
w=lambda o: open(f,"a").write(json.dumps(o,separators=(",",":"))+"\n")
if len(sys.argv)>4 and sys.argv[4]: w({"type":"user","timestamp":t,"promptSource":"sdk","message":{"role":"user","content":"Context handoff (manual_context):\nThread: "+sys.argv[4]}})
w({"type":"user","timestamp":t,"promptSource":"sdk","message":{"role":"user","content":txt},**json.loads(sys.argv[5] if len(sys.argv)>5 else "{}")})' "$@"; }
mlog "$LD/a.jsonl" 30 "an old ruling" thread-1; mlog "$LD/a.jsonl" 2 "never use cron" thread-1; mlog "$LD/b.jsonl" 1 "another thread's line"
# the harness's own user-role entries, and a child session whose tool output names the thread
for e in '{"isMeta":true,"message":{"content":[{"type":"text","text":"Base directory for this skill: x"}]}}' '{"isMeta":true}' \
  '{"isCompactSummary":true,"promptSource":null}' '{"promptSource":"system","origin":{"kind":"task-notification"}}'; do mlog "$LD/a.jsonl" 1.5 "harness entry" "" "$e"; done
mlog "$LD/a.jsonl" 1.5 "Delegated task node:delegated-task:x reached a terminal state."
mlog "$LD/a.jsonl" 1.4 "RSC check-in."; mlog "$LD/a.jsonl" 1.3 "RSC check-in."
mlog "$LD/orch.jsonl" 1 "said in the session init ran in"; mlog "$LD/c.jsonl" 1 "a child's brief"; mlog "$LD/c.jsonl" 1 "tool output" "" '{"toolUseResult":{},"promptSource":null,"message":{"content":"thread-1"}}'
ss_mem() { python3 -c 'import json,sys; print(json.dumps({"cwd":sys.argv[1],"source":"compact"}))' "$1" | python3 "$R/hooks/session-memory.py" 2>/dev/null; }
check "session-memory in the orchestrator's checkout, memory missing: the refresh order and an empty digest" "1 1" "$(ss_mem "$OC/sub" > "$T/ss.out"; grep -c "is behind your session log.*memory-prep prep $MR.*ONE Haiku" "$T/ss.out") $(grep -c '^### Ruled out' "$T/ss.out")"
check "a session elsewhere gets no memory" 0 "$(ss_mem "$T" | grep -c 'standing memory\|is behind')"
python3 "$R/bin/memory-prep" prep "$MR" > "$T/prep.out"
MB=$(sed -n 's/.*brief: //p' "$T/prep.out")
check "the first prep takes the thread's last 24 hours only, from the init session and the handed-off one" "1 1 0 0 0 1" "$(grep -c 'USER\] said in the session init ran in' "$MR/memory-new.txt") $(grep -c 'USER\] never use cron' "$MR/memory-new.txt") $(grep -c 'an old ruling' "$MR/memory-new.txt") $(grep -c "another thread" "$MR/memory-new.txt") $(grep -c "a child's brief" "$MR/memory-new.txt") $(grep -c 'skills/delegate/memory-refresh.md' "$MB")"
check "prep drops the harness's entries (skill bodies, hook feedback, summaries, notifications, T3's own) and repeats" "0 0 0 1 1" "$(grep -c 'harness entry\|Base directory' "$MR/memory-new.txt") $(grep -c 'Delegated task' "$MR/memory-new.txt") $(grep -c 'Context handoff' "$MR/memory-new.txt") $(grep -c 'RSC check-in' "$MR/memory-new.txt") $(grep -c '^\[20[0-9T:.-]*Z END\]' "$MR/memory-new.txt")"
UNTIL=$(sed -n 's/^\[\(.*\) END\].*/\1/p' "$MR/memory-new.txt")
echo "read-through: $UNTIL" >> "$MR/memory-notes.txt"
printf '# Memory\n## Standing\n### Rulings in force\n- **No cron** (now). "never use cron".\n### Ruled out\n- **Cron jobs** (now). The user refused them.\n### Superseded\n- **Day files → one memory file** (now).\n### Still intended\n- **Ship it** (now).\n## Recent\n- now: refreshed.\n<!-- covered-until: %s -->\n' "$UNTIL" > "$MR/memory.md"
check "fresh memory: no refresh order, the Standing digest without the Recent part" "0 1 1 0" "$(ss_mem "$OC" > "$T/ss.out"; grep -c 'is behind' "$T/ss.out") $(grep -c '^- \*\*Cron jobs\*\*' "$T/ss.out") $(grep -c 'Day files → one memory file' "$T/ss.out") $(grep -c 'refreshed' "$T/ss.out")"
sed -i '$d' "$MR/memory-notes.txt"
check "memory.md never counts as covered past the chunks its run noted" "1 1" "$(ss_mem "$OC" | grep -c 'is behind'; python3 "$R/bin/memory-prep" prep "$MR" >/dev/null) $(grep -c 'never use cron' "$MR/memory-new.txt")"
echo "read-through: $UNTIL" >> "$MR/memory-notes.txt"
mlog "$LD/a.jsonl" 0 "a new ruling"
check "a new log line makes it behind; prep then extracts only what follows the covered position" "1 1 0" "$(ss_mem "$OC" | grep -c 'is behind'; python3 "$R/bin/memory-prep" prep "$MR" >/dev/null) $(grep -c 'a new ruling' "$MR/memory-new.txt") $(grep -c 'never use cron' "$MR/memory-new.txt")"
alog() { python3 -c 'import json,sys,datetime as d; t=d.datetime.now(d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
open(sys.argv[1],"a").write(json.dumps({"type":"assistant","timestamp":t,"message":{"content":[{"type":"text","text":sys.argv[2]}],"stop_reason":(sys.argv[3:] or [None])[0]}},separators=(",",":"))+"\n")' "$@"; }
alog "$LD/a.jsonl" "narration before a tool call"; alog "$LD/a.jsonl" "the turn's answer"; mlog "$LD/a.jsonl" 0 "next prompt"; alog "$LD/a.jsonl" "the last turn's answer"
check "prep keeps only the last text of each assistant turn" "0 1 1" "$(python3 "$R/bin/memory-prep" prep "$MR" >/dev/null; grep -c 'narration before' "$MR/memory-new.txt") $(grep -c "ASSISTANT\] the turn's answer" "$MR/memory-new.txt") $(grep -c "the last turn's answer" "$MR/memory-new.txt")"
alog "$LD/a.jsonl" "COMPLETED_ONE" end_turn; alog "$LD/a.jsonl" "COMPLETED_TWO" end_turn  # a background notification woke the second turn: no prompt between
check "prep keeps each completed turn's answer, with no prompt between them" "1 1" "$(python3 "$R/bin/memory-prep" prep "$MR" >/dev/null; grep -c 'COMPLETED_ONE' "$MR/memory-new.txt") $(grep -c 'COMPLETED_TWO' "$MR/memory-new.txt")"
python3 - "$MR/memory.md" <<'EOF'
import sys
items = lambda k: ''.join(f'- **{k} item {i}** (2026-10-12 10:00Z). ' + 'A long standing line about the work. ' * 12 + '\n' for i in range(300))
open(sys.argv[1], 'w').write('# Memory\n## Standing\n' + ''.join(f'### {h}\n' + items(h) for h in ('Rulings in force', 'Ruled out', 'Superseded', 'Still intended')) + '## Recent\n<!-- covered-until: 2099-01-01T00:00:00.000Z -->\n')
EOF
check "the digest of a huge memory stays under the aim, one line per item" "yes 0" "$(n=$(python3 "$R/bin/memory-prep" digest "$MR" | wc -c); [ "$n" -le 6400 ] && echo yes || echo "no $n") $(python3 "$R/bin/memory-prep" digest "$MR" | awk 'length > 240' | wc -l)"
# Claude Code shows the model a 2 KB preview of a hook command's output over 10,000 characters: each SessionStart output stays under 9,000 bytes
cp "$R/tests/fixtures/memory.md" "$MR/memory.md"; touch -d '3 hours ago' "$MR/memory.md"; mlog "$LD/a.jsonl" 0 "after the fixture"
ss_all=$(CLAUDE_PLUGIN_ROOT="$R" bash "$R/hooks/session-start" </dev/null 2>/dev/null | wc -c); ss_m=$(ss_mem "$OC" | tee "$T/ss.out" | wc -c)
echo "measured with tests/fixtures/memory.md (a real memory.md, words hashed): session-start $ss_all bytes, session-memory $ss_m bytes"
check "each SessionStart output with a real-sized memory.md stays under 9,000 bytes; the order comes first, the digest after" "yes yes 1 1" "$([ "$ss_all" -le 9000 ] && echo yes) $([ "$ss_m" -le 9000 ] && echo yes) $(head -1 "$T/ss.out" | grep -c 'is behind') $(grep -c '^### Still intended' "$T/ss.out")"
python3 -c 'import json; print(json.dumps({"type":"user","message":{"content":"Please pause the work"}})); print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"Paused."}]}}))' > "$T/tr.jsonl"
rm -f "$MR/.memory-order-repeated"  # left by the prep runs above
check "the user's pause holds the refresh order too" "0 no" "$(stop "$OC") $([ -e "$MR/.memory-order-repeated" ] && echo yes || echo no)"
tr_file "Done."
check "BLOCK: memory.md behind, covering nothing of the last 2 hours: stop-lint repeats the refresh order, running beside the work, then not within the hour" "2 1 0 0" "$(stop "$OC") $(grep -c "is behind your session log.*memory-prep prep $MR.*keep working meanwhile" "$T/err") $(grep -c "without starting other work" "$T/err") $(stop "$OC")"
rm "$MR/.memory-order-repeated"
python3 "$R/bin/memory-prep" prep "$MR" > "$T/prep.out"; MB=$(sed -n 's/.*brief: //p' "$T/prep.out")
check "BLOCK: memory-prep prep wrote the brief but no agent runs it: stop-lint still repeats the order" 2 "$(stop "$OC")"
rm "$MR/.memory-order-repeated"
launch "Follow $MB exactly" >/dev/null
check "an agent launched on the brief holds the order" 0 "$(stop "$OC")"
rm "$MR/.memory-order-repeated"; python3 "$R/bin/agent-job" done "$MB" >/dev/null
python3 -c 'import json; print(json.dumps({"type":"user","message":{"content":"Act as the implementation sub-agent for this task. Fix it."}})); print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}))' > "$T/tr.jsonl"
check "a delegated sub-agent in the orchestrator's checkout never gets the order" 0 "$(stop "$OC")"
# a T3 child as T3 starts one: its prompt opens with the brief, no introduction; T3's state links its thread to the parent's
mkdir -p "$HOME/.t3/userdata"; python3 - "$HOME/.t3/userdata/statev2.sqlite" <<'EOF2'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute('create table orchestration_v2_projection_provider_threads (provider_thread_id text, thread_id text, payload_json text)')
c.execute('create table orchestration_v2_projection_subagents (subagent_id text, thread_id text, child_thread_id text)')
c.execute("""insert into orchestration_v2_projection_provider_threads values ('p1', 'thread:delegated-task:notes-1', '{"nativeThreadRef":{"driver":"claudeAgent","nativeId":"t3-child"}}')""")
c.execute("""insert into orchestration_v2_projection_provider_threads values ('p2', 'main-thread', '{"nativeThreadRef":{"driver":"claudeAgent","nativeId":"t3-main"}}')""")
c.execute("insert into orchestration_v2_projection_subagents values ('s1', 'main-thread', 'thread:delegated-task:notes-1')"); c.commit()
EOF2
python3 -c 'import json; w=lambda o: print(json.dumps(o,separators=(",",":"))); b="Goal: ~/.mergeworthy/projects/o/r.md exists: the project notes for o/r.\n\nFacts:\n- The study: /w/guide.md"
w({"type":"queue-operation","operation":"enqueue","sessionId":"t3-child","content":b})
w({"parentUuid":None,"attachment":{"type":"hook_success","hookName":"SessionStart:startup","content":"## Subagent models"},"type":"attachment","entrypoint":"sdk-ts"})
w({"type":"user","promptSource":"sdk","entrypoint":"sdk-ts","message":{"role":"user","content":b}})
w({"type":"assistant","entrypoint":"sdk-ts","message":{"content":[{"type":"text","text":"Notes written."}]}})' > "$T/tr.jsonl"
t3stop() { python3 -c 'import json,sys; print(json.dumps({"transcript_path":sys.argv[1],"cwd":sys.argv[2],"session_id":sys.argv[3]}))' "$T/tr.jsonl" "$OC" "$1" \
  | MERGEWORTHY_STOP_CHECKIN=off python3 "$R/hooks/stop-lint.py" 2>"$T/err"; echo $?; }
check "a T3 child whose prompt doesn't introduce it (T3's state gives it a parent thread) never gets the order; a top-level thread does" "0 2" "$(t3stop t3-child) $(t3stop t3-main)"
rm -f "$MR/.memory-order-repeated" "$HOME/.t3/userdata/statev2.sqlite"
if [ -d "${MW_REAL_DAYS:-/nonexistent}" ]; then  # local only: the real day files are private
  python3 - "$MR/memory.md" "$MW_REAL_DAYS"/2026-10-12.md "$MW_REAL_DAYS"/2026-10-11.md <<'EOF'
import re, sys
def sec(t, h):
    m = re.search(r'^## *(?:\d+\. *)?' + h + r'[^\n]*\n(.*?)(?=^## |\Z)', t, re.M | re.S | re.I); return m.group(1) if m else ''
days = [open(p).read() for p in sys.argv[2:]]
parts = {'Rulings in force': 'How the user wants', 'Ruled out': 'Ruled out', 'Superseded': 'How the plan changed', 'Still intended': 'Still intended'}
open(sys.argv[1], 'w').write('# Memory\n## Standing\n' + ''.join(f'### {k}\n' + ''.join(sec(d, v) for d in days) for k, v in parts.items()) + '## Recent\n<!-- covered-until: 2099-01-01T00:00:00.000Z -->\n')
EOF
  check "the digest of the real 2026-10-11/12 files stays under the hook output limit" yes "$(n=$(ss_mem "$OC" | wc -c); [ "$n" -le 9000 ] && echo yes || echo "no $n")"
fi
# pre-agent-dedupe: a brief pinned to an old commit of a linked worktree, and research the notes already cover
git init -q -b main "$T/gr"; git -C "$T/gr" commit -q --allow-empty -m one; OLD=$(git -C "$T/gr" rev-parse HEAD)
git -C "$T/gr" worktree add -q -b w "$T/gw"; git -C "$T/gw" commit -q --allow-empty -m two; NEW=$(git -C "$T/gw" rev-parse HEAD)
git -C "$T/gr" commit -q --allow-empty -m three; MAINOLD=$OLD
ag() { # cwd task [role]
  python3 -c 'import json,sys,time; print(json.dumps({"tool_name":"mcp__t3-code__delegate_task","cwd":sys.argv[1],"tool_input":{"task":sys.argv[2],"title":sys.argv[2][:50],"role":sys.argv[3],"clientRequestId":f"ag-{time.time_ns()}-r1"}}))' "$1" "$2" "${3:-implementation}" \
    | timeout 10 python3 "$R/hooks/pre-agent-dedupe.py" 2>"$T/err"; echo $?; }
printf '# Memory\n## Standing\n### Ruled out\n- **Cron jobs** (now). The user refused them.\n## Recent\n<!-- covered-until: 2099-01-01T00:00:00.000Z -->\n' > "$MR/memory.md"
check "BLOCK: a brief pinned to an older commit of the worktree it names, with the ruled-out list" "2 1" "$(ag "$OC" "Fix it in $T/gw at $OLD") $(grep -c 'Cron jobs' "$T/err")"
check "a brief pinned to the worktree's live head passes" 0 "$(ag "$OC" "Fix it again in $T/gw at $NEW, base $OLD")"
mkdir -p "$HOME/.mergeworthy/projects/o"; echo "- a lesson from $OLD" > "$HOME/.mergeworthy/projects/o/gwnotes.md"
check "a project notes file the brief names is read, not pinned: its history SHAs block nothing" 0 "$(ag "$OC" "Fix it in $T/gw; notes $HOME/.mergeworthy/projects/o/gwnotes.md")"
check "the user's own checkout is read at any commit" 0 "$(ag "$OC" "Read $T/gr at $MAINOLD once more")"
echo 'TanStack Start client CSS: answered here.' > "$MR/css-research.md"
check "BLOCK: a research brief with no Topic line" 2 "$(ag "$OC" 'Look into CSS' research)"
check "BLOCK: research the notes already cover, naming the file" "2 1" "$(ag "$OC" $'Look into CSS again\nTopic: tanstack client css' research) $(grep -c "$MR/css-research.md" "$T/err")"
check "research passes once each covering file is named as checked" 0 "$(ag "$OC" $'Look into CSS once more\nTopic: tanstack client css\nChecked: '"$MR/css-research.md"' covers dev only' research)"
check "research on a topic nothing covers passes" 0 "$(ag "$OC" $'Look into RSC\nTopic: flight streaming chunk order' research)"
printf '# Design\n\nThe flight protocol.\n\nStreaming is out of scope.\n\nChunk order: later.\n' > "$MR/flight-design.md"
check "a doc naming the topic's words only in separate paragraphs doesn't cover it" 0 "$(ag "$OC" $'Look into RSC\nTopic: flight streaming chunk order' research)"
rm "$MR/flight-design.md"
mkdir -p "$MR/flight"; printf 'Topic: flight streaming chunk order\nGoal: find it\n' > "$MR/flight/brief.md"
check "the brief being launched is not research that already covers its own topic" 0 "$(ag "$OC" "Follow $MR/flight/brief.md exactly" research)"
rm -r "$MR/flight"
# pre-agent-dedupe: a brief for a repo with maintainers' notes names the notes file
mkdir -p "$HOME/.mergeworthy/projects/o" "$T/oc"; printf -- '- a convention\n## Who decides\n- maint merges: ~/.mergeworthy/projects/o/r.study.md\n' > "$HOME/.mergeworthy/projects/o/r.md"
echo "Studied: $(date -u +%F)" > "$HOME/.mergeworthy/projects/o/r.study.md"
git init -q "$T/oc"; git -C "$T/oc" remote add origin https://github.com/o/r.git; mkdir -p "$T/oc/src"
check "BLOCK: a brief naming owner/repo without its notes file, printing the path" "2 1" "$(ag "$T" 'Fix o/r#5') $(grep -c "$HOME/.mergeworthy/projects/o/r.md" "$T/err")"
check "BLOCK: a brief naming a path in that repo's checkout" 2 "$(ag "$T" "Fix the bug in $T/oc/src")"
check "a brief with an https URL finishes (its //host is not a path), and the URL's owner/repo still counts" "2 0" "$(ag "$T" 'Fix https://github.com/o/r/pull/5') $(ag "$T" 'See https://example.com/a/b')"
git init -q "$HOME/occ"; git -C "$HOME/occ" remote add origin git@github.com:o/r.git; mkdir -p "$HOME/occ/src"
check "BLOCK: the repo as git@github.com:o/r.git, and a ~/ path in its checkout" "2 2" "$(ag "$T" 'Fix git@github.com:o/r.git') $(ag "$T" 'Fix the bug in ~/occ/src')"
check "a brief that writes nothing to the repo (role research or test) needs no notes; a review does" "0 0 2" "$(ag "$T" 'Mine session logs for o/r' research) $(ag "$T" 'Run the tests of o/r' test) $(ag "$T" 'Review o/r#7' review)"
check "a brief naming the notes file passes; one naming another repo or none passes; a memory-refresh brief passes" "0 0 0 0" "$(ag "$T" 'Fix o/r#5 by skills/code/SKILL.md, notes in ~/.mergeworthy/projects/o/r.md') $(ag "$T" 'Fix o/r-two#5') $(ag "$T" 'Tidy the README') $(ag "$T" 'Follow skills/delegate/memory-refresh.md on o/r#5 lines')"
printf -- '- a convention\n## Who decides\n- maint merges. Study: [r.study.md](r.study.md)\n' > "$HOME/.mergeworthy/projects/o/r.md"
check "a study linked relative to the project file counts" 0 "$(ag "$T" 'Fix o/r#5 by skills/code/SKILL.md, notes in ~/.mergeworthy/projects/o/r.md')"
printf -- '- a convention\n## Who decides\n- maint merges: ~/.mergeworthy/projects/o/r.study.md\n' > "$HOME/.mergeworthy/projects/o/r.md"
echo "Studied: 2026-01-01" > "$HOME/.mergeworthy/projects/o/r.study.md"
check "BLOCK: an implementer brief whose repo study is over 30 days old, or missing; research needs none" "2 1 2 0" "$(ag "$T" 'Fix o/r#5 by skills/code/SKILL.md, notes in ~/.mergeworthy/projects/o/r.md') $(grep -c 'write the repo study first' "$T/err") $(rm "$HOME/.mergeworthy/projects/o/r.study.md"; ag "$T" 'Fix o/r#5 by skills/code/SKILL.md, notes in ~/.mergeworthy/projects/o/r.md') $(ag "$T" 'Mine session logs for o/r' research)"
echo "Studied: $(date -u +%F)" > "$HOME/.mergeworthy/projects/o/r.study.md"
check "BLOCK: an implementation brief for that repo without code/SKILL.md, naming it" "2 1" "$(ag "$T" 'Build o/r#6 per ~/.mergeworthy/projects/o/r.md') $(grep -c 'skills/code/SKILL.md' "$T/err")"
check "a review brief needs no code/SKILL.md" 0 "$(ag "$T" 'Review o/r#8 per ~/.mergeworthy/projects/o/r.md' review)"
# the main session reads the code itself before briefing an implementer: a Read of a file in a checkout of that repo, in its transcript
RD="$T/x-work/rd"; git init -q "$RD"; git -C "$RD" remote add origin git@github.com:o/r.git; mkdir -p "$RD/src"; echo 'export {}' > "$RD/src/a.ts"; git -C "$RD" add src/a.ts; echo report > "$RD/verify.md"
agt() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"mcp__t3-code__delegate_task","cwd":sys.argv[1],"transcript_path":sys.argv[3],"tool_input":{"task":sys.argv[2],"title":sys.argv[2][:50],"role":"implementation"}}))' "$T" "$1" "$2" \
  | timeout 10 python3 "$R/hooks/pre-agent-dedupe.py" 2>"$T/err"; echo $?; }
now=$(date -u +%FT%T.000Z)
python3 -c 'import json,sys; print(json.dumps({"type":"assistant","timestamp":sys.argv[1],"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cat "+sys.argv[2]+"/verify.md; git -C "+sys.argv[2]+" status"}}]}}))' "$now" "$RD" > "$T/tr-noread.jsonl"
python3 -c 'import json,sys; print(json.dumps({"type":"assistant","timestamp":sys.argv[1],"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cd "+sys.argv[2]+" && sed -n 1,80p src/a.ts"}}]}}))' "$now" "$RD" > "$T/tr-sed.jsonl"
python3 -c 'import json,sys; print(json.dumps({"type":"assistant","timestamp":sys.argv[1],"message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":sys.argv[2]}}]}}))' "$now" "$RD/src/a.ts" > "$T/tr-read.jsonl"
B='Build o/r#9 by skills/code/SKILL.md per ~/.mergeworthy/projects/o/r.md'
check "BLOCK: an implementation brief whose session read only an agent's report in the checkout (in a work folder); a Read, or a cd + sed of a tracked source, passes" "2 1 0 0" "$(agt "$B" "$T/tr-noread.jsonl") $(grep -c 'read the code this change is about yourself' "$T/err") $(agt "$B" "$T/tr-read.jsonl") $(agt "$B" "$T/tr-sed.jsonl")"
python3 -c 'import json,sys; print(json.dumps({"type":"assistant","timestamp":sys.argv[1],"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":sys.argv[2]}}]}}))' "$now" "D=$RD; cd \"\$D\" && sed -n 1,80p src/a.ts" > "$T/tr-var.jsonl"
python3 -c 'import json,sys; print(json.dumps({"type":"assistant","timestamp":sys.argv[1],"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":sys.argv[2]}}]}}))' "$now" "D=$RD; git -C \"\$D\" show HEAD:src/a.ts" > "$T/tr-gshow.jsonl"
check "a read in a checkout named by a variable the command set (cd \"\$D\" && sed, git -C \"\$D\" show) passes too" "0 0" "$(agt "$B" "$T/tr-var.jsonl") $(agt "$B" "$T/tr-gshow.jsonl")"
check "BLOCK: a drafter brief (it reads thread-context.md) without writing/SKILL.md; with it, it passes" "2 0" "$(ag "$T" 'Draft the reply from /w/drafts/x/thread-context.md' review) $(ag "$T" 'Write a reply draft by skills/writing/SKILL.md from /w/drafts/y/thread-context.md; list each claim with a scope word beside its source' review)"
check "BLOCK: a drafter brief without the template's scope-word check, naming the template; a review of a draft (CLEAN) needs none" "2 1 0" "$(ag "$T" 'Write a reply draft by skills/writing/SKILL.md from /w/drafts/z/thread-context.md' review) $(grep -c 'delegate/drafter.md' "$T/err") $(ag "$T" 'Review /w/drafts/z/r.md against /w/drafts/z/thread-context.md by skills/writing/SKILL.md; final message CLEAN or findings' review)"
# pre-agent-dedupe: a template's placeholder left in the brief, by the plugin's own skills/delegate templates
check "BLOCK: a brief with a template's placeholder unfilled, naming it and its template" "2 1" "$(ag "$T" $'Verify the slice.\n- try the edges: <the slice\'s risky edges>, each Recurring misses line' review) $(grep -c "<the slice's risky edges> (delegate/verifier.md)" "$T/err")"
check "BLOCK: a slot of a template's code block indented in a list item (delegate/SKILL.md's reviewer launch)" "2 1" "$(ag "$T" $'Review the diff.\n{"target": {"options": {"<its effort option>": "high"}}}' review) $(grep -c '<its effort option> (delegate/SKILL.md)' "$T/err")"
check "a filled brief passes with the paste-in rules (their <work folder>), an output form in backticks and a quoted HTML tag" 0 "$(ag "$T" "$(printf 'Verify the slice: try the edges: the abort path.\nFinal message: the gates as `<command> -> exit <code>`; check the <head> tags.\n'; cat "$R/skills/delegate/agent.md")" review)"
check "a brief quoting a line format in backticks that holds a template's slot passes (a format, not a slot)" 0 "$(ag "$T" 'Check each `PROMISED <thread>: <what> (<draft>)` line in proposals-open.md.' review)"
mkdir -p "$T/mem"; printf 'Next: the brief may say (git show <sha>) in a quoted ruling.\n' > "$T/mem/memory.md"; printf 'Summarize %s into the digest.\n' "$T/mem/memory.md" > "$T/mem/memory-brief-1.md"
check "an input file the brief names (memory.md quoting <sha>) is not scanned for slots; the brief file still is" "0 2" "$(ag "$T" "Follow $T/mem/memory-brief-1.md" research) $(printf 'Sort it (git show <sha>).\n' > "$T/mem/sort-brief.md"; ag "$T" "Follow $T/mem/sort-brief.md" review)"
# pre-agent-dedupe: a worktree another agent still works in (its process's cwd, or its fresh transcript naming it)
git -C "$T/gr" worktree add -q -b a "$T/aw"; AD="$HOME/.claude/projects/-aw"; AS="$AD/sess/subagents"; mkdir -p "$AD" "$AS" "$T/aw/src"
alive() { # task [transcript_path]
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"mcp__t3-code__delegate_task","cwd":sys.argv[1],"transcript_path":sys.argv[3],"tool_input":{"task":sys.argv[2],"title":sys.argv[2][:50]}}))' "$OC" "$1" "${2:-}" \
    | python3 "$R/hooks/pre-agent-dedupe.py" 2>"$T/err"; echo $?; }
(cd "$T/aw/src" && exec sleep 600) & APID=$!; sleep 0.2
check "BLOCK: a process works in the worktree, naming its PID" "2 1" "$(alive "Run e2e in $T/aw/src") $(grep -c "$APID (sleep)" "$T/err")"
CUR=$(readlink "$HOME/.mergeworthy/current"); ln -sfn "$T/aw" "$HOME/.mergeworthy/current"; mkdir -p "$HOME/.mergeworthy/work"; ln -sfn "$T/aw" "$HOME/.mergeworthy/work/aw"
check "an installed skill or the installed folder is no worktree a brief names, though ~/.mergeworthy/current links to the busy one; a task's folder under ~/.mergeworthy/work is" "0 0 2" "$(alive 'Follow ~/.mergeworthy/current/skills/review/SKILL.md') $(alive 'Read the skills in ~/.mergeworthy/current.') $(alive 'Run e2e in ~/.mergeworthy/work/aw/src')"
rm "$HOME/.mergeworthy/work/aw"; ln -sfn "$CUR" "$HOME/.mergeworthy/current"
kill $APID; wait $APID 2>/dev/null
echo "{\"cwd\":\"$T/aw\"}" > "$AD/main-session.jsonl"
check "a main session's transcript naming the worktree (the steward's, say) doesn't make it busy" 0 "$(alive "Run e2e in $T/aw")"
rm -f "$AD/main-session.jsonl"; echo "{\"cwd\":\"$T/aw\"}" > "$AS/agent.jsonl"
check "BLOCK: an agent transcript written minutes ago names the worktree" "2 1" "$(alive "Run e2e in $T/aw") $(grep -c "$AS/agent.jsonl" "$T/err")"
echo "Prototype report: worktree $T/aw, branch a." > "$T/aw-report.md"; printf 'Goal: e2e green.\nWork in %s.\n' "$T/aw" | tee "$T/aw-job.md" > "$T/aw-brief.md"
check "a reference file the brief names whose text names the busy worktree passes; the brief file it says to follow, or named as a brief, blocks" "0 2 2" "$(alive "Summarize the prototype. Context: $T/aw-report.md (read first)") $(alive "Follow $T/aw-job.md exactly") $(alive "Topic: e2e. Its file: $T/aw-brief.md")"
check "the orchestrator's own transcript naming the worktree doesn't count" 0 "$(alive "Run e2e in $T/aw once more" "$AS/agent.jsonl")"
echo "{\"cwd\":\"$T/aw-r\"}" > "$AS/sibling.jsonl"; touch -d '10 minutes ago' "$AS/agent.jsonl"
check "a transcript naming a longer sibling path ($T/aw-r) doesn't make the worktree busy" 0 "$(alive "Run e2e in $T/aw yet again")"
rm -f "$AS/sibling.jsonl"; touch "$AS/agent.jsonl"
touch -d '10 minutes ago' "$AS/agent.jsonl"
check "a worktree with no process and only an old transcript passes" 0 "$(alive "Run e2e in $T/aw again")"
mkdir -p "$HOME/.t3/userdata"; python3 - "$HOME/.t3/userdata/statev2.sqlite" <<'EOF2'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute('create table orchestration_v2_projection_provider_threads (provider_thread_id text, thread_id text, payload_json text)')
c.execute('create table orchestration_v2_projection_subagents (subagent_id text, thread_id text, child_thread_id text, status text)')
c.execute('create table orchestration_v2_projection_runs (run_id text, thread_id text, status text)')
c.execute("""insert into orchestration_v2_projection_provider_threads values ('p1', 'review-1', '{"nativeThreadRef":{"driver":"claudeAgent","nativeId":"t3review"}}')""")
c.execute("insert into orchestration_v2_projection_subagents values ('s1', 'main-thread', 'review-1', 'completed')")
c.execute("insert into orchestration_v2_projection_runs values ('r1', 'review-1', 'completed')"); c.commit()
EOF2
echo "{\"cwd\":\"$T/aw\"}" > "$AD/t3review.jsonl"
check "a fresh transcript of a T3 task that completed, with no run pending, doesn't make the worktree busy" 0 "$(alive "Review round 2 in $T/aw")"
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("insert into orchestration_v2_projection_runs values (?, ?, ?)", ("r2", "review-1", "queued")); c.commit()' "$HOME/.t3/userdata/statev2.sqlite"
check "BLOCK: the same task woken again (a run queued)" 2 "$(alive "Review round 3 in $T/aw")"
rm -f "$AD/t3review.jsonl" "$HOME/.t3/userdata/statev2.sqlite"
# a finished agent is reported: the watcher's AGENT DONE once per finish, and stop-lint while its job is open
JD="$HOME/.claude/projects/-jobs"; WJ="$T/wj"; mkdir -p "$JD" "$WJ"; echo orch > "$WJ/session"
reg() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"mcp__t3-code__delegate_task","session_id":"orch","transcript_path":sys.argv[2],"tool_input":{"task":sys.argv[1],"title":sys.argv[1][:40]}}))' "$1" "$T/tr.jsonl" \
  | python3 "$R/hooks/pre-agent-dedupe.py" register; }
child_log() { # file brief minutes-ago last-entry(text|tool)
  python3 -c 'import json,sys; f,b,last=sys.argv[1],sys.argv[2],sys.argv[3]; w=lambda o: open(f,"a").write(json.dumps(o)+"\n")
w({"type":"user","promptSource":"sdk","message":{"role":"user","content":b}})
w({"type":"assistant","message":{"content":[{"type":"tool_use","id":"x","name":"Bash","input":{}}] if last=="tool" else [{"type":"text","text":"Report written."}]}})' "$1" "$2" "$4"
  touch -d "$3 minutes ago" "$1"; }
done_events() { GH_WATCH_ME=me python3 - "$R/watcher/gh-watch.py" "$WJ" <<'EOF2'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('ghw', sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.HERE = sys.argv[2]; m.agent_jobs_pass()
EOF2
}
reg "Execute $T/jobs/quiet-ticket.md exactly"; child_log "$JD/quiet.jsonl" "Execute $T/jobs/quiet-ticket.md exactly" 5 text
reg "Execute $T/jobs/busy-ticket.md exactly"; child_log "$JD/busy.jsonl" "Execute $T/jobs/busy-ticket.md exactly" 0 text
reg "Execute $T/jobs/tool-ticket.md exactly"; child_log "$JD/tool.jsonl" "Execute $T/jobs/tool-ticket.md exactly" 5 tool
codex_log() { # file brief minutes-ago last-event: a T3 Code Codex agent's transcript
  mkdir -p "$HOME/.codex/sessions/2026/10/14"; python3 -c 'import json,sys; f,b,last=sys.argv[1],sys.argv[2],sys.argv[3]; w=lambda o: open(f,"a").write(json.dumps(o)+"\n")
w({"type":"session_meta","payload":{"originator":"T3 Code"}})
w({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions"}]}})
w({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":b}]}})
w({"type":"event_msg","payload":{"type":last}})' "$HOME/.codex/sessions/2026/10/14/$1" "$2" "$4"
  touch -d "$3 minutes ago" "$HOME/.codex/sessions/2026/10/14/$1"; }
reg "Execute $T/jobs/codex-done.md exactly"; codex_log rollout-done.jsonl "Execute $T/jobs/codex-done.md exactly" 5 task_complete
reg "Execute $T/jobs/codex-run.md exactly"; codex_log rollout-run.jsonl "Execute $T/jobs/codex-run.md exactly" 5 agent_message
python3 -c 'import glob,json,os,time; [json.dump({**json.load(open(f)), "started": time.time() - 3600}, open(f + ".n", "w")) or os.replace(f + ".n", f) for f in glob.glob(os.path.expanduser("~/.claude/agent-jobs/*")) if "jobs/" in open(f).read()]'  # launched an hour ago
done_events > "$T/ev1"; done_events > "$T/ev2"
check "AGENT DONE for a Codex agent once its task completes, not while it runs" "1 0" "$(grep -c "AGENT DONE $T/jobs/codex-done.md" "$T/ev1") $(grep -c codex-run "$T/ev1")"
python3 "$R/bin/agent-job" done "$T/jobs/codex-done.md" >/dev/null; python3 "$R/bin/agent-job" done "$T/jobs/codex-run.md" >/dev/null
check "AGENT DONE for the quiet agent's job, once; not for an active one or one in a running tool call" "1 0 0 0" "$(grep -c "^### AGENT DONE $T/jobs/quiet-ticket.md Execute [^:]*: read its result (task_status / its report), then agent-job done '$T/jobs/quiet-ticket.md Execute [^']*'$" "$T/ev1") $(cat "$T/ev2" | wc -l) $(grep -c busy-ticket "$T/ev1") $(grep -c tool-ticket "$T/ev1")"
sj() { python3 -c 'import json,sys; print(json.dumps({"transcript_path":sys.argv[1],"cwd":sys.argv[2],"session_id":sys.argv[3]}))' "$T/tr.jsonl" "$T" "$1" \
  | MERGEWORTHY_STOP_CHECKIN=off python3 "$R/hooks/stop-lint.py" 2>"$T/err"; echo $?; }
tr_file 'Done.'
check "BLOCK: stop-lint while the launching session's finished job is open, naming it; another session passes" "2 1 0" "$(sj orch) $(grep -c "quiet-ticket.md" "$T/err") $(sj other)"
touch -d '30 minutes ago' "$JD/tool.jsonl"; python3 "$R/bin/agent-job" done "$T/jobs/quiet-ticket.md" >/dev/null
check "a released job is never reported again; a tool call quiet past ten minutes counts as finished" "0 1" "$(done_events > "$T/ev3"; grep -c quiet-ticket "$T/ev3") $(grep -c tool-ticket "$T/ev3")"
python3 "$R/bin/agent-job" done "$T/jobs/tool-ticket.md" >/dev/null; python3 "$R/bin/agent-job" done "$T/jobs/busy-ticket.md" >/dev/null
# an agent waiting for an agent it launched itself (a T3 child and its reviewer) hasn't finished until that one has
reg "Execute $T/jobs/parent-ticket.md exactly"; child_log "$JD/parent.jsonl" "Execute $T/jobs/parent-ticket.md exactly" 5 text
python3 -c 'import json,sys; print(json.dumps({"tool_name":"mcp__t3-code__delegate_task","session_id":"parent","transcript_path":sys.argv[2],"tool_input":{"task":sys.argv[1],"title":"grandchild"}}))' "Execute $T/jobs/grand-ticket.md exactly" "$JD/parent.jsonl" | python3 "$R/hooks/pre-agent-dedupe.py" register
child_log "$JD/grand.jsonl" "Execute $T/jobs/grand-ticket.md exactly" 0 text
python3 -c 'import glob,json,os,time; [json.dump({**json.load(open(f)), "started": time.time() - 3600}, open(f + ".n", "w")) or os.replace(f + ".n", f) for f in glob.glob(os.path.expanduser("~/.claude/agent-jobs/*")) if "-ticket.md" in open(f).read()]'
done_events > "$T/ev4"; touch -d '5 minutes ago' "$JD/grand.jsonl"; done_events > "$T/ev5"
check "a quiet agent whose own agent still runs is not done; it is once that one is" "0 1" "$(grep -c "AGENT DONE $T/jobs/parent-ticket.md" "$T/ev4") $(grep -c "AGENT DONE $T/jobs/parent-ticket.md" "$T/ev5")"
python3 "$R/bin/agent-job" done "$T/jobs/parent-ticket.md" >/dev/null; python3 "$R/bin/agent-job" done "$T/jobs/grand-ticket.md" >/dev/null
# a quiet agent whose T3 thread still has a run going (a turn waiting on a background command) hasn't finished either
mkdir -p "$HOME/.t3/userdata"; python3 - "$HOME/.t3/userdata/statev2.sqlite" <<'EOF2'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute('create table orchestration_v2_projection_provider_threads (provider_thread_id text, thread_id text, payload_json text)')
c.execute('create table orchestration_v2_projection_subagents (subagent_id text, thread_id text, child_thread_id text, status text)')
c.execute('create table orchestration_v2_projection_runs (run_id text, thread_id text, status text)')
c.execute("""insert into orchestration_v2_projection_provider_threads values ('p1', 'busy-1', '{"nativeThreadRef":{"driver":"claudeAgent","nativeId":"t3busy"}}')""")
c.execute("insert into orchestration_v2_projection_runs values ('r1', 'busy-1', 'waiting')"); c.commit()  # waiting on an approval: as active as running
EOF2
reg "Execute $T/jobs/t3busy-ticket.md exactly"; child_log "$JD/t3busy.jsonl" "Execute $T/jobs/t3busy-ticket.md exactly" 5 text
python3 -c 'import glob,json,os,time; [json.dump({**json.load(open(f)), "started": time.time() - 3600}, open(f + ".n", "w")) or os.replace(f + ".n", f) for f in glob.glob(os.path.expanduser("~/.claude/agent-jobs/*")) if "t3busy-ticket" in open(f).read()]'
t3db() { python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(sys.argv[2]); c.commit()' "$HOME/.t3/userdata/statev2.sqlite" "$1"; }
done_events > "$T/ev6"; t3db "update orchestration_v2_projection_runs set status = 'completed'"
t3db "insert into orchestration_v2_projection_subagents values ('s9', 'busy-1', 'child-9', 'pending')"; done_events > "$T/ev7"
t3db "update orchestration_v2_projection_subagents set status = 'completed' where subagent_id = 's9'"
t3db "insert into orchestration_v2_projection_subagents values ('s0', 'orch-1', 'busy-1', 'running')"; done_events > "$T/ev8"  # its own task: its turn ended, its background command runs
t3db "update orchestration_v2_projection_subagents set status = 'completed' where subagent_id = 's0'"
t3db "update orchestration_v2_projection_provider_threads set payload_json = json_set(payload_json, '$.pendingBackgroundTasks', json('[{\"taskId\":\"b1\",\"kind\":\"command\"}]'))"; done_events > "$T/ev8b"  # its task completed, its background all.sh runs: T3's waiting_for_children
t3db "update orchestration_v2_projection_provider_threads set payload_json = json_set(payload_json, '$.pendingBackgroundTasks', json('[]'))"; done_events > "$T/ev9"
check "a quiet agent whose T3 run is still active (waiting), whose delegated task is (pending), whose own task is (running), or whose background command runs, is not done; it is once all ended" "0 0 0 0 1" "$(grep -c "AGENT DONE $T/jobs/t3busy-ticket.md" "$T/ev6") $(grep -c "AGENT DONE $T/jobs/t3busy-ticket.md" "$T/ev7") $(grep -c "AGENT DONE $T/jobs/t3busy-ticket.md" "$T/ev8") $(grep -c "AGENT DONE $T/jobs/t3busy-ticket.md" "$T/ev8b") $(grep -c "AGENT DONE $T/jobs/t3busy-ticket.md" "$T/ev9")"
# the watcher asks T3's state on every tick for days: each lookup closes its connection, not the cycle collector
check "T3 state lookups leave no connection open" 0 "$(python3 -c '
import gc, os, sys; sys.path.insert(0, sys.argv[1]); import steward; gc.disable()
for _ in range(40): steward.busy("t3busy"); steward.task_done("t3busy"); steward.is_task("t3busy"); steward.threads("t3busy"); steward.busy("nobody")
def name(f):
    try: return os.readlink("/proc/self/fd/" + f)
    except OSError: return ""
print(sum("statev2" in name(f) for f in os.listdir("/proc/self/fd")))' "$R/hooks")"
t3db "insert into orchestration_v2_projection_runs values ('r3', 'busy-1', 'running')"  # woken again: its next turn runs
check "BLOCK: agent-job done while the ticket's agent is still at work keeps the job, pointing at AGENT DONE" "1 1 1" \
  "$(python3 "$R/bin/agent-job" done "$T/jobs/t3busy-ticket.md" >/dev/null 2>"$T/aj.err"; echo $?) $(grep -c 'AGENT DONE. wakes this session' "$T/aj.err") $(python3 "$R/bin/agent-job" list | grep -c t3busy-ticket)"
t3db "update orchestration_v2_projection_runs set status = 'completed' where run_id = 'r3'"
check "agent-job done releases it once the agent has ended" "0 0" "$(python3 "$R/bin/agent-job" done "$T/jobs/t3busy-ticket.md" >/dev/null; echo $?) $(python3 "$R/bin/agent-job" list | grep -c t3busy-ticket)"
# a T3 Codex agent: T3 names it by its rollout's session_meta id, not the file's name
CX=0aa0c0de-1111-7222-8333-444455556666; CXF="$HOME/.codex/sessions/2026/10/14/rollout-2026-10-14T10-00-00-$CX.jsonl"
python3 -c 'import json,sys; f,cx,b=sys.argv[1:]; w=lambda o: open(f,"a").write(json.dumps(o)+"\n")
w({"type":"session_meta","payload":{"id":cx,"originator":"T3 Code"}})
w({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":b}]}})
w({"type":"event_msg","payload":{"type":"task_complete"}})' "$CXF" "$CX" "Execute $T/jobs/cx-ticket.md exactly"
reg "Execute $T/jobs/cx-ticket.md exactly"; touch -d '5 minutes ago' "$CXF"
python3 -c 'import glob,json,os,time; [json.dump({**json.load(open(f)), "started": time.time() - 3600}, open(f + ".n", "w")) or os.replace(f + ".n", f) for f in glob.glob(os.path.expanduser("~/.claude/agent-jobs/*")) if "cx-ticket" in open(f).read()]'
t3db "insert into orchestration_v2_projection_provider_threads values ('p3', 'codex-1', '{\"nativeThreadRef\":{\"driver\":\"codex\",\"nativeId\":\"$CX\"}}')"
t3db "insert into orchestration_v2_projection_runs values ('r4', 'codex-1', 'running')"
done_events > "$T/ev10"; tr_file 'Done.'
check "a running T3 Codex agent is not done: no AGENT DONE, stop-lint passes, agent-job done keeps its job" "0 0 1" \
  "$(grep -c "AGENT DONE $T/jobs/cx-ticket.md" "$T/ev10") $(sj orch) $(python3 "$R/bin/agent-job" done "$T/jobs/cx-ticket.md" >/dev/null 2>&1; echo $?)"
t3db "update orchestration_v2_projection_runs set status = 'completed' where run_id = 'r4'"; done_events > "$T/ev11"
check "once its run ended: AGENT DONE, stop-lint names it, agent-job done releases it" "1 2 1 0" \
  "$(grep -c "AGENT DONE $T/jobs/cx-ticket.md" "$T/ev11") $(sj orch) $(grep -c cx-ticket "$T/err") $(python3 "$R/bin/agent-job" done "$T/jobs/cx-ticket.md" >/dev/null; echo $?)"
rm -f "$HOME/.t3/userdata/statev2.sqlite"
# a job launched by another watch dir's declared session goes to that dir, though its launcher's transcript names this one's events.log
WS="$T/ws"; mkdir -p "$WS"; echo stew > "$WS/session"; echo $$ > "$WS/gh-watch.pid"; printf '%s\n' "$WS" >> "$HOME/.claude/gh-watch-dirs.txt"
for i in 1 2 3; do echo "tail $WJ/events.log" >> "$T/stew-tr.jsonl"; done
python3 -c 'import json,sys; print(json.dumps({"tool_name":"mcp__t3-code__delegate_task","session_id":"stew","transcript_path":sys.argv[2],"tool_input":{"task":sys.argv[1],"title":"stew job"}}))' "Execute $T/jobs/stew-ticket.md exactly" "$T/stew-tr.jsonl" | python3 "$R/hooks/pre-agent-dedupe.py" register
child_log "$JD/stew.jsonl" "Execute $T/jobs/stew-ticket.md exactly" 5 text
python3 -c 'import glob,json,os,time; [json.dump({**json.load(open(f)), "started": time.time() - 3600}, open(f + ".n", "w")) or os.replace(f + ".n", f) for f in glob.glob(os.path.expanduser("~/.claude/agent-jobs/*")) if "stew-ticket" in open(f).read()]'
check "a job of another live watch dir's declared session is not reported here" 0 "$(done_events > "$T/ev4"; grep -c stew-ticket "$T/ev4")"
python3 "$R/bin/agent-job" done "$T/jobs/stew-ticket.md" >/dev/null
check "stop-lint passes once every finished job is released" 0 "$(sj orch)"
reg "Execute $T/jobs/routed-ticket.md exactly"; child_log "$JD/routed.jsonl" "Execute $T/jobs/routed-ticket.md exactly" 5 text
python3 -c 'import glob,json,os,time; [json.dump({**json.load(open(f)), "started": time.time() - 3600}, open(f, "w")) for f in glob.glob(os.path.expanduser("~/.claude/agent-jobs/*")) if "routed-ticket" in open(f).read()]'
mkdir -p "$T/wj2"; rm "$WJ/session"; printf 'tail -F %s/events.log\nps: watcher for %s/events.log\ntail -F %s/events.log\n' "$T/wj2" "$WJ" "$T/wj2" > "$T/tr.jsonl"
check "a watch dir with no session file gets the event when the launcher's transcript names its events.log most; another it names once doesn't" "0 1" "$(done_events | wc -l) $(WJ="$T/wj2" done_events | grep -c routed-ticket)"
for t in old listed; do python3 -c 'import json,os,sys,time,hashlib; json.dump({"key":sys.argv[1],"started":time.time()-3600},open(os.path.expanduser("~/.claude/agent-jobs/")+hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16],"w"))' "$T/jobs/$t-ticket.md"
  child_log "$JD/$t.jsonl" "Execute $T/jobs/$t-ticket.md exactly" 5 text; done  # registered by an older hook: key and start only
python3 -c 'import json,sys; t,wj=sys.argv[1],sys.argv[2]; w=lambda f,o: open(f,"a").write(json.dumps(o)+"\n")
w(t+"/home/.claude/projects/-jobs/launcher.jsonl",{"type":"assistant","message":{"content":[{"type":"tool_use","id":"l","name":"mcp__t3-code__delegate_task","input":{"task":f"Execute {t}/jobs/old-ticket.md exactly"}}]}})
for f in ("launcher","lister"): w(f"{t}/home/.claude/projects/-jobs/{f}.jsonl",{"type":"user","message":{"content":f"tail -F {wj}/events.log; cat {t}/jobs/listed-ticket.md"}})' "$T" "$T/wj2"
check "an older hook's job (key and start only) is reported to the watch dir its launch call's session tails; a session that only names it isn't a launcher" "1 0" "$(WJ="$T/wj2" done_events > "$T/ev4"; grep -c old-ticket "$T/ev4") $(grep -c listed-ticket "$T/ev4")"
# stop-lint: a Running list is read live from T3 and names no finished task
rl_tr() { # final-text then status events: status:<s> (a task_status read) | user
  python3 - "$T/tr.jsonl" "$@" <<'EOF'
import json, sys
f, text, *ev = sys.argv[1:]; out = open(f, 'w'); w = lambda o: out.write(json.dumps(o) + '\n'); n = [0]
def res(name, st, title='', tid='loop-a-1'):
    n[0] += 1; i = f'tu{n[0]}'
    w({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": i, "name": f"mcp__t3-code__{name}", "input": {"title": title, "taskId": "x"}}]}})
    w({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": i, "content": json.dumps({"taskId": "node:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3A" + tid, "status": st})}]}})
w({"type": "user", "message": {"content": "run loop A"}}); res('delegate_task', 'running', 'Loop A')
for e in ev:
    if e == 'user': w({"type": "user", "message": {"content": "status?"}})
    elif e == 'notice': w({"type": "user", "message": {"content": "Delegated task node:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Aloop-a-1 reached a terminal state. Use task_status"}})
    elif e == 'relaunch': res('delegate_task', 'running', 'Loop A', 'loop-a-2')
    elif e == 'round2': res('delegate_task', 'running', 'Loop A round 2', 'loop-a-r2')
    elif e == 'followup':  # a message sent to the finished Loop A's thread: a new task of that thread
        n[0] += 1; w({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "f1", "name": "mcp__t3-code__task_status", "input": {}}]}})
        w({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "f1", "content": json.dumps({"taskId": "node:delegated-task:command%3Amcp%3Aabc%3Athread-send%3Aloop-a-1-r2", "childThreadId": "thread:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Aloop-a-1", "status": "running"})}]}})
    elif e == 'send':  # t3_thread_send to the finished Loop A's thread: it runs again
        w({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "s1", "name": "mcp__t3-code__t3_thread_send", "input": {}}]}})
        w({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "s1", "content": json.dumps({"threadId": "thread:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Aloop-a-1"})}]}})
    elif e == 'queue':  # t3_thread_send in queue mode: a new task of that thread, named by threadId, not childThreadId
        w({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "q1", "name": "mcp__t3-code__t3_thread_send", "input": {}}]}})
        w({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "q1", "content": json.dumps({"threadId": "thread:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Aloop-a-1", "taskId": "node:delegated-task:command%3Amcp%3Aabc%3Athread-send%3A5676", "status": "running"})}]}})
    elif e == 'continued': w({"type": "user", "message": {"content": "Delegated task node:delegated-task:provider-continuation%3Amessage%3Athread%3Athread%253Adelegated-task%253Acommand%25253Amcp%25253Aabc%25253Adelegate-task%25253Aloop-a-1%3Aordinal%3A1%3Aff (Loop A) [completed]: The e2e lanes are still running; I'll continue when they finish."}})
    elif e == 'feedback': w({"type": "user", "message": {"content": "Stop hook feedback: [stop-lint.py]: check once"}})
    elif e == 'other': w({"type": "user", "message": {"content": "Delegated task node:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Aother-9 reached a terminal state."}})
    elif e == 'waiting': w({"type": "user", "message": {"content": "Delegated task node:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Aloop-a-1 (Loop A) [completed]: The gates are still running; I'll continue when they finish."}})
    elif e == 'other2': w({"type": "user", "message": {"content": "Delegated task node:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Aother-9 (Review round 2) [completed]:\nCLEAN"}})
    else: res('task_status', e.split(':')[1])
w({"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}})
EOF
}
rl_tr $'Done for now.\n\nRunning:\n- Loop A on the head' user; check "BLOCK: a Running list not read from T3 since the user's last message" 2 "$(stop "$T")"
rl_tr $'Done for now.\n\nRunning:\n- Loop A on the head' user status:completed; check "BLOCK: a Running list naming a completed task" 2 "$(stop "$T")"
rl_tr $'Done for now.\n\n**Running:**\n- loop-a-1, the bug hunt' user status:failed; check "BLOCK: matched by its request id too" 2 "$(stop "$T")"
rl_tr $'Done for now.\n\nRunning:\n- Loop A on the head' user status:running; check "a Running list read live, its task still running, passes" 0 "$(stop "$T")"
rl_tr $'Done for now.\n\nRunning:\n- Loop A on the head' user status:running other; check "another task's T3 completion notice is not the user: a list read live before it passes" 0 "$(stop "$T")"
rl_tr $'Done for now.\n\nRunning:\n- Loop A on the head' user status:running notice; check "BLOCK: a Running list naming the task whose completion notice came in" 2 "$(stop "$T")"
rl_tr $'Started Loop A.

Running:
- Loop A on the head'; check "a task launched since the user's last message needs no read: its Running list passes (the vike-react-rsc handoff session, 305 blocks)" 0 "$(stop "$T")"
rl_tr $'Done for now.

Running:
- Loop A on the head' user status:running feedback; check "a stop hook's feedback is not the user: a list read before it passes" 0 "$(stop "$T")"
rl_tr $'Started Loop A again.

Running:
- Loop A on the new head' user notice relaunch; check "a title names its latest task: an earlier finished task of the same title isn't listed" 0 "$(stop "$T")"
rl_tr $'Done for now.\n\nRunning:\n- Loop A on the head' user status:running other2; check "T3's newer notice (\`Delegated task <id> (<title>) [completed]:\`) is not the user either (the handoff session's 305 blocks)" 0 "$(stop "$T")"
rl_tr $'Started round 2.\n\nRunning:\n- Loop A round 2' user notice round2; check "a title names the latest task whose title holds it: round 2 of a finished Loop A is running" 0 "$(stop "$T")"
rl_tr $'Sent round 2 to it.\n\nRunning:\n- [Loop A](t3-thread://v1/thread:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Aloop-a-1)' user notice followup; check "a link to a thread names its latest task: a follow-up sent to a finished task's thread is running" 0 "$(stop "$T")"
rl_tr $'Asked it for its report.\n\nRunning:\n- [Loop A](t3-thread://v1/thread:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Aloop-a-1)' user notice send; check "a message sent to a finished task's thread with t3_thread_send runs it again: its Running list passes" 0 "$(stop "$T")"
rl_tr $'Queued a message for it.

Running:
- [Loop A](t3-thread://v1/thread:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Aloop-a-1)' user notice queue; check "a message queued to a finished task's thread is a new task of that thread: its Running list passes" 0 "$(stop "$T")"
rl_tr $'Done for now.

Running:
- Loop A on the head' user status:running waiting; check "a sub-agent whose turn ended while its gates still run (T3 says completed, it says it continues) is still running" 0 "$(stop "$T")"
rl_tr $'Done for now.\n\nRunning:\n- [Loop A](t3-thread://v1/thread:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Aloop-a-1) (e2e gates)' user status:running notice continued status:completed; check "a thread T3 continued on its own, waiting on its gates, is running even after a read of its first task says completed" 0 "$(stop "$T")"
rl_tr 'Running the tests found nothing.' user; check "a sentence starting with Running is no Running list" 0 "$(stop "$T")"
rl_tr $'The example is:\n\n- ```text\n  example output\n  ```\n\nRunning:\n- Loop A\n\nTo reproduce:\n```sh\npnpm test\n```' user status:completed; check "BLOCK: a Running list between two code examples still counts" 2 "$(stop "$T")"
# stop-lint: a message opening with "done" names no linked PR or MR that is still a draft or not green
cat > "$T/bin/glab" <<'EOF2'
#!/usr/bin/env bash
[ "$1" = api ] && [ "$2" = --hostname ] || exit 1
f="$FX/$(printf '%s' "$4" | tr '/?&=' '____')"; [ -f "$f" ] && cat "$f" || exit 1
EOF2
chmod +x "$T/bin/glab"
echo '{"state":"open","draft":false,"head":{"sha":"h1"}}' > "$FX/repos_o_r_pulls_7"
echo '{"check_runs":[{"name":"test","conclusion":"success"}]}' > "$FX/repos_o_r_commits_h1_check-runs"
echo '{"state":"opened","draft":true,"head_pipeline":{"status":"failed"}}' > "$FX/projects_g%2Fp_merge_requests_96"
tr_file 'The work is done: https://github.com/o/r/pull/7 and https://gitlab.com/g/p/-/merge_requests/96'
check "BLOCK: a done message linking a draft MR with a failed pipeline, naming it and not the green PR" "2 1 0" "$(stop "$T") $(grep -c 'merge_requests/96 (draft, pipeline failed)' "$T/err") $(grep -c 'pull/7' "$T/err")"
tr_file 'A #184 munkája elkészült: https://gitlab.com/g/p/-/merge_requests/96'
check "BLOCK: the same in Hungarian" 2 "$(stop "$T")"
tr_file 'The work is done: https://github.com/o/r/pull/7'
check "a done message whose linked PR is ready and green passes" 0 "$(stop "$T")"
tr_file 'It is not done: https://gitlab.com/g/p/-/merge_requests/96 still needs green CI.'
check "a message saying it is not done passes" 0 "$(stop "$T")"
tr_file 'Ezek nincsenek még kész: https://gitlab.com/g/p/-/merge_requests/96'; a=$(stop "$T")
tr_file "It isn't ready for review: https://gitlab.com/g/p/-/merge_requests/96 still needs green CI."
check "a done word negated in Hungarian or English is no claim" "0 0" "$a $(stop "$T")"
tr_file 'It is not quite yet ready for review: https://gitlab.com/g/p/-/merge_requests/96'; a=$(stop "$T")
tr_file 'Once it is ready for review, I will send https://gitlab.com/g/p/-/merge_requests/96'; a="$a $(stop "$T")"
tr_file 'Amint kész, szólok: https://gitlab.com/g/p/-/merge_requests/96'; a="$a $(stop "$T")"
tr_file 'A review-ig kész lesz: https://gitlab.com/g/p/-/merge_requests/96'
check "a negation, condition or plan anywhere earlier in the done word's clause is no claim" "0 0 0 0" "$a $(stop "$T")"
tr_file 'It will be ready for review tomorrow: https://gitlab.com/g/p/-/merge_requests/96'; a=$(stop "$T")
tr_file 'Kész lesz délre: https://gitlab.com/g/p/-/merge_requests/96'; a="$a $(stop "$T")"
tr_file 'Majd kész, ha átment a CI: https://gitlab.com/g/p/-/merge_requests/96'
check "a future anywhere in the done word's clause is no claim" "0 0 0" "$a $(stop "$T")"
tr_file 'It would be ready for review if CI passed: https://gitlab.com/g/p/-/merge_requests/96'; a=$(stop "$T")
tr_file 'It would be ready for review with green CI: https://gitlab.com/g/p/-/merge_requests/96'; a="$a $(stop "$T")"
tr_file 'Kész lenne, ha zöld a CI: https://gitlab.com/g/p/-/merge_requests/96'
check "a conditional in the done word's clause is no claim" "0 0 0" "$a $(stop "$T")"
a=; for m in 'Egyik MR sem kész: mindháromnál a CI hiányzik. https://gitlab.com/g/p/-/merge_requests/96' 'Semmi sincs kész: https://gitlab.com/g/p/-/merge_requests/96' \
             'Nothing is done yet: https://gitlab.com/g/p/-/merge_requests/96' 'None of them is ready for review: https://gitlab.com/g/p/-/merge_requests/96'; do tr_file "$m"; a="$a $(stop "$T")"; done
check "a done word under sem, sincs, semmi, nothing or none is no claim" " 0 0 0 0" "$a"
tr_file 'Kész még nem vagyok: https://gitlab.com/g/p/-/merge_requests/96'; a=$(stop "$T")
tr_file 'Kész sem vagyok még: https://gitlab.com/g/p/-/merge_requests/96'
check "a Hungarian negation after the done word is no claim either" "0 0" "$a $(stop "$T")"
tr_file 'It is ready for review if CI passes: https://gitlab.com/g/p/-/merge_requests/96'; a=$(stop "$T")
tr_file 'Kész, ha zöld a CI: https://gitlab.com/g/p/-/merge_requests/96'
check "a condition after the done word in its part is no claim; one opening the next part leaves it standing" "0 2" "$a $(stop "$T")"
tr_file 'All done, if you have questions I can explain: https://gitlab.com/g/p/-/merge_requests/96'; a=$(stop "$T")
tr_file 'All done as expected: https://gitlab.com/g/p/-/merge_requests/96'
check "BLOCK: an offer's condition or an expectation after the done word leaves it standing" "2 2" "$a $(stop "$T")"
tr_file 'Kész van? https://gitlab.com/g/p/-/merge_requests/96'; a=$(stop "$T")
tr_file 'All done, any questions? https://gitlab.com/g/p/-/merge_requests/96'
check "BLOCK: a question still claims, as on main" "2 2" "$a $(stop "$T")"
tr_file 'All done after I fixed the tests: https://gitlab.com/g/p/-/merge_requests/96'
check "BLOCK: a time word after the done word is past work, not a condition" 2 "$(stop "$T")"
tr_file 'The tests are not flaky and the work is done: https://gitlab.com/g/p/-/merge_requests/96'; a=$(stop "$T")
tr_file 'A tesztek nem instabilak és kész a munka: https://gitlab.com/g/p/-/merge_requests/96'
check "BLOCK: a negation in an earlier coordinated clause leaves the claim standing" "2 2" "$a $(stop "$T")"
tr_file 'It is ready for review with no issues: https://gitlab.com/g/p/-/merge_requests/96'; a=$(stop "$T")
tr_file 'Kész, nincs több teendő: https://gitlab.com/g/p/-/merge_requests/96'
check "BLOCK: a negation after the done word doesn't take the claim back" "2 2" "$a $(stop "$T")"
tr_file 'When you asked, I checked it: all done, https://gitlab.com/g/p/-/merge_requests/96'
check "BLOCK: a condition in an earlier clause leaves the claim standing" 2 "$(stop "$T")"
tr_file $'> Earlier context.\n\nAll done: https://gitlab.com/g/p/-/merge_requests/96'
check "BLOCK: a claim after a quoted line" 2 "$(stop "$T")"
tr_file 'A „kész” jelzés még a régi futásé: https://gitlab.com/g/p/-/merge_requests/96'; a=$(stop "$T")
tr_file 'The `ready for review` step comes next: https://gitlab.com/g/p/-/merge_requests/96'
check "a done word in quotes or code is no claim" "0 0" "$a $(stop "$T")"
echo '{"state":"open","draft":true,"head":{"sha":"h8"}}' > "$FX/repos_o_r_pulls_8"
echo '{"check_runs":[{"name":"test","conclusion":"success"}]}' > "$FX/repos_o_r_commits_h8_check-runs"
tr_file $'A https://github.com/o/r/pull/7 már ready for review állapotban van.\n\nA https://github.com/o/r/pull/8 még vázlat.'
check "a claim about one PR is checked against that PR, not another linked draft" 0 "$(stop "$T")"
tr_file $'Ezek vannak még hátra:\n- https://github.com/o/r/pull/8 (vázlat):\n  1. a kész állapotú leírás átnézése.'
check "a done word past the opening sentence is no claim" 0 "$(stop "$T")"
tr_file 'All done: https://github.com/o/r/pull/8 is up.'
check "BLOCK: a claim about a draft PR" "2 1" "$(stop "$T") $(grep -c 'pull/8 (draft)' "$T/err")"
tr_file $'All done.\n\nhttps://github.com/o/r/pull/8 needs a look.'
check "BLOCK: an opening sentence calling the work done, naming no PR, is about every linked PR" 2 "$(stop "$T")"
echo '{"check_runs":[{"name":"test","conclusion":null}]}' > "$FX/repos_o_r_commits_h1_check-runs"
tr_file 'All done, https://github.com/o/r/pull/7 is ready for review.'
check "BLOCK: a PR whose checks are still running" 2 "$(stop "$T")"
check "agent-job lists jobs with the id file present" 0 "$(python3 "$R/bin/agent-job" list >/dev/null 2>&1; echo $?)"
# a gate review starts only on a draft that passed post-lint in its current form
mkdir -p "$T/drafts/lf"; printf 'Fixed in abc1234.\n' > "$T/drafts/lf/reply.md"
printf 'Review %s and write the verdict to %s/drafts/lf/r.out; the last message is exactly CLEAN.\n' "$T/drafts/lf/reply.md" "$T" > "$T/drafts/lf/review-ticket.md"
check "BLOCK: a review of a draft with no post-lint record" 2 "$(launch "Execute $T/drafts/lf/review-ticket.md")"
printf 'x' > "$T/drafts/lf/reply.md.lint.sha"
check "BLOCK: a review of a draft with a stale post-lint record" 2 "$(launch "Execute $T/drafts/lf/review-ticket.md")"
python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest(), end="")' "$T/drafts/lf/reply.md" > "$T/drafts/lf/reply.md.lint.sha"
check "a review of a draft with a current post-lint record launches" 0 "$(launch "Execute $T/drafts/lf/review-ticket.md")"
python3 "$R/bin/agent-job" done "$T/drafts/lf/review-ticket.md" >/dev/null
cp "$T/drafts/lf/review-ticket.md" "$T/drafts/lf/review-brief.md"
check "a review brief kept in drafts/ is not itself a draft needing post-lint" 0 "$(launch "Execute $T/drafts/lf/review-brief.md")"
python3 "$R/bin/agent-job" done "$T/drafts/lf/review-brief.md" >/dev/null
printf 'thread' > "$T/drafts/lf/thread-context.md"
printf 'Check %s against %s by skills/writing/SKILL.md; write CLEAN or findings to %s/drafts/lf/reply.review.out.\n' "$T/drafts/lf/reply.md" "$T/drafts/lf/thread-context.md" "$T" > "$T/drafts/lf/check-r1.md"
check "a review naming <name>.review.out checks only <name>.md, not the thread record beside it" 0 "$(launch "Execute $T/drafts/lf/check-r1.md")"
python3 "$R/bin/agent-job" done "$T/drafts/lf/check-r1.md" >/dev/null
printf 'x' >> "$T/drafts/lf/reply.md"
check "BLOCK: that review once <name>.md changed after its lint" 2 "$(launch "Execute $T/drafts/lf/check-r1.md")"
python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest(), end="")' "$T/drafts/lf/reply.md" > "$T/drafts/lf/reply.md.lint.sha"
echo 'edited' >> "$T/drafts/lf/reply.md"
check "BLOCK: the same review after the draft was edited" 2 "$(launch "Execute $T/drafts/lf/review-ticket.md")"
python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest(), end="")' "$T/drafts/lf/reply.md" > "$T/drafts/lf/reply.md.lint.sha"
printf 'Evidence.\n' > "$T/drafts/lf/research.md"
printf 'Review %s against the evidence in %s, write the verdict to %s/drafts/lf/r2.out; the last message is exactly CLEAN.\n' "$T/drafts/lf/reply.md" "$T/drafts/lf/research.md" "$T" > "$T/drafts/lf/review2-ticket.md"
check "the evidence file a review names is not a draft" 0 "$(launch "Execute $T/drafts/lf/review2-ticket.md")"
printf 'Live text.\n' > "$T/drafts/lf/reply.current.md"
printf 'Review %s against the live %s, write the verdict to %s/drafts/lf/r3.out; the last message is exactly CLEAN.\n' "$T/drafts/lf/reply.md" "$T/drafts/lf/reply.current.md" "$T" > "$T/drafts/lf/review3-ticket.md"
check "the live copy of an edited post is not a draft" 0 "$(launch "Execute $T/drafts/lf/review3-ticket.md")"
printf 'Findings.\n' > "$T/drafts/lf/fresh.report.md"
printf 'Review %s and write your report to %s, the verdict to %s/drafts/lf/r4.out; the last message is exactly CLEAN.\n' "$T/drafts/lf/reply.md" "$T/drafts/lf/fresh.report.md" "$T" > "$T/drafts/lf/review4-ticket.md"
check "a reviewer's report in drafts/ is not a draft" 0 "$(launch "Execute $T/drafts/lf/review4-ticket.md")"
# ---------- pr-steps: a shape record is a real pass ----------
G="$T/prs"; mkdir -p "$G"; git -C "$G" init -q; git -C "$G" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a
prs() { (cd "$G" && bash "$R/bin/pr-steps" "$@" >/dev/null 2>&1; echo $?); }
printf '# Loop B fix log\nfixed the README\n' > "$T/fixlog.md"
std() { for f in "$@"; do { echo '## Standards read'; bash "$R/bin/pr-steps" standards; echo '## Report'; cat "$f"; } > "$f.s" && mv "$f.s" "$f"; done; }
printf '\n\n' > "$T/blank.md"; check "BLOCK: an output of blank lines, saying what it lacks" 1 "$(cd "$G" && bash "$R/bin/pr-steps" verify "$T/blank.md" 2>&1 | grep -c 'does not end with a line NO BUGS')"
check "BLOCK: a fix log recorded as the shape pass, saying what a pass needs" "1 1" "$(prs shape "$T/fixlog.md") $(cd "$G" && bash "$R/bin/pr-steps" shape "$T/fixlog.md" 2>&1 | grep -c "lacks the ✅ coverage list")"
# a ratings report in the form a session wrote for #3609 (one rating per item, a summary of the changed ones, no ✅ list) is told all it lacks
printf '## Files\n\n| # | File | Rating | Reason |\n|---|---|---|---|\n| 1 | `docs/headings.ts` | 9 | One entry, last. |\n| 8 | `packages/vike/package.json` | 6 | Refactor 1. |\n\n## Summary\n\n| Item | Old => new | Commit |\n|---|---|---|\n| File 8 `packages/vike/package.json` | 6 => 9 | f3e4b44bd4 |\n\nGates on f3e4b44bd4:\n- `pnpm run test:types` -> exit 0\n' > "$T/ratings.md"
check "BLOCK: a ratings report with no ✅ list, standards or CLEAN, naming each, and how a pass that changes nothing records" "1 1" "$(prs shape "$T/ratings.md") $(cd "$G" && bash "$R/bin/pr-steps" shape "$T/ratings.md" 2>&1 | grep -c "lacks the ✅ coverage list, '## Standards read', a last line CLEAN (mergeworthy delegate/shape.md). A pass that changes nothing is one too: it rates each item N ⇒ N and records on the unchanged head")"
printf '| `loader.ts` | new ⇒ 9 | abc | one step per hook |\n✅ loader.ts\nCLEAN\n' > "$T/newpass.md"; std "$T/newpass.md"
GN="$T/prsn"; mkdir -p "$GN"; git -C "$GN" init -q; git -C "$GN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a
check "a pass rating only items it added (new ⇒ 9) records" 0 "$(cd "$GN" && bash "$R/bin/pr-steps" shape "$T/newpass.md" >/dev/null 2>&1; echo $?)"
# a carry of a head with two passes (one before a maintainer's ask, one after it) carries the latest
GC="$T/prsc"; mkdir -p "$GC"; git -C "$GC" init -q; git -C "$GC" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a; GA=$(git -C "$GC" rev-parse HEAD)
printf '| `a.ts` | 6 ⇒ 7 | x | one |\n✅ a.ts\nCLEAN\n' > "$T/two-old.md"; printf '| `a.ts` | 7 ⇒ 9 | y | two |\n✅ a.ts\nCLEAN\n' > "$T/two-new.md"
printf 'shape %s 2026-10-15T07:00:00Z\nshape %s 2026-10-15T09:00:00Z\n' "$T/two-old.md" "$T/two-new.md" > "$HOME/.claude/pr-steps/$GA"
echo "2026-10-15T08:04:10Z ${GA:0:10} o/r#9 https://example.invalid/o/r/pull/9#issuecomment-8" > "$HOME/.claude/refactor-asks.txt"
printf 'x\n' > "$GC/f"; git -C "$GC" add f; git -C "$GC" -c user.name=t -c user.email=t@t commit -q -m b; printf 'carries the pass of %s: one docs line\n' "$GA" > "$T/carry-two.md"
check "a small follow-up carries the latest of two passes on a head, the one after the ask" 0 "$(cd "$GC" && bash "$R/bin/pr-steps" shape "$T/carry-two.md" >/dev/null 2>&1; echo $?)"
rm -f "$HOME/.claude/refactor-asks.txt" "$HOME/.claude/pr-steps/$GA"
printf '| express vike() | 5 ⇒ 8 | abc | named steps |\n✅ express vike()\nCLEAN\n' > "$T/pass.md"; std "$T/pass.md"
printf '| express vike() | 5 ⇒ 8 | abc | named steps |\n✅ express vike()\nFIX src/a.ts:3 dead branch\n' > "$T/open.md"
printf '| express vike() | 5 ⇒ 8 | abc | named steps |\n| render() | 10 = | Unchanged since ratings17. |\n✅ express vike()\nCLEAN\n' > "$T/copied.md"
check "BLOCK: a re-rating that copies earlier ratings is not a pass, quoting the copied cell" "1 1" "$(prs shape "$T/copied.md") $(cd "$G" && bash "$R/bin/pr-steps" shape "$T/copied.md" 2>&1 | grep -c "rating is copied")"
check "BLOCK: a pass with findings left, not ending CLEAN" 1 "$(prs shape "$T/open.md")"
check "a pass with ratings and the ✅ list, ending CLEAN, records" 0 "$(prs shape "$T/pass.md")"
check "pr-steps loopb and refactor are gone, pointing at shape" "1 1" "$(prs loopb "$T/pass.md") $(prs refactor "$T/pass.md")"
A=$(git -C "$G" rev-parse HEAD); printf 'x\n' > "$G/f"; git -C "$G" add f; git -C "$G" -c user.name=t -c user.email=t@t commit -q -m b
printf 'carries the pass of %s: one docs line\n' "$A" > "$T/carry.md"
check "a small follow-up carries the earlier pass" 0 "$(prs shape "$T/carry.md")"
# a maintainer's ask for a refactor pass (the watcher's ~/.claude/refactor-asks.txt) after the carried pass needs a real pass, not a carry
printf 'y\n' > "$G/g"; git -C "$G" add g; git -C "$G" -c user.name=t -c user.email=t@t commit -q -m c
printf 'carries the pass of %s: one test line\n' "$A" > "$T/carry2.md"; cp "$T/carry2.md" "$T/carry3.md"
echo "$(date -u -d '-1 day' +%FT%TZ) ${A:0:10} o/r#5 https://example.invalid/o/r/pull/5#issuecomment-1" > "$HOME/.claude/refactor-asks.txt"
check "an ask older than the carried pass leaves the carry allowed" 0 "$(prs shape "$T/carry2.md")"
echo "$(date -u -d '+1 minute' +%FT%TZ) 0123456789 o/r#6 https://example.invalid/o/r/pull/6#issuecomment-3" >> "$HOME/.claude/refactor-asks.txt"; cp "$T/carry2.md" "$T/carry4.md"
check "an ask on another PR's branch (its head not in this history) leaves the carry allowed" 0 "$(prs shape "$T/carry4.md")"
echo "$(date -u -d '+1 minute' +%FT%TZ) ${A:0:10} o/r#5 https://example.invalid/o/r/pull/5#issuecomment-2" >> "$HOME/.claude/refactor-asks.txt"
check "BLOCK: an ask after the carried pass, on this branch: a carry is refused, naming the ask" "1 1" "$(prs shape "$T/carry3.md") $(cd "$G" && bash "$R/bin/pr-steps" shape "$T/carry3.md" 2>&1 | grep -c 'issuecomment-2 asks for a refactor pass')"
printf '| express vike() | 8 ⇒ 9 | def | one step per hook |\n✅ express vike()\nCLEAN\n' > "$T/pass2.md"; std "$T/pass2.md"
check "after the ask, a real pass records" 0 "$(prs shape "$T/pass2.md")"
rm -f "$HOME/.claude/refactor-asks.txt"
printf 'NO BUGS\n' > "$T/vA.md"; std "$T/vA.md"; G_A=$A; (cd "$G" && git checkout -q "$G_A" && bash "$R/bin/pr-steps" verify "$T/vA.md" >/dev/null 2>&1; git checkout -q -); 
cp "$T/carry.md" "$T/carry-v.md"
check "a small follow-up carries an earlier head's Loop A" 0 "$(prs verify "$T/carry-v.md")"
cp "$T/carry.md" "$T/carry-f.md"
check "BLOCK: carrying a step the earlier head never recorded" 1 "$(prs fresh "$T/carry-f.md")"
mkdir -p "$G/dist"; seq 1 300 > "$G/dist/a.mjs"; git -C "$G" add dist; git -C "$G" -c user.name=t -c user.email=t@t commit -q -m bundle; cp "$T/carry.md" "$T/carry-d.md"
check "a committed build bundle (dist/) doesn't count against a carry" 0 "$(prs shape "$T/carry-d.md")"
seq 1 100 > "$G/big"; git -C "$G" add big; git -C "$G" -c user.name=t -c user.email=t@t commit -q -m c
printf 'carries the pass of %s: big change\n' "$A" > "$T/carry2.md"
check "BLOCK: carrying across more than 80 changed lines" 1 "$(prs shape "$T/carry2.md")"
# a clean merge of the base brings in other people's lines: the PR's own patch is unchanged, so its pass carries
MB="$T/mbase.git"; MG="$T/mclone"; git init -q --bare -b main "$MB"; git clone -q "$MB" "$MG" 2>/dev/null
gc() { git -C "$MG" -c user.name=t -c user.email=t@t "$@"; }
echo a > "$MG/a"; gc add a; gc commit -q -m base; gc push -q origin main; gc remote set-head origin main >/dev/null
gc checkout -q -b fix; echo fix > "$MG/f"; gc add f; gc commit -q -m fix; MA=$(git -C "$MG" rev-parse HEAD)
mkdir -p "$HOME/.claude/pr-steps"; echo "verify $T/mv.md" >> "$HOME/.claude/pr-steps/$MA"
gc checkout -q main; seq 1 200 > "$MG/other"; gc add other; gc commit -q -m other; gc push -q origin main; gc checkout -q fix; gc merge -q --no-edit main
printf 'carries the pass of %s: merged main\n' "$MA" > "$T/carry-m.md"
check "a clean merge of the base (200 lines, none the PR's) carries the earlier head's Loop A" 0 "$( (cd "$MG" && bash "$R/bin/pr-steps" verify "$T/carry-m.md" >/dev/null 2>&1; echo $?) )"
# a branch whose latest approach record has no `contract: 2` was started by a session on v1's skills: it finishes under the old records
mkdir -p "$HOME/.mergeworthy/sessions"; echo "/p graph startup 0" > "$HOME/.mergeworthy/sessions/s-graph"; echo "/p v1 startup 0" > "$HOME/.mergeworthy/sessions/s-v1"
printf 'Root cause: src/a.ts:3 does it\n| Candidate | Rating | Why |\n|---|---|---|\n| Not building it | 3 | stays |\n| Fix it | 8 | ok |\n\nChosen: Fix it\n' > "$T/apo.md"; CLAUDE_CODE_SESSION_ID=s-graph prs approach "$T/apo.md" >/dev/null
APF=$(ls -t "$HOME"/.claude/pr-steps/approach.* | head -n1)
check "an approach recorded by a session on the graph catalog carries contract: 2" 1 "$(tail -n1 "$APF" | grep -c ' contract: 2$')"
printf 'nothing worth changing\nCLEAN\n' > "$T/olb.md"
check "BLOCK: a new-contract branch can't record loopb or refactor" "1 1" "$(prs loopb "$T/olb.md") $(prs refactor "$T/pass.md")"
CLAUDE_CODE_SESSION_ID=s-none prs approach "$T/apo.md" >/dev/null
check "an approach recorded by a session with no catalog record has no contract: 2" 0 "$(tail -n1 "$APF" | grep -c ' contract: 2$')"
CLAUDE_CODE_SESSION_ID=s-v1 prs approach "$T/apo.md" >/dev/null
check "an approach recorded by a session on v1's catalog has no contract: 2" 0 "$(tail -n1 "$APF" | grep -c ' contract: 2$')"
printf 'MERGE AS IS: yes\nCLEAN\n' > "$T/ofr.md"; std "$T/ofr.md"
check "an old-contract branch still records loopb, refactor, and a fresh report without a Maintainer line" "0 0 0" "$(prs loopb "$T/olb.md") $(prs refactor "$T/pass.md") $(prs fresh "$T/ofr.md")"
C=$(git -C "$G" rev-parse HEAD); printf 'y\n' > "$G/f2"; git -C "$G" add f2; git -C "$G" -c user.name=t -c user.email=t@t commit -q -m d
printf 'carries the pass of %s: one line\n' "$C" > "$T/carry3.md"
check "a shape record carries an old head's loopb CLEAN and refactor pass" 0 "$(prs shape "$T/carry3.md")"
printf 'z\n' > "$G/f3"; git -C "$G" add f3; git -C "$G" -c user.name=t -c user.email=t@t commit -q -m e; E=$(git -C "$G" rev-parse HEAD)
cp "$T/pass.md" "$T/pass-e.md"; prs refactor "$T/pass-e.md" >/dev/null
printf 'w\n' > "$G/f4"; git -C "$G" add f4; git -C "$G" -c user.name=t -c user.email=t@t commit -q -m f
printf 'carries the pass of %s: one line\n' "$E" > "$T/carry4.md"
check "BLOCK: an old head with a refactor pass but no loopb record can't be carried as shape" 1 "$(prs shape "$T/carry4.md")"
CLAUDE_CODE_SESSION_ID=s-graph prs approach "$T/apo.md" >/dev/null
check "BLOCK: the branch reused with a new approach is new-contract again" 1 "$(prs loopb "$T/olb.md")"
# pr-steps verify and reverify: a reproduced behavior a verifier dropped as harmless waits for the main session's RULED line
printf 'slice 1\n## Tried and dropped\n- **abort leaks a listener**: Not a regression, main does the same\n- a slow path: rarely slower, noise\nNO BUGS\n' > "$T/vr0.md"
printf 'slice 1\n- **a rare race in abort**: reproduced, fixed in abc1234\nNO BUGS\n' > "$T/vr3.md"; std "$T/vr3.md"
check "a counted bug described as rare, outside the dropped list, needs no RULED line" 0 "$(prs verify "$T/vr3.md")"
{ head -n4 "$T/vr0.md"; echo 'RULED: abort leaks a listener: a real leak, fixed in its own PR'; echo 'NO BUGS'; } > "$T/vr1.md"
sed 's/^NO BUGS$/NO LOOP B COMMITS/' "$T/vr0.md" > "$T/vr2.md"; std "$T/vr0.md" "$T/vr1.md"
check "BLOCK: a dropped candidate whose reason is 'not a regression', quoting it, in verify and reverify; with a later RULED line naming it, it records" "1 1 1 0" "$(prs verify "$T/vr0.md") $(cd "$G" && bash "$R/bin/pr-steps" verify "$T/vr0.md" 2>&1 | grep -c '^- \*\*abort leaks a listener\*\*: Not a regression') $(prs reverify "$T/vr2.md") $(prs verify "$T/vr1.md")"
printf 'slice 1\n## Tried and dropped\n- **abort leaks a listener**: Not a regression, main does the same\nRULED: abort leaks a listener: not a regression, main does the same\nNO BUGS\n' > "$T/vr4.md"; std "$T/vr4.md"
printf 'slice 1\n## Tried and dropped\n- **abort leaks a listener**: Not a regression, main does the same\nRULED: abort leaks a listener: not a regression, and only a staged race reaches it (code Earn every line)\nNO BUGS\n' > "$T/vr5.md"; std "$T/vr5.md"
check "BLOCK: a RULED line whose only reason is that main does the same; one citing Earn every line records" "1 1 0" "$(prs verify "$T/vr4.md") $(cd "$G" && bash "$R/bin/pr-steps" verify "$T/vr4.md" 2>&1 | grep -c 'is not a ruling') $(prs verify "$T/vr5.md")"
printf 'slice 1\n## Tried and dropped\n- `D=~/cfg` (tilde.sh): a nit.\n  - **Why a nit:** both fail closed, and it is rare.\nRULED: `D=~/cfg` (tilde.sh): a nit, no realistic usage (code Earn every line)\nNO BUGS\n' > "$T/vr6.md"; std "$T/vr6.md"
check "a dropped item's sub-bullet reason is ruled under the item's name, not its label" 0 "$(prs verify "$T/vr6.md")"
# pr-steps verify: a diff that touches bodies or streams needs code §No regressions' list answered by name
G3="$T/prs3"; mkdir -p "$G3"; git -C "$G3" init -q -b main; git -C "$G3" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a
git -C "$G3" update-ref refs/remotes/origin/main HEAD; git -C "$G3" checkout -q -b fix
echo 'const b = await request.arrayBuffer()' > "$G3/a.ts"; git -C "$G3" add a.ts; git -C "$G3" -c user.name=t -c user.email=t@t commit -q -m b
prs3() { (cd "$G3" && bash "$R/bin/pr-steps" "$@" 2>"$T/prs3.err" >/dev/null; echo $?); }
printf 'slice 1: no bug that counts\nNO BUGS\n' > "$T/vb0.md"
printf 'slice 1\n## Bodies and streams\n- Cancellation: ok\n- Backpressure: ok\n- Cap: ok\n- Release: ok\n- Read once: ok\n- Ownership: ok\n- Failure: ok\n- Sources: ok\n## Done\nNO BUGS\n' > "$T/vb1.md"
printf 'slice 1\n## Bodies and streams\n- Cancellation: ok\n- Backpressure: ok\n- Cap: ok\n- Release: ok\n- Read once: ok\n- Ownership: ok\n- Failure: ok\n- Sources: ok\n- Second copy: ok\nNO BUGS\n' > "$T/vb2.md"
L='- %s: cancelled the reader mid-stream, source stopped\n'; printf "slice 1\n## Bodies and streams\n$L$L$L$L$L$L$L$L$L" Cancellation Backpressure Cap Release 'Read once' Ownership Failure Sources 'Second copy' > "$T/vb3.md"; echo NO BUGS >> "$T/vb3.md"; std "$T/vb0.md" "$T/vb1.md" "$T/vb2.md" "$T/vb3.md"
check "BLOCK: a body-touching diff's Loop A without the list, then without one item (named), then with one-word answers; with a probe per item, records" "1 1 1 1 0" "$(prs3 verify "$T/vb0.md") $(prs3 verify "$T/vb1.md") $(grep -c 'too short: Cancellation, .*Second copy$' "$T/prs3.err") $(prs3 verify "$T/vb2.md") $(prs3 verify "$T/vb3.md")"
echo 'Response.prototype.text = f' > "$G3/a.ts"; git -C "$G3" -c user.name=t -c user.email=t@t commit -qam c
check "BLOCK: a patch onto a built-in's prototype also needs the list" 1 "$(prs3 verify "$T/vb0.md")"
# pr-steps gates: each changeset the branch adds is a sentence or two, and names every package whose files the branch changed
G5="$T/prs5"; mkdir -p "$G5/packages/a" "$G5/packages/b" "$G5/examples/e" "$G5/.changeset"; git -C "$G5" init -q -b main
echo '{"name": "root"}' > "$G5/package.json"; echo '{"name": "@x/a"}' > "$G5/packages/a/package.json"; echo '{"name": "@x/b"}' > "$G5/packages/b/package.json"
echo '{"name": "e", "private": true}' > "$G5/examples/e/package.json"; seq 1 80 | tr '\n' ' ' > "$G5/.changeset/README.md"
git -C "$G5" add -A; git -C "$G5" -c user.name=t -c user.email=t@t commit -q -m a; git -C "$G5" update-ref refs/remotes/origin/main HEAD; git -C "$G5" checkout -q -b fix
for f in packages/a/src.ts packages/b/x.ts examples/e/y.ts README.md; do echo x > "$G5/$f"; done
printf -- '---\n"@x/a": patch\n---\n\n%s\n' "$(seq 1 61 | sed 's/^/word/' | tr '\n' ' ')" > "$G5/.changeset/c.md"
git -C "$G5" add -A; git -C "$G5" -c user.name=t -c user.email=t@t commit -q -m b
prs5() { (cd "$G5" && bash "$R/bin/pr-steps" "$@" 2>"$T/prs5.err" >/dev/null; echo $?); }
printf 'pnpm lint -> exit 0\n' | tee "$T/g5a.md" > "$T/g5b.md"
check "BLOCK: gates with a changeset of 61 words that misses a changed package, naming both (not the private example's, not the root's)" "1 1 1 0" "$(prs5 gates "$T/g5a.md") $(grep -c 'c.md: its body has 61 words' "$T/prs5.err") $(grep -c 'no bump for @x/b,' "$T/prs5.err") $(grep -c '\(root\|e\),' "$T/prs5.err")"
printf -- '---\n"@x/a": patch\n"@x/b": patch\n---\n\nFix the thing users saw.\n' > "$G5/.changeset/c.md"; git -C "$G5" -c user.name=t -c user.email=t@t commit -qam c
check "a short changeset naming each changed package records" 0 "$(prs5 gates "$T/g5b.md")"
# ---------- pr-steps small: a fix of <= 60 lines outside tests and docs, with a test, takes one review for verify..fresh ----------
GS="$T/prss"; mkdir -p "$GS/src" "$GS/test"; git -C "$GS" init -q -b main; echo a > "$GS/src/a.ts"; git -C "$GS" add -A; git -C "$GS" -c user.name=t -c user.email=t@t commit -q -m a
git -C "$GS" update-ref refs/remotes/origin/main HEAD; git -C "$GS" checkout -q -b fix
prss() { (cd "$GS" && bash "$R/bin/pr-steps" small "$@" 2>"$T/prss.err" >/dev/null; echo $?); }
printf 'x\n## Outside this change\nNO BUGS\nMERGE AS IS: yes\n' > "$T/sr1.md"; cp "$T/sr1.md" "$T/sr2.md"; cp "$T/sr1.md" "$T/sr3.md"; printf 'a finding\n' > "$T/sr0.md"
seq 1 5 >> "$GS/src/a.ts"; git -C "$GS" -c user.name=t -c user.email=t@t commit -qam b
r1=$(prss "$T/sr1.md"); echo t > "$GS/test/a.test.ts"; seq 1 300 > "$GS/README.md"; git -C "$GS" add -A; git -C "$GS" -c user.name=t -c user.email=t@t commit -qm c
r2=$(prss "$T/sr0.md")
check "pr-steps small: BLOCK with no test in the diff, BLOCK on a report with findings, records with both (docs not counted)" "1 1 0" "$r1 $r2 $(prss "$T/sr2.md")"
check "after pr-steps small, gh pr ready lacks only the gates" "gates" "$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh pr ready 5 -R o/r"},"cwd":sys.argv[1]}))' "$GS" | python3 "$R/hooks/pre-bash-guard.py" 2>&1 | grep -o 'no pr-steps [a-z, ]* record' | sed 's/no pr-steps //; s/ record//')"
printf 'x\n## Outside this change\nNone.\n\nNO BUGS\nMERGE AS IS: yes\n\n## Verification\n- ran it\n\n## not_checked\n- Windows\n' > "$T/sr5.md"
check "pr-steps small records a report whose verdict comes before its Verification and not_checked sections" 0 "$(prss "$T/sr5.md")"
printf 'x\n## Outside this change\nNone.\n\n## not_checked\n- Windows\n\nNO BUGS\nMERGE AS IS: yes\n' > "$T/sr6.md"
check "pr-steps small records a report whose verdict ends the file after its not_checked section" 0 "$(prss "$T/sr6.md")"
mkdir -p "$GS/dist"; seq 1 300 > "$GS/dist/a.mjs"; git -C "$GS" add dist; git -C "$GS" -c user.name=t -c user.email=t@t commit -qm bundle
check "pr-steps small doesn't count a committed build bundle (dist/)" 0 "$(prss "$T/sr2.md")"
seq 1 70 >> "$GS/src/a.ts"; git -C "$GS" -c user.name=t -c user.email=t@t commit -qam d
printf 'NO BUGS\nMERGE AS IS: yes\n- a finding after them\n' > "$T/sr4.md"
check "BLOCK: pr-steps small on a report whose last lines aren't NO BUGS and MERGE AS IS: yes" 1 "$(prss "$T/sr4.md")"
check "BLOCK: pr-steps small past 60 lines outside tests and docs" "1 1" "$(prss "$T/sr3.md") $(grep -c 'past a small fix' "$T/prss.err")"
# a diff of docs alone carries the cold read's record (rules step 4) instead of a test
GD="$T/prsd"; mkdir -p "$GD/skills/a"; git -C "$GD" init -q -b main; echo a > "$GD/skills/a/SKILL.md"; git -C "$GD" add -A; git -C "$GD" -c user.name=t -c user.email=t@t commit -q -m a
git -C "$GD" update-ref refs/remotes/origin/main HEAD; git -C "$GD" checkout -q -b fix; echo b >> "$GD/skills/a/SKILL.md"; git -C "$GD" -c user.name=t -c user.email=t@t commit -qam b
prsd() { (cd "$GD" && bash "$R/bin/pr-steps" small "$@" 2>"$T/prsd.err" >/dev/null; echo $?); }
r1=$(prsd "$T/sr1.md"); r1="$r1 $(grep -c 'no cold read' "$T/prsd.err")"
echo record > "$T/sd-cold.md"; git -C "$GD" -c user.name=t -c user.email=t@t commit -q --allow-empty -m c -m "Cold-read: $T/sd-cold.md"
check "pr-steps small on a diff of docs alone: BLOCK naming the cold read with no Cold-read trailer, records with one" "1 1 0" "$r1 $(prsd "$T/sr1.md")"
echo x > "$GD/pnpm-lock.yaml"; git -C "$GD" add pnpm-lock.yaml; git -C "$GD" -c user.name=t -c user.email=t@t commit -q -m lock
check "BLOCK: pr-steps small on docs and a lockfile without a test, though a commit carries a cold read" "1 1" "$(prsd "$T/sr1.md") $(grep -c 'adds or changes no test' "$T/prsd.err")"
# ---------- pr-steps: every converge step leaves its proof; the guard needs all five ----------
G2="$T/prs2"; mkdir -p "$G2"; git -C "$G2" init -q; git -C "$G2" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a
prs2() { (cd "$G2" && bash "$R/bin/pr-steps" "$@" >/dev/null 2>&1; echo $?); }
ready() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh pr ready 5 -R o/r"},"cwd":sys.argv[1]}))' "$G2" | python3 "$R/hooks/pre-bash-guard.py" >/dev/null 2>&1; echo $?; }
check "BLOCK: gh pr ready with no step recorded" 2 "$(ready)"
printf 'slice 1: no bug that counts\n' > "$T/v0.md"
check "BLOCK: a Loop A output without NO BUGS" 1 "$(prs2 verify "$T/v0.md")"
printf 'slice 1: no bug that counts\nNO BUGS\n' > "$T/v.md"; cp "$T/v.md" "$T/v-nostd.md"; std "$T/v.md"; check "BLOCK: a Loop A file without '## Standards read', naming the missing sentence" "1 1" "$(prs2 verify "$T/v-nostd.md") $(cd "$G2" && bash "$R/bin/pr-steps" verify "$T/v-nostd.md" 2>&1 | grep -c '^Every fix passes it.$')"; check "Loop A ending NO BUGS records" 0 "$(prs2 verify "$T/v.md")"
printf '| vike() | 5 ⇒ 8 | abc | why |\n✅ vike()\nnothing worth changing\nCLEAN\n' > "$T/rf.md"; std "$T/rf.md"; check "Loop B's shape report records" 0 "$(prs2 shape "$T/rf.md")"
printf 'NO LOOP B COMMITS\n' > "$T/rv.md"; check "Loop A again, with no Loop B commits, records" 0 "$(prs2 reverify "$T/rv.md")"
printf 'Maintainer: hi-ogawa\nCLEAN\n' > "$T/fr0.md"; std "$T/fr0.md"; check "BLOCK: a fresh read without MERGE AS IS: yes" 1 "$(prs2 fresh "$T/fr0.md")"
printf 'MERGE AS IS: yes\nCLEAN\n' > "$T/fr1.md"; std "$T/fr1.md"; check "BLOCK: a fresh read that names no maintainer" 1 "$(prs2 fresh "$T/fr1.md")"
printf 'Maintainer: hi-ogawa\nMERGE AS IS: yes\nCLEAN\n' > "$T/fr.md"; std "$T/fr.md"; check "the fresh reader's maintainer, merge-as-is and CLEAN record" 0 "$(prs2 fresh "$T/fr.md")"
printf 'Maintainer: hi-ogawa\nMERGE AS IS: yes\n- the body says "buffered"; "buffered whole" is exact\n' > "$T/fr2.md"; std "$T/fr2.md"; check "a yes with a body note records; a no does not" "0 1" "$(prs2 fresh "$T/fr2.md") $(sed -i 's/MERGE AS IS: yes/MERGE AS IS: no/' "$T/fr2.md"; prs2 fresh "$T/fr2.md" 2>/dev/null)"
printf 'pnpm test -> exit 0\npnpm lint -> exit 1\n' > "$T/g1.md"
check "BLOCK: a gates log with a red gate" 1 "$(prs2 gates "$T/g1.md")"
check "BLOCK: gh pr ready with four of five steps" 2 "$(ready)"
printf 'pnpm test -> exit 0\npnpm lint -> exit 0\n' > "$T/g0.md"; printf 'pnpm test -> exit 0 (0 tests)\n' > "$T/g00.md"
check "BLOCK: a test gate without its count, or with 0 tests" "1 1" "$(prs2 gates "$T/g0.md") $(prs2 gates "$T/g00.md")"
printf 'pnpm test -> exit 0 (134 tests)\npnpm lint -> exit 0\n' > "$T/g2.md"; check "a green gates log records" 0 "$(prs2 gates "$T/g2.md")"
check "BLOCK: gh pr ready with the five steps but no approach record" 2 "$(ready)"
printf 'Root cause: src/a.ts:3 does it\n| Candidate | Rating | Why |\n|---|---|---|\n| Not building it | 3 | the bug stays |\n| Fix in place | 5 | misses siblings |\n| Fix the shared helper | 8 | one place for all |\n\nChosen: Fix the shared helper\n' > "$T/ap.md"
printf 'Root cause: src/a.ts:3 does it\n| Candidate | Rating | Why |\n|---|---|---|\n| Fix the shared helper | 8 | only one |\n\nChosen: Fix the shared helper\n' > "$T/ap1.md"
printf '| Candidate | Rating | Why |\n|---|---|---|\n| Not building it | 3 | the bug stays |\n| Fix in place | 8 | ok |\n\nChosen: Fix in place\n' > "$T/apnr.md"
printf 'Root cause: src/a.ts:3 does it\n| Candidate | Rating | Why |\n|---|---|---|\n| Not building it | 3 | the bug stays |\n| Fix in place | 6 | misses siblings |\n\nChosen: Fix in place\n' > "$T/ap6.md"
printf 'Root cause: src/a.ts:3 does it\n| Candidate | Rating | Why |\n|---|---|---|\n| Not building it | 3 | the bug stays |\n| Fix in place | 8 | ok |\n\nChosen: Rewrite\n' > "$T/apx.md"
rc=; for c in 'Root cause: unknown yet, logged at 12:30' '- **Root cause:** src/a.ts:3 does it' 'Root cause: none, a feature'; do printf '%s\n| Candidate | Rating | Why |\n|---|---|---|\n| Not building it | 3 | the bug stays |\n| Fix in place | 8 | ok |\n\nChosen: Fix in place\n' "$c" > "$T/aprc.md"; GR="$T/aprc-$((n=${n:-0}+1))"; git init -q "$GR"; git -C "$GR" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a; rc="$rc $(cd "$GR" && bash "$R/bin/pr-steps" approach "$T/aprc.md" >/dev/null 2>&1; echo $?)"; done
check "BLOCK: an approach with no Root cause line citing a path:line, or one citing a time; a bold list item or a feature records" "1 1 0 0" "$(prs2 approach "$T/apnr.md")$rc"
check "BLOCK: an approach with one candidate" 1 "$(prs2 approach "$T/ap1.md")"
check "BLOCK: a chosen approach rated 6" 1 "$(prs2 approach "$T/ap6.md")"
check "BLOCK: a chosen approach that is no candidate" 1 "$(prs2 approach "$T/apx.md")"
check "BLOCK: gh pr ready after refused approach records" 2 "$(ready)"
check "an approach with three rated candidates and a chosen 8 records, with no Browser line" 0 "$(prs2 approach "$T/ap.md")"
glab() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "${2:-$T}" | python3 "$R/hooks/pre-bash-guard.py" >/dev/null 2>&1; echo $?; }
mkdir -p "$HOME/.config/pnpm"; echo '//registry.npmjs.org/:_authToken=x' > "$HOME/.npmrc"; cp "$HOME/.npmrc" "$HOME/.config/pnpm/config.yaml"
check "BLOCK: printing a credential file; counting a line in it, or a file that isn't one, passes" "2 2 2 0 0" "$(glab "cat $HOME/.npmrc") $(glab 'cat ~/.config/pnpm/config.yaml') $(glab "grep token $HOME/.npmrc") $(glab "grep -c registry $HOME/.npmrc") $(glab "cat $T/tr.jsonl")"
check "BLOCK: setting a draft's file time (touch -d / -r, also after a cd into drafts/); a plain touch elsewhere passes" "2 2 0 0" "$(glab "cd /w/drafts/vike-1707 && touch -d 2024-06-20T12:26:20Z proposal.parent.md") $(glab "touch -r a.md /w/drafts/x/thread-context.md") $(glab "touch /w/drafts/x/new.md") $(glab "touch -d yesterday /tmp/stamp")"
check "BLOCK: gate-pass and a post in one command (a pipe hid its refusal); gate-pass alone passes" "2 2 0" "$(glab "gate-pass /w/drafts/19/body.md /w/drafts/19/body.review.out | tail -1 && gh issue edit 19 --body-file /w/drafts/19/body.md") $(glab "gate-pass /w/d/r.md /w/d/r.review.out; gh api repos/o/r/issues/5/comments -F body=@/w/d/r.md") $(glab "gate-pass /w/drafts/19/body.md /w/drafts/19/body.review.out")"
check "BLOCK: a playwright install into the shared cache; into a private folder passes" "2 2 0" "$(glab "pnpm exec playwright install chromium") $(glab "cd repo && npx playwright install --with-deps") $(glab "PLAYWRIGHT_BROWSERS_PATH=/w/.pw npx playwright install chromium")"
# pre-bash-guard: a PR title is drafted in a file, never typed inline
echo '[]' > "$FX/repos_o_r_issues_5_timeline_per_page_100"
guard() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2],"agent_id":sys.argv[3]}))' "$1" "$T" "${2:-}" | python3 "$R/hooks/pre-bash-guard.py" 2>"$T/err"; echo $?; }
check "BLOCK: a PR title typed inline (create, edit, -t), naming the title file; a title from its file passes" "2 1 2 2 0 0" "$(guard "gh pr create --draft --title 'Fix the thing' --body-file $T/b.md") $(grep -c 'drafts/title.md.*last 10 merged titles.*pull-request step 7' "$T/err") $(guard "gh pr edit 5 --title 'Fix it'") $(guard 'gh pr edit 5 -t Fix') $(GH_WATCH_ME=me guard 'gh pr edit 5 -R o/r --title "$(cat /w/drafts/title.md)"') $(guard 'gh pr create --draft --title "$(cat /w/drafts/title.md)" --body-file /w/b.md' >/dev/null; grep -c 'typed inline' "$T/err")"
printf '[{"event":"renamed","actor":{"login":"brillout"},"created_at":"2026-10-14T21:50:52Z","rename":{"from":"a","to":"b"}}]' > "$FX/repos_o_r_issues_7_timeline_per_page_100"
echo '[]' > "$FX/repos_o_r_issues_9_timeline_per_page_100"
printf '[{"event":"renamed","actor":{"login":"brillout"},"created_at":"2026-10-14T21:50:52Z"},{"event":"renamed","actor":{"login":"me"},"created_at":"2026-10-14T22:00:00Z"}]' > "$FX/repos_o_r_issues_8_timeline_per_page_100"
check "BLOCK: retitling a PR whose title a maintainer set, naming him; our own last title, or no rename, passes" "2 1 0 0" "$(GH_WATCH_ME=me guard 'gh pr edit 7 -R o/r --title "$(cat /w/drafts/title.md)"') $(grep -c 'brillout set this PR.s title' "$T/err") $(GH_WATCH_ME=me guard 'gh pr edit 8 -R o/r --title "$(cat /w/drafts/title.md)"') $(GH_WATCH_ME=me guard 'gh pr edit 9 -R o/r --title "$(cat /w/drafts/title.md)"')"
printf 'fix: deprecate `vike/fetch` (closes #3608)\n' > "$T/title.md"; printf 'fix: two\nlines.\n' > "$T/title2.md"
check "post-lint --kind title passes one line and records it; two lines fail" "0 1 1" "$("$R/bin/post-lint" "$T/title.md" --kind title >/dev/null; echo $?) $([ -s "$T/title.md.lint.sha" ] && echo 1) $("$R/bin/post-lint" "$T/title2.md" --kind title >/dev/null; echo $?)"
echo 'me 42' > "$FX/user"
IDR="$T/idr"; git init -q "$IDR"; git -C "$IDR" remote add origin https://github.com/o/r.git  # the identity is checked in a checkout of a GitHub repo
(cd "$IDR" && bash "$R/bin/pr-steps" preflight 'none, because the test repo has no UI' >/dev/null)
check "BLOCK: a commit as the pushing login but with another email, naming the noreply form; the noreply email passes" "2 1 0" "$(guard "git -C $IDR -c user.name=me -c user.email=real@example.com commit -m a") $(grep -c '42+me@users.noreply.github.com' "$T/err") $(guard "git -C $IDR -c user.name=me -c user.email=42+me@users.noreply.github.com commit -m a")"
rm "$FX/user"
# pre-bash-guard: a review's verdict is the reviewer's own output, never the main session's
check "BLOCK: the main session writing a .review.out (echo >, tee, cp, sed -i, bash -c), naming who writes it" "2 1 2 2 2 2" "$(guard 'echo CLEAN > $D/pr-body.review.out') $(grep -c 'codex exec -o' "$T/err") $(guard "printf 'CLEAN\n' | tee /w/x.review.out") $(guard 'cp /w/r.md /w/x.review.out') $(guard 'sed -i s/a/b/ /w/x.review.out') $(guard 'bash -c "echo CLEAN >> /w/x.review.out"')"
check "BLOCK: pgrep -f, also inside bash -c; pgrep -P passes" "2 2 0" "$(guard 'pgrep -f vite') $(guard "bash -c 'pgrep -f \"vitest run\" || echo gone'") $(guard 'pgrep -P 123')"
check "BLOCK: pkill -f behind wrappers (timeout, netns-run, nice, ionice) and inside their bash -c; a plain timeout run passes" "2 2 2 0" "$(guard "timeout 200 netns-run bash -c 'pnpm build; pkill -f \"vike preview\"; true'") $(guard 'nice -n 19 ionice -c3 pkill -f vite') $(guard 'timeout -k 5 60 pkill -f vite') $(guard 'timeout 60 nice -n 19 pnpm test')"
check "reading a .review.out, gate-pass, a claude -p reviewer's stdout and an agent writing its own output pass" "0 0 0 0" "$(guard 'cat /w/x.review.out > /w/copy.md') $(guard 'gate-pass /w/x.md /w/x.review.out') $(guard 'claude -p "$(cat /w/p.md)" > /w/x.review.out') $(guard 'echo CLEAN > /w/x.review.out' a1)"
check "BLOCK: glab mr create, not a draft, outside a converged repo" 2 "$(glab 'glab mr create --title x')"
check "BLOCK: glab mr update --ready outside a converged repo" 2 "$(glab 'glab mr update 5 --ready')"
check "glab mr create --draft passes on a branch with its approach" 0 "$(MERGEWORTHY_WATCHER=off glab 'glab mr create --draft --title x' "$G2")"
check "glab mr create --wip passes there too" 0 "$(MERGEWORTHY_WATCHER=off glab 'glab mr create --wip --title x' "$G2")"
check "gh pr ready passes once all five steps and the approach hold" 0 "$(ready)"
check "glab mr update --ready passes there too" 0 "$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"glab mr update 5 --ready"},"cwd":sys.argv[1]}))' "$G2" | python3 "$R/hooks/pre-bash-guard.py" >/dev/null 2>&1; echo $?)"
printf 'm\n' > "$G2/m"; git -C "$G2" add m; git -c user.name=maint -c user.email=m@m -C "$G2" commit -q -m "a maintainer's tweak"
check "a maintainer's commit on a converged head carries its steps" 0 "$(ready)"
seq 1 81 > "$G2/m2"; git -C "$G2" add m2; git -c user.name=maint -c user.email=m@m -C "$G2" commit -q -m "a maintainer's rewrite"
check "a big maintainer commit carries them too: the pipeline waits for their go" 0 "$(ready)"
git -C "$G2" reset -q --hard HEAD~1
printf 'y\n' > "$G2/g"; git -C "$G2" add g; git -c user.name=t -c user.email=t@t -C "$G2" commit -q -m c -m 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'
check "BLOCK: a new HEAD has no steps, but the approach is not what it lacks" 2 "$(ready)"
check "the approach block message does not name approach on the new HEAD" 0 "$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh pr ready 5 -R o/r"},"cwd":sys.argv[1]}))' "$G2" | python3 "$R/hooks/pre-bash-guard.py" 2>&1 | grep -c 'pr-steps approach')"
H=$(git -C "$G2" rev-parse HEAD); for k in verify loopb refactor reverify fresh gates; do echo "$k /x/$k.md 2026-10-13T00:00:00Z" >> "$HOME/.claude/pr-steps/$H"; done
check "a head recorded before the shape pass (loopb and refactor) counts as shaped" 0 "$(ready)"
# pre-bash-guard: `gh pr merge` waits for a PR that is up to date with its base and whose CI ran after the base last touched its files; never --admin
M='gh pr merge 41 -R o/r --squash --delete-branch --subject "Fix it (#41)" --body ""'
mpr() { # mergeStateStatus, when its last check completed
  printf '{"url":"https://github.com/o/r/pull/41","headRefName":"fix","headRefOid":"hd","baseRefName":"main","mergeStateStatus":"%s","changedFiles":1,"files":[{"path":"a.py"}],"statusCheckRollup":[{"completedAt":"%s"}],"commits":[{"authors":[%s]}]}' "$1" "$2" "${3:-}" > "$FX/pr_view_41"; }
printf '{"total_commits":1,"commits":[{"sha":"b1","commit":{"committer":{"date":"2026-10-28T12:00:00Z"}}}]}' > "$FX/repos_o_r_compare_hd...main"
printf '{"files":[{"filename":"a.py"}]}' > "$FX/repos_o_r_commits_b1"
mpr CLEAN 2026-10-28T13:00:00Z
check "a PR up to date with its base, CI run after the base's last commit, merges" 0 "$(guard "$M")"
check "BLOCK: --admin, naming it" "2 1" "$(guard "$M --admin") $(grep -c 'never `gh pr merge --admin`' "$T/err")"
mpr BEHIND 2026-10-28T13:00:00Z
check "BLOCK: a PR GitHub reports BEHIND, naming it and the way out" "2 1" "$(guard "$M") $(grep -c 'reports it BEHIND against main: merge or rebase main into it (after a rebase, `git range-diff`' "$T/err")"
mpr DIRTY 2026-10-28T13:00:00Z
check "BLOCK: a PR GitHub reports DIRTY, naming it" "2 1" "$(guard "$M") $(grep -c 'reports it DIRTY against main' "$T/err")"
mpr CLEAN 2026-10-28T11:00:00Z
check "BLOCK: a base commit after the last CI run touching the PR's files, naming them" "2 1" "$(guard "$M") $(grep -c 'base main got commits touching a.py after its last CI run' "$T/err")"
printf '{"files":[{"filename":"b.py"}]}' > "$FX/repos_o_r_commits_b1"
check "a base commit after the last CI run touching none of the PR's files merges" 0 "$(guard "$M")"
check "BLOCK: a merge by URL checks that PR, not the current branch's" "2 1" "$(cp "$FX/pr_view_41" "$FX/pr_view_current"; sed 's/"CLEAN"/"BEHIND"/' "$FX/pr_view_41" > "$FX/pr_view_https___github.com_o_r_pull_41"
  guard 'gh pr merge https://github.com/o/r/pull/41 --squash --subject "Fix it (#41)" --body ""') $(grep -c 'reports it BEHIND' "$T/err")"
rm "$FX/pr_view_current" "$FX/pr_view_https___github.com_o_r_pull_41"; mkdir -p "$T/other"
check "the merge's PR is read in the dir and with the env the merge runs in: every gh call there, the view included" "0 0 1" "$(guard "cd $T/other && GH_STUB_PWD=$T/pwd $M") $(grep -vc " $T/other$" "$T/pwd") $(grep -c '^pr view ' "$T/pwd")"
printf '{"total_commits":251,"commits":[]}' > "$FX/repos_o_r_compare_hd...main.big"; mv "$FX/repos_o_r_compare_hd...main" "$FX/cmp.keep"; mv "$FX/repos_o_r_compare_hd...main.big" "$FX/repos_o_r_compare_hd...main"
check "BLOCK: a base past one page of GitHub's compare, naming it" "2 1" "$(guard "$M") $(grep -c "moved past one page of GitHub's lists" "$T/err")"
mv "$FX/cmp.keep" "$FX/repos_o_r_compare_hd...main"
python3 -c 'import json; print(json.dumps({"url":"https://github.com/o/r/pull/41","headRefName":"fix","headRefOid":"hd","baseRefName":"main","mergeStateStatus":"CLEAN","changedFiles":101,"files":[{"path":f"f{i}.py"} for i in range(100)],"statusCheckRollup":[{"completedAt":"2026-10-28T11:00:00Z"}],"commits":[]}))' > "$FX/pr_view_41"
printf '{"files":[{"filename":"z101.py"}]}' > "$FX/repos_o_r_commits_b1"
check "BLOCK: a base commit after the last CI run on a PR past gh's 100 files, which may touch one gh left out" "2 1" "$(guard "$M") $(grep -c "100 files a PR" "$T/err")"
# a squash keeps the human authors' credit: a body of only Co-authored-by lines naming the PR's commit authors (gh lists co-authors as authors), never the agent's
RT='{"name":"rtritto","email":"rtritto@example.invalid"}'; AG='{"name":"Claude Opus 5.5","email":"noreply@anthropic.com"},{"name":"Claude","email":"81847+claude@users.noreply.github.com"}'
mpr CLEAN 2026-10-28T13:00:00Z "$RT,$AG"; MB='gh pr merge 41 -R o/r --squash --delete-branch --subject "Fix it (#41)" --body'
check "a squash body of the PR's authors' Co-authored-by lines passes" 0 "$(guard "$MB \"Co-authored-by: rtritto <rtritto@example.invalid>\"")"
check "BLOCK: a squash body with other text, a co-author no commit of the PR has (a guessed email), or two bodies" "2 2 2 1" \
  "$(guard "$MB \"Co-authored-by: rtritto <rtritto@example.invalid>"$'\n'"Fixes the thing.\"") $(guard "$MB \"Co-authored-by: rtritto <rtritto@users.noreply.github.com>\"") $(guard "$MB '' --body ''") $(grep -c 'squash-merge as the repo asks' "$T/err")"
check "BLOCK: the agent's co-author line, by its email or its name, though gh lists it among the PR's authors" "2 2" \
  "$(guard "$MB \"Co-authored-by: Claude Opus 5.5 <noreply@anthropic.com>\"") $(guard "$MB \"Co-authored-by: Claude <81847+claude@users.noreply.github.com>\"")"
sed 's/"rtritto","email":"rtritto@example.invalid"/"Other","email":"other@example.invalid"/' "$FX/pr_view_41" > "$FX/pr_view_current"; cp "$FX/pr_view_41" "$FX/pr_view_https___github.com_o_r_pull_41"
U='gh pr merge https://github.com/o/r/pull/41 --squash --subject "Fix it (#41)" --body'
check "a squash by URL checks the credit against that PR's authors, not the current branch's" "0 2" "$(guard "$U \"Co-authored-by: rtritto <rtritto@example.invalid>\"") $(guard "$U \"Co-authored-by: Other <other@example.invalid>\"")"
cp "$FX/pr_view_41" "$FX/pr_view_current"; : > "$T/pwd"
check "a squash of the current branch's PR after a cd reads its authors in that dir" "0 0" \
  "$(guard "cd $T/other && GH_STUB_PWD=$T/pwd gh pr merge --squash --subject \"Fix it (#41)\" --body \"Co-authored-by: rtritto <rtritto@example.invalid>\"") $(grep -vc " $T/other$" "$T/pwd")"
rm "$FX/pr_view_current" "$FX/pr_view_https___github.com_o_r_pull_41"
rm "$FX/pr_view_41"
check "BLOCK: a merge state gh can't read" "2 1" "$(guard "$M") $(grep -c "gh couldn't read this PR's merge state" "$T/err")"
# ---------- pre-bash-guard: a maintainer's refactor ask (the watcher's refactor-asks.txt) is answered by a pass recorded after it ----------
# The guard reads the record only, on the PR's head or any commit it lists; whether a post shows that pass's result is the post review's.
sguard() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$T" | MERGEWORTHY_WATCHER=off python3 "$R/hooks/pre-bash-guard.py" >/dev/null 2>"$T/err"; }
echo '{"number":7,"comments":0}' > "$FX/repos_o_r_issues_7"  # the thread a comment goes to: no comments yet
pr7() { python3 -c 'import json,sys; print(json.dumps({"head":{"sha":sys.argv[1]},"body":sys.argv[2]}))' "$1" "$2" > "$FX/repos_o_r_pulls_7"; }
gated() { printf '%s\n' "$2" > "$T/$1.md"; sha256sum "$T/$1.md" | cut -d' ' -f1 > "$T/$1.md.gate"; echo "$T/$1.md"; }
printf '| # | File / function | Old ⇒ new | Reason |\n|---|---|---|---|\n| 1 | `src/load.ts` / `load()` | 6 ⇒ 7 | one owner |\n✅ load()\nCLEAN\n' > "$T/sp-old.md"
printf '| # | File / function | Old ⇒ new | Reason |\n|---|---|---|---|\n| 1 | `src/load.ts` / `load()` | 7 ⇒ 9 | split the parser from the loader |\n✅ load()\nCLEAN\n' > "$T/sp-new.md"
printf 'carries the pass of 1111111111: tests only\nCLEAN\n' > "$T/sp-carry.md"
AH=$(printf '1%.0s' $(seq 40)); MH=$(printf '2%.0s' $(seq 40))
echo "2026-10-15T08:04:10Z ${AH:0:10} o/r#7 https://example.invalid/o/r/pull/7#issuecomment-9" > "$HOME/.claude/refactor-asks.txt"
asked() { sguard "$1"; grep -c "issuecomment-9 asks for a refactor pass (2026-10-15T08:04:10Z) and no pass on this PR was recorded after it.*pr-steps shape <report>" "$T/err"; }
oldpass() { echo "shape $T/sp-old.md 2026-10-14T08:00:00Z" > "$HOME/.claude/pr-steps/$AH"; }
newpass() { echo "shape $T/sp-new.md 2026-10-15T09:00:00Z" >> "$HOME/.claude/pr-steps/$AH"; }
OLDR=$(gated sp-old-r "Done in abc1234."$'\n\n| Item | Old ⇒ new |\n|---|---|\n| `load()` | 6 ⇒ 7 |')
NEWR=$(gated sp-new-r "Done in abc1234."$'\n\n| Item | Old ⇒ new | Commit |\n|---|---|---|\n| `load()` | 7 ⇒ 9 | abc1234 |')
oldpass; pr7 "$AH" 'Fixes the leak.'
check "BLOCK: an ask after the head's pass, answered with no new pass (it landed no commit), naming the ask and pr-steps shape" 1 "$(asked "gh pr comment 7 -R o/r --body-file $OLDR")"
echo "shape $T/sp-carry.md 2026-10-15T09:00:00Z" >> "$HOME/.claude/pr-steps/$AH"
check "BLOCK: a carry recorded after the ask doesn't answer it" 1 "$(asked "gh pr comment 7 -R o/r --body-file $NEWR")"
oldpass; newpass
check "a pass recorded on the unchanged head after the ask answers it, whatever table the reply holds (the post review checks that)" "0 0" "$(asked "gh pr comment 7 -R o/r --body-file $NEWR") $(asked "gh pr comment 7 -R o/r --body-file $OLDR")"
oldpass; pr7 "$MH" 'Fixes the leak.'; python3 -c 'import json,sys; print(json.dumps([{"sha":sys.argv[1]},{"sha":sys.argv[2]}]))' "$AH" "$MH" > "$FX/repos_o_r_pulls_7_commits_per_page_100"
check "BLOCK: the maintainer's commits on top (a head with no record): the ask still needs a pass" 1 "$(asked "gh pr comment 7 -R o/r --body-file $NEWR")"
newpass
check "a pass after the ask on any of the PR's commits answers it" 0 "$(asked "gh pr comment 7 -R o/r --body-file $NEWR")"
oldpass
check "BLOCK: through gh api, a comment and a body PATCH on the PR" "1 1" "$(asked "gh api repos/o/r/issues/7/comments -F body=@$NEWR") $(asked "gh api -X PATCH repos/o/r/pulls/7 -F body=@$NEWR")"
check "BLOCK: the same through gh api's {owner}/{repo}, which gh fills from the checkout's repo" "1 1" "$(asked "cd $IDR && gh api 'repos/{owner}/{repo}/issues/7/comments' -F body=@$NEWR") $(asked "cd $IDR && gh api -X PATCH 'repos/{owner}/{repo}/pulls/7' -F body=@$NEWR")"
ODR="$T/odr"; git init -q "$ODR"; git -C "$ODR" remote add origin https://github.com/x/y.git
check "BLOCK: GH_REPO, on the command or inherited, fills {owner}/{repo} before the checkout's origin, as gh does" "1 1" "$(asked "cd $ODR && GH_REPO=o/r gh api 'repos/{owner}/{repo}/issues/7/comments' -F body=@$NEWR") $(GH_REPO=github.com/o/r asked "cd $ODR && gh api -X PATCH 'repos/{owner}/{repo}/pulls/7' -F body=@$NEWR")"
check "BLOCK: gh pr comment and gh pr ready without -R act on GH_REPO, on the command or inherited, before the checkout's origin" "1 1" "$(asked "cd $ODR && GH_REPO=o/r gh pr comment 7 --body-file $NEWR") $(GH_REPO=https://github.com/o/r asked "cd $ODR && gh pr ready 7")"
newpass
check "through gh api, the pass recorded after the ask answers it" "0 0" "$(asked "gh api repos/o/r/issues/7/comments -F body=@$NEWR") $(asked "gh api -X PATCH repos/o/r/pulls/7 -F body=@$NEWR")"
# every form gh takes for the target reaches the same check: a URL, a branch, an issue number that is a PR, gh pr ready; the current branch's PR (#6) is not the target
oldpass; echo 6 > "$FX/pr_view_current"; echo 7 > "$FX/pr_view_feature"
check "BLOCK: gh pr comment by URL or branch, gh issue comment on the PR's number, gh pr ready by URL" "1 1 1 1" "$(asked "gh pr comment https://github.com/o/r/pull/7 --body-file $NEWR") $(asked "gh pr comment feature -R o/r --body-file $NEWR") $(asked "gh issue comment 7 -R o/r --body-file $NEWR") $(asked 'gh pr ready https://github.com/o/r/pull/7')"
newpass
check "the same forms pass once the pass is recorded" "0 0 0 0" "$(asked "gh pr comment https://github.com/o/r/pull/7 --body-file $NEWR") $(asked "gh pr comment feature -R o/r --body-file $NEWR") $(asked "gh issue comment 7 -R o/r --body-file $NEWR") $(asked 'gh pr ready https://github.com/o/r/pull/7')"
rm -f "$FX/pr_view_current" "$FX/pr_view_feature"
# while the ask waits on its pass, a comment goes out once the session has promised the result in its watch dir's proposals-open.md;
# gh pr ready and a body edit always wait for the recorded pass
oldpass; HOLD=$(gated sp-hold-r "I'm running the refactor pass on the whole PR now; the ratings and their commits follow by 15:00 UTC.")
DONE=$(gated sp-done-b "The wrapper is fixed in abc1234.")
WR="$T/wr"; mkdir -p "$WR"; echo sess-r4 > "$WR/session"; echo "$WR" >> "$HOME/.claude/gh-watch-dirs.txt"
hold() { printf '%s\n' "$1" > "$WR/proposals-open.md"; CLAUDE_CODE_SESSION_ID=sess-r4 asked "${2:-gh pr comment 7 -R o/r --body-file $HOLD}"; }
check "BLOCK: a holding comment with no PROMISED line, the block naming that way through" "1 1" "$(hold '') $(grep -c "To comment before it .*'PROMISED o/r#7: the refactor pass's result by <time> (<draft>)'" "$T/err")"
PL="PROMISED o/r#7: the refactor pass's result by 15:00 UTC (sp-hold-r.md)"
check "the session's open PROMISED line for the PR's refactor result lets a comment through; another PR's, or a cleared one, doesn't" "0 1 1" "$(hold "$PL") $(hold "PROMISED o/r#8: the refactor pass's result (x.md)") $(hold "DONE https://example.invalid/c PROMISED o/r#7: the refactor pass's result (sp-hold-r.md)")"
check "BLOCK: with that PROMISED line, gh pr ready and a body edit (gh pr edit, gh api PATCH) still wait for the pass, saying so" "1 1 1 1" "$(hold "$PL" 'gh pr ready 7 -R o/r') $(hold "$PL" "gh pr edit 7 -R o/r --body-file $DONE") $(hold "$PL" "gh api -X PATCH repos/o/r/pulls/7 -F body=@$DONE") $(grep -c 'gh pr ready` and a body edit wait for the recorded pass' "$T/err")"
rm -rf "$WR"; sed -i "\#^$WR\$#d" "$HOME/.claude/gh-watch-dirs.txt"
rm -f "$FX/repos_o_r_issues_7" "$FX/repos_o_r_pulls_7" "$FX/repos_o_r_pulls_7_commits_per_page_100" "$HOME/.claude/pr-steps/$AH" "$HOME/.claude/refactor-asks.txt"
# ---------- preflight: no code in a repo and branch until the app was loaded in browser control ----------
P="$T/pf"; mkdir -p "$P"; git -C "$P" init -q -b feat
pf() { (cd "$P" && bash "$R/bin/pr-steps" preflight "$@" >/dev/null 2>&1; echo $?); }
pfurl() { (cd "$P" && CHROME="$T/bin/fakechrome" FAKE_DOM="$1" bash "$R/bin/pr-steps" preflight https://app.test --host-resolver-rules=x >/dev/null 2>&1; echo $?); }
pfedit() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$T" | python3 "$R/hooks/pre-design-gate.py" 2>/dev/null; echo $?; }
pfcommit() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"git commit -m x"},"cwd":sys.argv[1]}))' "$P" | python3 "$R/hooks/pre-bash-guard.py" 2>&1 >/dev/null; }
cat > "$T/bin/fakechrome" <<'EOF'
#!/bin/bash
[ -n "$FAKE_LOG" ] && echo "pulse=${PULSE_SERVER:-unset} $*" >> "$FAKE_LOG"
for x in "$@"; do case "$x" in --dump-dom) printf '%s' "$FAKE_DOM";; --screenshot=*) printf '\x89PNG\r\n\x1a\n' > "${x#--screenshot=}";; esac; done
EOF
chmod +x "$T/bin/fakechrome"
check "BLOCK: an edit in a repo and branch with no preflight" 2 "$(pfedit "$P/a.ts")"
check "BLOCK: a new file in a new folder there" 2 "$(pfedit "$P/new/dir/a.ts")"
check "BLOCK: git commit there, saying how to record it" 1 "$(pfcommit | grep -c 'pr-steps preflight <its URL>')"
mkdir -p "$T/nogit"; check "a path outside any git work tree is free" 0 "$(pfedit "$T/nogit/a.md")"
check "BLOCK: none, because with no reason" 1 "$(pf 'none, because ')"
printf 'x' > "$T/pf.png"; check "BLOCK: a screenshot that isn't a PNG" 1 "$(pf "$T/pf.png")"
printf '\x89PNG\r\n\x1a\n' > "$T/pf.png"; touch -d '-20 min' "$T/pf.png"; check "BLOCK: a screenshot older than 10 minutes" 1 "$(pf "$T/pf.png")"
check "BLOCK: a URL that shows Chrome's error page" 1 "$(pfurl '<div id="main-frame-error">This site can’t be reached</div>')"
check "BLOCK: a URL that renders a blank page" 1 "$(pfurl '<html><body><div id="root"></div><script>boot()</script></body></html>')"
check "an edit still waits after refused preflights" 2 "$(pfedit "$P/a.ts")"
check "a URL that renders records the screenshot Chrome took" 0 "$(pfurl '<body><h1>Dashboard</h1></body>')"
check "an edit passes once the branch has its preflight" 0 "$(pfedit "$P/a.ts")"
check "git commit passes it too" 0 "$(pfcommit | grep -c 'pr-steps preflight')"
git -C "$P" checkout -q -b other
check "BLOCK: another branch needs its own preflight" 2 "$(pfedit "$P/a.ts")"
Q="$T/q"; git init -q "$Q"; git -C "$Q" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i; qb=$(git -C "$Q" symbolic-ref --short HEAD)
(cd "$Q" && bash "$R/bin/pr-steps" preflight 'none, because the test repo has no UI' >/dev/null 2>&1)
git -C "$Q" config remote.origin.url "$Q"; git -C "$Q" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'; git -C "$Q" update-ref "refs/remotes/origin/$qb" HEAD
git -C "$Q" checkout -q -b cleanup "origin/$qb" 2>/dev/null
qedit() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1]},"cwd":sys.argv[1]}))' "$Q/a.ts" | python3 "$R/hooks/pre-design-gate.py" 2>/dev/null; echo $?; }
check "a local branch tracking the recorded branch shares its preflight; one tracking nothing doesn't" "0 2" "$(qedit) $(git -C "$Q" checkout -q -b loose; qedit)"
touch "$T/pf.png"; check "a PNG the browser MCP just took records" 0 "$(pf "$T/pf.png")"
git -C "$P" checkout -q -b docs
check "none, because with its reason records" 0 "$(pf 'none, because it only changes a CLI flag')"
check "an edit passes after it" 0 "$(pfedit "$P/a.ts")"
check "preflight's Chrome runs muted and without the WSLg audio server" "2 2" "$( (cd "$P" && PULSE_SERVER=unix:/mnt/wslg/PulseServer FAKE_LOG="$T/chrome.log" CHROME="$T/bin/fakechrome" FAKE_DOM='<html><body>app</body></html>' bash "$R/bin/pr-steps" preflight https://app.test >/dev/null 2>&1); grep -c -- '--mute-audio' "$T/chrome.log") $(grep -c '^pulse=unset ' "$T/chrome.log")"
# ---------- under T3 Code, Codex starts through delegate_task, not a shell ----------
# the hook's nearest `claude` ancestor is the session; T3 starts it with its MCP server in --mcp-config
cx() { # <mcp config> <command>: the guard run under a claude process given that config
  (exec -a claude "$(python3 -c 'import sys; print(sys.executable)')" -c 'import json, subprocess, sys
r = subprocess.run(["python3", sys.argv[4]], input=json.dumps({"tool_input": {"command": sys.argv[3]}, "cwd": sys.argv[5]}), capture_output=True, text=True)
print(r.returncode)' --mcp-config "$1" "$2" "$R/hooks/pre-bash-guard.py" "$T")
}
T3CFG='{"mcpServers":{"t3-code":{"type":"http","url":"http://127.0.0.1:3774/mcp"}}}'
check "BLOCK: codex exec under T3" 2 "$(cx "$T3CFG" 'codex exec -m m -o /tmp/o "$(cat /tmp/p)" < /dev/null')"
check "BLOCK: codex exec resume under T3" 2 "$(cx "$T3CFG" 'codex exec resume -c sandbox_mode=x abc "more"')"
check "BLOCK: codex exec through bash -c under T3" 2 "$(cx "$T3CFG" "bash -lc 'cd /tmp && FOO=1 codex exec hi'")"
check "BLOCK: codex exec inside \$(...) under T3" 2 "$(cx "$T3CFG" 'out=$(codex exec hi)')"
check "codex exec without T3 (a terminal session) passes" 0 "$(cx '{"mcpServers":{}}' 'codex exec -m m hi')"
check "codex exec through bash -c without T3 passes" 0 "$(cx '{"mcpServers":{}}' "bash -c 'codex exec hi'")"
check "codex login under T3 passes" 0 "$(cx "$T3CFG" 'codex login status')"
# ---------- pre-design-gate: Tier M code waits for prior-art.md and decisions/*.md ----------
D="$T/dg"; mkdir -p "$D" "$D-work"; git -C "$D" init -q
(cd "$D" && bash "$R/bin/pr-steps" preflight 'none, because the design gate is tested here' >/dev/null)
gate() { python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1],"tool_input":json.loads(sys.argv[2]),"cwd":sys.argv[3]}))' "$1" "$2" "$D" | python3 "$R/hooks/pre-design-gate.py" 2>/dev/null; echo $?; }
check "no scope.md: an edit passes" 0 "$(gate Edit "{\"file_path\":\"$D/a.ts\"}")"
printf 'Tier: M, because x\n' > "$D-work/scope.md"
check "BLOCK: Tier M edit with no prior art or decision" 2 "$(gate Edit "{\"file_path\":\"$D/a.ts\"}")"
check "BLOCK: Tier M implementation agent with no decision" 2 "$(gate mcp__t3-code__delegate_task '{"role":"implementation"}')"
check "a research agent passes" 0 "$(gate mcp__t3-code__delegate_task '{"role":"research"}')"
check "an artifact-root write passes" 0 "$(gate Write "{\"file_path\":\"$D-work/prior-art.md\"}")"
touch "$D-work/prior-art.md"; mkdir -p "$D-work/design"; touch "$D-work/design/x.debate.md" "$D-work/design/x.review.md"
check "BLOCK: Tier M edit with only the design debate and review records" 2 "$(gate Edit "{\"file_path\":\"$D/a.ts\"}")"
mkdir -p "$D-work/decisions"; touch "$D-work/decisions/x.md"
check "Tier M edit passes once prior art and a decision exist" 0 "$(gate Edit "{\"file_path\":\"$D/a.ts\"}")"
DW="$HOME/.mergeworthy/work/dg"; D="$DW/repo"; mkdir -p "$D"; git -C "$D" init -q  # the work folder holding the checkout
(cd "$D" && bash "$R/bin/pr-steps" preflight 'none, because the design gate is tested here' >/dev/null)
printf 'Tier: M, because x\n' > "$DW/scope.md"
check "BLOCK: in ~/.mergeworthy/work/<task>/, a Tier M edit and an implementation agent with no prior art or decision" "2 2" "$(gate Edit "{\"file_path\":\"$D/a.ts\"}") $(gate mcp__t3-code__delegate_task '{"role":"implementation"}')"
check "there, an artifact-root write passes" 0 "$(gate Write "{\"file_path\":\"$DW/prior-art.md\"}")"
touch "$DW/prior-art.md"; mkdir -p "$DW/decisions"; touch "$DW/decisions/x.md"
check "there, a Tier M edit passes once prior art and a decision exist" 0 "$(gate Edit "{\"file_path\":\"$D/a.ts\"}")"
# ---------- pre-design-gate and pre-bash-guard: no file change in a repo before this session read its AGENTS.md and CLAUDE.md ----------
I="$T/instr"; mkdir -p "$I/sub"; git -C "$I" init -q; printf 'rules\n' > "$I/AGENTS.md"; printf '@AGENTS.md\n' > "$I/CLAUDE.md"
IN="$T/instr-none"; mkdir -p "$IN"; git -C "$IN" init -q
for x in "$I" "$IN"; do (cd "$x" && bash "$R/bin/pr-steps" preflight 'none, because instruction reads are tested here' >/dev/null); done
ir_tr() { # <transcript> <event>...: read:<path> | bash:<cwd>|<command> | compact; failread: and failbash: get an error result
  python3 - "$@" <<'EOF'
import json, sys
out = open(sys.argv[1], 'w')
w = lambda e: out.write(json.dumps(e, separators=(',', ':')) + '\n')  # Claude Code writes compact JSON
def call(n, cwd, name, i, err):
    w({"type": "assistant", "cwd": cwd, "message": {"role": "assistant", "content": [{"type": "tool_use", "id": f"toolu_{n}", "name": name, "input": i}]}})
    w({"type": "user", "cwd": cwd, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": f"toolu_{n}", "content": "Permission denied" if err else "rules", "is_error": err}]}})
w({"type": "user", "message": {"role": "user", "content": "fix the bug"}})
for n, ev in enumerate(sys.argv[2:]):
    kind, _, v = ev.partition(':')
    if kind.endswith('read'): call(n, '/', 'Read', {"file_path": v}, kind.startswith('fail'))
    elif kind.endswith('bash'): call(n, v.split('|', 1)[0], 'Bash', {"command": v.split('|', 1)[1]}, kind.startswith('fail'))
    elif kind == 'compact': w({"type": "system", "subtype": "compact_boundary", "content": "Conversation compacted"})
EOF
}
iedit() { # <transcript> <tool> <file> [extra hook input as JSON]: pre-design-gate's exit code (its message in $T/ierr)
  python3 -c 'import json,sys; d={"tool_name":sys.argv[2],"tool_input":{("notebook_path" if sys.argv[2]=="NotebookEdit" else "file_path"):sys.argv[3]},"cwd":sys.argv[4],"transcript_path":sys.argv[1]}; d.update(json.loads(sys.argv[5])); print(json.dumps(d))' "$1" "$2" "$3" "$T" "${4:-{\}}" | python3 "$R/hooks/pre-design-gate.py" 2>"$T/ierr"; echo $?
}
ibash() { # <transcript> <command>: pre-bash-guard's exit code for the command run in $I
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[2]},"cwd":sys.argv[3],"transcript_path":sys.argv[1]}))' "$1" "$2" "$I" | python3 "$R/hooks/pre-bash-guard.py" 2>/dev/null; echo $?
}
IT="$T/instr.jsonl"; ir_tr "$IT"
check "BLOCK: an edit in a repo whose root has AGENTS.md and CLAUDE.md, before reading them, naming both" "2 1" "$(iedit "$IT" Edit "$I/a.ts") $(grep -c "read this repo's instructions first.*$I/AGENTS.md, $I/CLAUDE.md" "$T/ierr")"
check "BLOCK: Write, MultiEdit and NotebookEdit there, and a new file in a new folder" "2 2 2 2" "$(iedit "$IT" Write "$I/b.ts") $(iedit "$IT" MultiEdit "$I/a.ts") $(iedit "$IT" NotebookEdit "$I/n.ipynb") $(iedit "$IT" Write "$I/new/dir/c.ts")"
ir_tr "$IT" "read:$I/AGENTS.md"; check "BLOCK: with only AGENTS.md read, naming CLAUDE.md" "2 1" "$(iedit "$IT" Edit "$I/a.ts") $(grep -c "follow them: $I/CLAUDE.md$" "$T/ierr")"
ir_tr "$IT" "read:$I/AGENTS.md" "read:$I/CLAUDE.md"; check "an edit passes once both were read" 0 "$(iedit "$IT" Edit "$I/sub/a.ts")"
ir_tr "$IT" "bash:$T|cd $I && cat AGENTS.md" "bash:$I|sed -n 1,40p CLAUDE.md"; check "a cat after cd, and a sed -n, count as reads" 0 "$(iedit "$IT" Edit "$I/a.ts")"
ir_tr "$IT" "bash:$I|sed -i s/a/b/ AGENTS.md" "read:$I/CLAUDE.md"; check "BLOCK: sed -i doesn't count as a read" 2 "$(iedit "$IT" Edit "$I/a.ts")"
ir_tr "$IT" "read:$I/AGENTS.md" "read:$I/CLAUDE.md" compact; check "BLOCK: reads before the last compaction don't count" 2 "$(iedit "$IT" Edit "$I/a.ts")"
check "BLOCK: no transcript at all" 2 "$(iedit "$T/no-such.jsonl" Edit "$I/a.ts")"
SUB="$T/instr-agent.jsonl"; ir_tr "$SUB"; ir_tr "$IT" "read:$I/AGENTS.md" "read:$I/CLAUDE.md"
check "BLOCK: a subagent whose own transcript has no read, though its session's has" 2 "$(iedit "$IT" Edit "$I/a.ts" "{\"agent_id\":\"a1\",\"agent_transcript_path\":\"$SUB\"}")"
ir_tr "$IT"
check "a repo without AGENTS.md or CLAUDE.md is never blocked" 0 "$(iedit "$IT" Edit "$IN/a.ts")"
check "a path outside any git repo is never blocked" 0 "$(iedit "$IT" Write "$T/nogit/a.md")"
check "BLOCK: a command writing into that repo before the reads: a redirect, tee, sed -i, cp" "2 2 2 2" "$(ibash "$IT" "echo x > $I/a.txt") $(ibash "$IT" "echo x | tee sub/b.txt") $(ibash "$IT" "sed -i s/a/b/ $I/a.ts") $(ibash "$IT" "cp /etc/hostname $I/h")"
check "a command reading there, or writing outside it, passes" "0 0 0" "$(ibash "$IT" "cat $I/AGENTS.md") $(ibash "$IT" "echo x > /dev/null") $(ibash "$IT" "echo x > $T/nogit/a.md")"
ir_tr "$IT" "read:$I/AGENTS.md" "read:$I/CLAUDE.md"; check "a command writing into it passes once both were read" 0 "$(ibash "$IT" "echo x > $I/a.txt")"
ir_tr "$IT"; echo x > "$T/nogit/src"
check "BLOCK: cp, mv and install into the repo's folder itself (a folder destination)" "2 2 2 2" "$(ibash "$IT" "cp $T/nogit/src .") $(ibash "$IT" "mv $T/nogit/src .") $(ibash "$IT" "install $T/nogit/src .") $(ibash "$IT" "cp $T/nogit/src $I/")"
check "sed -i on a file outside the repo passes: its script is no path" "0 0" "$(ibash "$IT" "sed -i 's/foo/bar/' $T/nogit/src") $(ibash "$IT" "sed -i -e s/foo/bar/ $T/nogit/src")"
check "BLOCK: sed -i -e on a file inside it" 2 "$(ibash "$IT" "sed -i -e s/foo/bar/ $I/a.ts")"
check "BLOCK: cp and mv into the repo with stderr or stdout redirected, sed -i.bak, cp -t <repo folder>" "2 2 2 2" "$(ibash "$IT" "cp $T/nogit/src $I/d 2>/dev/null") $(ibash "$IT" "mv $T/nogit/src $I/d > /dev/null") $(ibash "$IT" "sed -i.bak s/a/b/ $I/a.ts") $(ibash "$IT" "cp -t $I $T/nogit/src")"
check "writes outside the repo pass with their redirections: sudo tee > /dev/null, tee 2>&1, sed -i 2>/dev/null, BSD sed -i '' and -Ei ''" "0 0 0 0 0" "$(ibash "$IT" "echo x | sudo tee $T/nogit/src > /dev/null") $(ibash "$IT" "echo x | tee $T/nogit/src 2>&1") $(ibash "$IT" "sed -i s/a/b/ $T/nogit/src 2>/dev/null") $(ibash "$IT" "sed -i '' s/a/b/ $T/nogit/src") $(ibash "$IT" "sed -Ei '' s/a/b/ $T/nogit/src")"
ir_tr "$IT" "failread:$I/AGENTS.md" "failread:$I/CLAUDE.md"; check "BLOCK: reads whose result is an error" 2 "$(iedit "$IT" Edit "$I/a.ts")"
ir_tr "$IT" "failbash:$I|cat AGENTS.md CLAUDE.md"; check "BLOCK: a cat whose result is an error" 2 "$(iedit "$IT" Edit "$I/a.ts")"
ir_tr "$IT" "bash:$I|cat \"\$PWD/AGENTS.md\" \"\${PWD}/CLAUDE.md\""; check "a cat of \$PWD/AGENTS.md counts as a read" 0 "$(iedit "$IT" Edit "$I/a.ts")"
IL="$T/instr-link"; mkdir -p "$IL"; git -C "$IL" init -q; printf 'rules\n' > "$T/shared-agents"; ln -s "$T/shared-agents" "$IL/AGENTS.md"
(cd "$IL" && bash "$R/bin/pr-steps" preflight 'none, because instruction reads are tested here' >/dev/null)
ir_tr "$IT" "read:$T/shared-agents"; check "a Read of a symlinked AGENTS.md's target counts" 0 "$(iedit "$IT" Edit "$IL/a.ts")"
# ---------- pre-skill-gate: an action waits for the skills its always-on row names, opened since the last compaction ----------
sg_tr() { # <transcript> <event>...: skill:<input.skill> | typed:<name> | compact | text
  python3 - "$@" <<'EOF'
import json, sys
out = open(sys.argv[1], 'w')
w = lambda e: out.write(json.dumps(e) + '\n')
w({"type": "user", "message": {"role": "user", "content": "open a PR for the fix"}})
for ev in sys.argv[2:]:
    kind, _, v = ev.partition(':')
    if kind == 'skill':
        w({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_1", "name": "Skill", "input": {"skill": v}}]}})
        w({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_1", "content": f"Launching skill: {v}"}]}})
    elif kind == 'typed':
        w({"type": "user", "message": {"role": "user", "content": f"<command-message>{v}</command-message>\n<command-name>/{v}</command-name>\n<command-args></command-args>"}})
    elif kind == 'compact':  # the shapes Claude Code writes: the boundary, then the summary (whose text must not count)
        w({"parentUuid": None, "type": "system", "subtype": "compact_boundary", "content": "Conversation compacted", "level": "info", "compactMetadata": {"trigger": "auto"}})
        w({"type": "user", "isCompactSummary": True, "isVisibleInTranscriptOnly": True, "message": {"role": "user", "content": "This session is being continued from a previous conversation. Summary: opened <command-name>/mergeworthy:merging</command-name> and the Skill tool"}})
    elif kind in ('attached', 'cut'):  # the harness re-attaches each invoked skill after a compaction, a long one cut short
        w({"type": "attachment", "attachment": {"type": "invoked_skills", "skills": [{"name": n, "path": "/p", "content": "# Skill" + ("\n[... skill content truncated for compaction; use Read]" if kind == 'cut' else "")} for n in v.split(',')]}})
    else:
        w({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "Working on it."}]}})
EOF
}
sg_in() { # <tool> <tool_input json> [transcript] [agent_id]
  python3 -c 'import json,sys; d={"tool_name":sys.argv[1],"tool_input":json.loads(sys.argv[2]),"cwd":sys.argv[3],"session_id":"s1","transcript_path":sys.argv[4]}
if sys.argv[5]: d["agent_id"]=sys.argv[5]
print(json.dumps(d))' "$1" "$2" "$T" "${3:-$T/sg.jsonl}" "${4:-}"
}
sg() { sg_in "$@" | python3 "$R/hooks/pre-skill-gate.py" 2>"$T/sg.err"; echo $?; }
sgb() { sg Bash "$(python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1]}))' "$1")"; }
sg_tr "$T/sg.jsonl" text
check "BLOCK: gh pr create without its skills opened" 2 "$(sgb "gh pr create --draft --body-file $T/b.md")"
check "the block names exactly post, pull-request, task and writing" "mergeworthy:post mergeworthy:pull-request mergeworthy:task mergeworthy:writing" "$(grep -o '^- mergeworthy:[a-z-]*' "$T/sg.err" | cut -c3- | sort | xargs)"
check "the block gives the reason from the always-on row" 1 "$(grep -c '^- mergeworthy:writing, for gh pr create: Before writing any words a person reads' "$T/sg.err")"
sg_tr "$T/sg.jsonl" skill:mergeworthy:pull-request text skill:writing skill:post skill:task
check "gh pr create passes once its skills were opened (plugin-qualified or bare)" 0 "$(sgb "gh pr create --draft --body-file $T/b.md")"
sg_tr "$T/sg.jsonl" skill:mergeworthy:pull-request skill:mergeworthy:writing skill:mergeworthy:post compact text
check "BLOCK: skills opened before the last compaction don't count" 2 "$(sgb "gh pr create --draft --body-file $T/b.md")"
check "the compact summary's text doesn't open merging either" 2 "$(sgb 'git push')"
sg_tr "$T/sg.jsonl" skill:mergeworthy:writing compact skill:mergeworthy:pull-request skill:mergeworthy:writing skill:mergeworthy:post skill:mergeworthy:task
check "opened again after the compaction: passes" 0 "$(sgb "gh pr create --draft --body-file $T/b.md")"
sg_tr "$T/sg.jsonl" compact attached:mergeworthy:pull-request,mergeworthy:writing,mergeworthy:task cut:mergeworthy:post
check "skills the harness re-attached whole after the compaction count; one cut short doesn't" "2 mergeworthy:post" "$(sgb "gh pr create --draft --body-file $T/b.md") $(grep -o '^- mergeworthy:[a-z-]*' "$T/sg.err" | cut -c3- | xargs)"
check "BLOCK: gh pr ready also needs merging" 2 "$(sgb 'gh pr ready 5')"
check "the ready block names only merging" "mergeworthy:merging" "$(grep -o '^- mergeworthy:[a-z-]*' "$T/sg.err" | cut -c3- | xargs)"
check "gh pr ready --undo, back to draft, never waits" 0 "$(sgb 'gh pr ready 5 --undo')"
check "BLOCK: git push without merging" 2 "$(sgb 'cd /x && git -C /x push origin HEAD')"
check "BLOCK: gh pr merge without merging" 2 "$(sgb 'gh pr merge 5 --squash')"
sg_tr "$T/sg.jsonl" typed:mergeworthy:merging skill:task skill:pull-request
check "a skill the user typed as /mergeworthy:merging counts" 0 "$(sgb 'git push')"
sg_tr "$T/sg.jsonl" skill:mergeworthy:merging
check "a push needs only merging here: a collaboration push waits for scope.md in pre-bash-guard" 0 "$(sgb 'git push')"
sg_tr "$T/sg.jsonl" skill:other:merging
check "BLOCK: another plugin's skill of the same name doesn't count" 2 "$(sgb 'git push')"
for c in 'git status' 'git push --dry-run' 'gh pr view 5 --comments' 'gh pr list' 'gh issue view 3' 'gh api repos/o/r/pulls/5' \
         'gh api repos/o/r/issues/comments/9/reactions -f content=eyes' 'gh pr create --help' 'ls skills/writing' 'gh pr ready 5 --undo'; do
  check "read-only passes: $c" 0 "$(sgb "$c")"
done
check "a GraphQL reaction posts no text; a comment mutation does" "False True" "$(python3 - "$R/hooks" <<'PY2'
import sys; sys.path.insert(0, sys.argv[1]); import shellcmd as s
print(*[s.api_call(['graphql', '-f', 'query=mutation{%s(input:{subjectId:"x"}){x}}' % m])[4] for m in ('addReaction', 'addComment')])
PY2
)"
sg_tr "$T/sg.jsonl" text
check "BLOCK: gh api comment POST" 2 "$(sgb "gh api repos/o/r/issues/5/comments -F body=@$T/d.md")"
check "the post block names post and writing" "mergeworthy:post mergeworthy:writing" "$(grep -o '^- mergeworthy:[a-z-]*' "$T/sg.err" | cut -c3- | sort | xargs)"
check "BLOCK: a review comment edit (PATCH)" 2 "$(sgb "gh api -X PATCH repos/o/r/pulls/comments/9 -F body=@$T/d.md")"
check "BLOCK: gh pr review" 2 "$(sgb "gh pr review 5 --comment --body-file $T/d.md")"
check "the review block names review, post and writing" "mergeworthy:post mergeworthy:review mergeworthy:writing" "$(grep -o '^- mergeworthy:[a-z-]*' "$T/sg.err" | cut -c3- | sort | xargs)"
check "BLOCK: gh issue edit of the body" 2 "$(sgb "gh issue edit 5 --body-file $T/d.md")"
check "a label-only issue edit posts nothing" 0 "$(sgb 'gh issue edit 5 --add-label bug')"
check "BLOCK: gh issue create" 2 "$(sgb "gh issue create --title x --body-file $T/d.md")"
check "the issue block names open-issue, post, task and writing" "mergeworthy:open-issue mergeworthy:post mergeworthy:task mergeworthy:writing" "$(grep -o '^- mergeworthy:[a-z-]*' "$T/sg.err" | cut -c3- | sort | xargs)"
check "BLOCK: post-lint without writing" 2 "$(sgb "post-lint $T/d.md --kind reply")"
check "a reply's lint names reply, post and writing" "mergeworthy:post mergeworthy:reply mergeworthy:writing" "$(grep -o '^- mergeworthy:[a-z-]*' "$T/sg.err" | cut -c3- | sort | xargs)"
sgb "post-lint $T/d.md --kind=proposal" >/dev/null
check "a proposal's lint names design" 1 "$(grep -c '^- mergeworthy:design, for post-lint proposal' "$T/sg.err")"
sgb "post-lint $T/d.md --kind tracker" >/dev/null
check "a tracker's lint names task" 1 "$(grep -c '^- mergeworthy:task, for post-lint tracker' "$T/sg.err")"
sgb "post-lint $T/d.md --kind inline" >/dev/null
check "an inline comment's lint counts as a reply's" 1 "$(grep -c '^- mergeworthy:reply, for post-lint reply' "$T/sg.err")"
check "BLOCK: gh-watch-start without task" 2 "$(sgb "gh-watch-start $T o/r")"
check "BLOCK: building a thread record without post" 2 "$(sgb "thread-context o/r#5 --out $T/drafts/x/thread-context.md")"
check "thread-context --latest and --verify only read" "0 0" "$(sgb 'thread-context --latest o/r#5') $(sgb "thread-context --verify $T/x.md")"
check "BLOCK: an upload without evidence" 2 "$(sgb "gh pr edit 5 --body-file $T/b.md --attach /a/01.png")"
check "the upload block names evidence" 1 "$(grep -c '^- mergeworthy:evidence, for an upload' "$T/sg.err")"
check "BLOCK: gate-pass by its path" 2 "$(sgb "python3 ~/.mergeworthy/current/bin/gate-pass $T/d.md $T/r.out")"
check "BLOCK: pr-steps shape" 2 "$(sgb "pr-steps shape $T/o.md")"
check "the shape block names converge" "mergeworthy:converge" "$(grep -o '^- mergeworthy:[a-z-]*' "$T/sg.err" | cut -c3- | sort | xargs)"
check "BLOCK: codex exec starts an agent" 2 "$(sgb 'codex exec "review the diff"')"
check "BLOCK: the Agent tool without delegate" 2 "$(sg Agent '{"prompt":"x"}')"
check "BLOCK: delegate_task without delegate" 2 "$(sg mcp__t3-code__delegate_task '{"task":"x"}')"
check "BLOCK: editing a skill" 2 "$(sg Edit '{"file_path":"/r/skills/writing/SKILL.md"}')"
check "the skill-edit block names rules" "mergeworthy:rules" "$(grep -o '^- mergeworthy:[a-z-]*' "$T/sg.err" | cut -c3- | xargs)"
check "BLOCK: writing a brief" 2 "$(sg Write '{"file_path":"/w/drafts/impl-brief.md"}')"
check "the brief block names delegate" "mergeworthy:delegate" "$(grep -o '^- mergeworthy:[a-z-]*' "$T/sg.err" | cut -c3- | xargs)"
check "BLOCK: editing AGENTS.md" 2 "$(sg Edit '{"file_path":"/r/AGENTS.md"}')"
check "an ordinary edit passes" 0 "$(sg Edit '{"file_path":"/r/src/debrief.ts"}')"
sg_tr "$T/sg.jsonl" skill:mergeworthy:delegate skill:mergeworthy:rules
check "the Agent tool passes once delegate was opened" 0 "$(sg Agent '{"prompt":"x"}')"
check "editing a skill passes once rules was opened" 0 "$(sg Edit '{"file_path":"/r/skills/writing/SKILL.md"}')"
mkdir -p "$T/s1/subagents"; sg_tr "$T/s1/subagents/agent-a1.jsonl" skill:mergeworthy:merging skill:mergeworthy:task skill:mergeworthy:pull-request
check "a subagent's own Skill calls count for it" 0 "$(sg_in Bash '{"command":"git push"}' "$T/sg.jsonl" a1 | python3 "$R/hooks/pre-skill-gate.py" 2>/dev/null; echo $?)"
sg_tr "$T/s1/subagents/agent-a1.jsonl" text; sg_tr "$T/sg.jsonl" skill:mergeworthy:merging
check "BLOCK: the parent's skills aren't in a subagent's context" 2 "$(sg_in Bash '{"command":"git push"}' "$T/sg.jsonl" a1 | python3 "$R/hooks/pre-skill-gate.py" 2>/dev/null; echo $?)"
check "BLOCK: a gated action whose transcript can't be read, saying so; a read-only one passes" "2 1 0" "$(sg Bash '{"command":"git push"}' "$T/none.jsonl") $(grep -c "transcript.*can't be read" "$T/sg.err") $(sg Bash '{"command":"git status"}' "$T/none.jsonl")"
old_tr() { # <transcript>: a session that opened the old catalog's core, github-threads, writing and delegating
  sg_tr "$1" skill:mergeworthy:core skill:mergeworthy:github-threads skill:mergeworthy:writing skill:mergeworthy:delegating; }
olds() { # <session id>: the four actions an old-catalog session takes, each 0 when its old skills count
  for c in '{"command":"gh-watch-start /w o/r"}' '{"command":"post-lint /w/d.md --kind reply"}'; do
    python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":json.loads(sys.argv[1]),"session_id":sys.argv[2],"transcript_path":sys.argv[3]}))' "$c" "$1" "$T/old.jsonl" | python3 "$R/hooks/pre-skill-gate.py" 2>/dev/null; echo -n "$? "; done
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Agent","tool_input":{"prompt":"x"},"session_id":sys.argv[1],"transcript_path":sys.argv[2]}))' "$1" "$T/old.jsonl" | python3 "$R/hooks/pre-skill-gate.py" 2>/dev/null; echo -n "$? "
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":"/r/skills/writing/SKILL.md"},"session_id":sys.argv[1],"transcript_path":sys.argv[2]}))' "$1" "$T/old.jsonl" | python3 "$R/hooks/pre-skill-gate.py" 2>/dev/null; echo $?; }
ss() { # <session id> <source> <plugin root>: the SessionStart hook, as Claude Code runs it from the session's own plugin
  printf '{"session_id":"%s","source":"%s"}' "$1" "$2" | CLAUDE_PLUGIN_ROOT="$3" bash "$R/hooks/session-start" >/dev/null 2>&1; }
V1="$T/v1-plugin"; mkdir -p "$V1/skills/core"; touch "$V1/always-on.md"
old_tr "$T/old.jsonl"
check "no catalog record (started before this install): its old skills satisfy their successors" "0 0 0 0" "$(olds s-none)"
ss s-v1 startup "$V1"; check "the record names the catalog of the session's own plugin" "v1 startup" "$(cut -d' ' -f2,3 "$HOME/.mergeworthy/sessions/s-v1")"
check "a session on the old catalog: old skills still count" "0 0 0 0" "$(olds s-v1)"
ss s-v1 compact "$V1"; check "after compaction, still on the old catalog: old skills count" "0 0 0 0" "$(olds s-v1)"
ss s-v1 resume "$R"; check "BLOCK: resumed on the skill graph, the old names no longer count" "2 2 2 2" "$(olds s-v1)"
ss s-new startup "$R"; check "BLOCK: a session started on the skill graph gets no transition" "2 2 2 2" "$(olds s-new)"
R2="$T/reinstall"; mkdir -p "$R2/skills/task"; touch "$R2/skills/task/SKILL.md" "$R2/always-on.md"
ss s-new compact "$R2"; check "BLOCK: a reinstall of the skill graph keeps it on the new names" "2 2 2 2" "$(olds s-new)"
check "BLOCK: no transcript, whatever the record" 2 "$(sg_in Bash '{"command":"gh-watch-start /w o/r"}' "$T/none.jsonl" | python3 "$R/hooks/pre-skill-gate.py" 2>/dev/null; echo $?)"
check "the gate's table and always-on.md's rows agree" ok "$(python3 - "$R" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('sg', sys.argv[1] + '/hooks/pre-skill-gate.py'); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
gated = {s for v in m.ACTIONS.values() for s in v}
rows = set(m.rows())
print('ok' if rows and gated | m.UNGATED == rows and not gated & m.UNGATED else f'gated-only {gated - rows}, ungated-only {m.UNGATED - rows}, rows with no decision {rows - gated - m.UNGATED}, both {gated & m.UNGATED}')
EOF
)"
check "hooks.json runs the gate on Bash, the agent launchers and the editors" ok "$(python3 - "$R" <<'EOF'
import json, re, sys
pre = json.load(open(sys.argv[1] + '/hooks/hooks.json'))['hooks']['PreToolUse']
m = [e['matcher'] for e in pre if any('pre-skill-gate.py' in h['command'] for h in e['hooks'])]
tools = ['Bash', 'Agent', 'Task', 'Write', 'Edit', 'MultiEdit', 'NotebookEdit', 'mcp__t3-code__delegate_task', 'mcp__t3-code__t3_thread_launch']
print('ok' if len(m) == 1 and all(re.search(m[0], t) for t in tools) and not re.search(m[0], 'Read') else m)
EOF
)"
# ---------- pre-bash-guard: never kill a running agent ----------
printf '#!/bin/sh\nsleep 600\n' > "$T/claude"; chmod +x "$T/claude"
"$T/claude" --output-format stream-json >/dev/null 2>&1 & APID=$!
sleep 600 >/dev/null 2>&1 & OPID=$!
sleep 0.3
kill_guard() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"kill "+sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$T" | python3 "$R/hooks/pre-bash-guard.py" 2>/dev/null; echo $?; }
check "BLOCK: kill of an agent's claude process" 2 "$(kill_guard $APID)"
check "kill of an ordinary process passes" 0 "$(kill_guard $OPID)"
kill $(ps -o pid= --ppid $APID) $APID $OPID 2>/dev/null
# ---------- pre-bash-guard: a compose stack takes no fixed host port or container name ----------
printf '#!/bin/sh\ncase " $* " in *" config "*) f=$DC_FX; while [ $# -gt 0 ]; do case "$1" in -f) f=$2;; --file=*) f=${1#--file=};; esac; shift; done; [ -f "$f" ] && cat "$f";; esac\n' > "$T/bin/docker"; chmod +x "$T/bin/docker"
echo '{"services":{"db":{"ports":[{"target":5432,"published":"5432"}]}}}' > "$T/fixed.json"
echo '{"services":{"web":{"container_name":"web","ports":[{"target":80}]}}}' > "$T/named.json"
echo '{"services":{"web":{"ports":[{"target":80}]}}}' > "$T/assigned.json"
dc_guard() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$T" | python3 "$R/hooks/pre-bash-guard.py" 2>"$T/err"; echo $?; }
check "BLOCK: compose up publishing a fixed host port" 2 "$(dc_guard "DC_FX=$T/fixed.json docker compose -p x up -d")"
check "BLOCK: compose up with a container_name" 2 "$(dc_guard "DC_FX=$T/named.json docker compose -p x up -d")"
check "compose up with Docker-assigned ports passes" 0 "$(dc_guard "DC_FX=$T/assigned.json docker compose -p x up -d")"
check "compose up on the usual ports when the user asked passes" 0 "$(dc_guard "MERGEWORTHY_HOST_PORTS=user-asked DC_FX=$T/fixed.json docker compose -p x up -d")"
check "BLOCK: compose up whose config fails (its ports can't be checked)" 2 "$(dc_guard "DC_FX=$T/missing.json docker compose -p x up -d")"
cp "$T/assigned.json" "$HOME/assigned.json"
check "compose up with a file under ~ passes" 0 "$(dc_guard 'docker compose -f ~/assigned.json -p x up -d')"
check "compose up with a file under a dir the line set passes" 0 "$(dc_guard "W=$T; docker compose -f \$W/assigned.json -p x up -d")"
check "BLOCK: compose up with --file= under a dir the line set, publishing a fixed host port" "2 1" "$(dc_guard "W=$T; docker compose --file=\$W/fixed.json -p x up -d") $(grep -c 'db host port 5432' "$T/err")"
check "BLOCK: compose up with a file path it can't tell, naming it" "2 1" "$(dc_guard 'docker compose -f $NOPE_DIR/c.yml -p x up -d') $(grep -c "can't tell.*NOPE_DIR/c.yml" "$T/err")"
printf 'See #7.\n' > "$T/ref.md"
check "post-lint: a 404 reference doesn't exist" 1 "$(python3 "$R/bin/post-lint" "$T/ref.md" --kind reply --repo o/r --parent none 2>&1 | grep -c "doesn't exist in o/r")"
check "post-lint: a rate-limited check says it couldn't check, not that it doesn't exist" "1 0" "$(GH_STUB_403=1 python3 "$R/bin/post-lint" "$T/ref.md" --kind reply --repo o/r --parent none 2>&1 | grep -c "couldn't check it") $(GH_STUB_403=1 python3 "$R/bin/post-lint" "$T/ref.md" --kind reply --repo o/r --parent none 2>&1 | grep -c "doesn't exist")"

# ---------- the steward: ~/.mergeworthy/steward owns the mergeworthy repo and the follow-ups ----------
SW="$T/steward"; mkdir -p "$SW" "$T/mwc"; git init -q "$T/mwc"; git -C "$T/mwc" remote add origin https://github.com/nitedani/mergeworthy.git
mkdir -p "$HOME/.t3/userdata"; python3 - "$HOME/.t3/userdata/statev2.sqlite" <<'EOF2'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute('create table orchestration_v2_projection_provider_threads (provider_thread_id text, thread_id text, payload_json text)')
c.execute('create table orchestration_v2_projection_subagents (subagent_id text, thread_id text, child_thread_id text)')
c.execute("""insert into orchestration_v2_projection_provider_threads values ('p1', 'thread:child', '{"nativeThreadRef":{"nativeId":"child-session"}}')""")
c.execute("""insert into orchestration_v2_projection_provider_threads values ('p2', 'other-thread', '{"nativeThreadRef":{"nativeId":"other-session"}}')""")
c.execute("insert into orchestration_v2_projection_subagents values ('s1', 'steward-thread', 'thread:child')"); c.commit()
EOF2
sg() { # command session cwd
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"session_id":sys.argv[2],"cwd":sys.argv[3]}))' "$@" \
    | python3 "$R/hooks/pre-bash-guard.py" 2>"$T/err"; echo $?; }
check "no steward declared: a push in a mergeworthy checkout passes" 0 "$(sg "git -C $T/mwc push $T/elsewhere.git HEAD:main" other-session "$T")"
echo "$SW steward-thread" > "$HOME/.mergeworthy/steward"
check "BLOCK: another session's commit or push in a mergeworthy checkout, saying to open an issue there" "2 1 2" "$(sg "git -C $T/mwc push $T/elsewhere.git HEAD:main" other-session "$T") $(grep -c "open an issue on nitedani/mergeworthy" "$T/err") $(sg "git commit -m x" other-session "$T/mwc")"
check "the steward's delegated agent (its T3 parent thread) and a session in its watch dir push; another repo passes" "0 0 0" "$(sg "git -C $T/mwc push $T/elsewhere.git HEAD:main" child-session "$T") $(sg "git -C $T/mwc push $T/elsewhere.git HEAD:main" x "$SW") $(sg "git -C $T/gr push $T/elsewhere.git HEAD:main" other-session "$T")"
python3 - "$HOME/.t3/userdata/statev2.sqlite" <<'EOF2'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("""insert into orchestration_v2_projection_provider_threads values ('p3', 'thread:spaced', '{"nativeThreadRef": {"nativeId": "spaced-session"}}')""")
c.execute("insert into orchestration_v2_projection_subagents values ('s2', 'steward-thread', 'thread:spaced')"); c.commit()
EOF2
echo steward-session > "$SW/session"
check "the steward's agent is found in JSON written with spaces" 0 "$(sg "git -C $T/mwc push $T/elsewhere.git HEAD:main" spaced-session "$T")"
mv "$HOME/.t3/userdata/statev2.sqlite" "$T/state.bak"
check "without T3's database, the session its watch dir's session file names is the steward; another isn't" "0 2" "$(sg "git -C $T/mwc push $T/elsewhere.git HEAD:main" steward-session "$T") $(sg "git -C $T/mwc push $T/elsewhere.git HEAD:main" other-session "$T")"
mv "$T/state.bak" "$HOME/.t3/userdata/statev2.sqlite"
printf '### FOLLOW-UP o/r#5: abcdef1234 by carol changes lines from your PR  <c>  at %s\n' "$(date -u -d '-40 minutes' +%FT%TZ)" > "$SW/events.log"; : > "$WD/events.log"; echo "$WD" > "$HOME/.claude/gh-watch-dirs.txt"
tr_file "Done."
stop_in() { python3 -c 'import json,sys; print(json.dumps({"transcript_path":sys.argv[1],"cwd":sys.argv[2],"session_id":sys.argv[3]}))' "$T/tr.jsonl" "$1" "$2" \
  | MERGEWORTHY_STOP_CHECKIN=off python3 "$R/hooks/stop-lint.py" 2>"$T/err"; echo $?; }  # cwd session
s1=$(stop_in "$SW" steward-session); echo "$SW" >> "$HOME/.claude/gh-watch-dirs.txt"; echo steward-session > "$SW/passed"
check "with a steward, its unsorted FOLLOW-UP waits for its pass, then blocks it, not an orchestrator" "0 2 0" "$s1 $(stop_in "$SW" steward-session) $(stop "$WD")"
cp "$SW/events.log" "$WD/events.log"
check "a FOLLOW-UP that fell back to the orchestrator's dir (no steward watcher ran) blocks the orchestrator" 2 "$(stop "$WD")"
echo 'abcdef1234 WORKED https://github.com/o/r/pull/5#issuecomment-1' > "$SW/followups-sorted.txt"
check "a WORKED verdict sorts it" 0 "$(stop_in "$SW" steward-session)"
echo "$WD" > "$HOME/.claude/gh-watch-dirs.txt"
rm -f "$HOME/.mergeworthy/steward" "$WD/events.log" "$SW/followups-sorted.txt" "$SW/passed"
# ---------- hooks/run: hook scripts run from ~/.mergeworthy/current; a changed hook list asks once for a restart ----------
PO="$T/plugins/cache/mw/old"; PN="$T/plugins/cache/mw/new"; mkdir -p "$PO/hooks" "$PN/hooks" "$T/co/hooks"; cp "$R/hooks/run" "$PO/hooks/"; cp "$R/hooks/run" "$T/co/hooks/"; CUR=$(readlink "$HOME/.mergeworthy/current")
printf 'print("old")\n' > "$PO/hooks/x.py"; printf 'print("new")\n' > "$PN/hooks/x.py"; printf 'print("checkout")\n' > "$T/co/hooks/x.py"
rm -f "$HOME/.mergeworthy/current"; a=$("$PO/hooks/run" x.py); ln -sfn "$PN" "$HOME/.mergeworthy/current"; b=$("$PO/hooks/run" x.py); c=$("$T/co/hooks/run" x.py)
check "hooks/run: an installed copy runs its own script without ~/.mergeworthy/current, the current version's with it; a checkout its own; every hook but session-start goes through it" "old new checkout ok" "$a $b $c $(python3 - "$R" <<'EOF2'
import json, sys
cmds = [h['command'] for es in json.load(open(sys.argv[1] + '/hooks/hooks.json'))['hooks'].values() for e in es for h in e['hooks']]
print('ok' if all(c.startswith('"${CLAUDE_PLUGIN_ROOT}"/hooks/run ') or c.endswith('/hooks/session-start') for c in cmds) else cmds)
EOF2
)"
echo '{"hooks": 1}' > "$PO/hooks/hooks.json"; echo '{"hooks": 2}' > "$PN/hooks/hooks.json"; touch -d '1 hour ago' "$PO"; tr_file "Done." work
rs() { python3 -c 'import json,sys; print(json.dumps({"transcript_path":sys.argv[1],"cwd":sys.argv[2],"session_id":sys.argv[3]}))' "$T/tr.jsonl" "$T" "$1" \
    | CLAUDE_PLUGIN_ROOT="$PO" MERGEWORTHY_STOP_CHECKIN=off python3 "$R/hooks/stop-lint.py" 2>"$T/err"; echo $?; }
check "BLOCK once per session: a newer version changed hooks.json, so a restart loads it; the same hook list says nothing" "2 1 0 0" "$(rs rs-1) $(grep -c 'restart of this session' "$T/err") $(rs rs-1) $(cp "$PN/hooks/hooks.json" "$PO/hooks/"; rs rs-2)"
mkdir -p "$PO/skills/task" "$PN/skills/task"; echo old > "$PO/skills/task/SKILL.md"; echo new > "$PN/skills/task/SKILL.md"
check "BLOCK once per session: a newer version changed the skills, naming where the installed text is; the same skills say nothing" "2 1 0 0" "$(rs rs-3) $(grep -c 'read and follow ~/.mergeworthy/current/skills/<name>/SKILL.md' "$T/err") $(rs rs-3) $(cp "$PN/skills/task/SKILL.md" "$PO/skills/task/"; rs rs-4)"
echo new2 > "$PN/skills/task/SKILL.md"; tr_file "Done."
check "a plain session (no work folder, agent or Monitor) hears of neither a changed hook list nor changed skills" "0 0" "$(echo '{"hooks": 3}' > "$PN/hooks/hooks.json"; rs rs-5) $(rs rs-6)"
python3 -c 'import json
print(json.dumps({"type":"user","message":{"content":"make me a fox image"}}))
print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","id":"s1","input":{"skill":"mergeworthy:task"}}]}}))
print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"Here is the fox."}]}}))' > "$T/tr.jsonl"
check "a session that only opened the task skill hears of neither (it is asked for its scope.md instead)" "0 0 1" "$(rs rs-7 >/dev/null; grep -c 'restart of this session' "$T/err") $(rs rs-8 >/dev/null; grep -c 'read and follow ~/.mergeworthy/current/skills' "$T/err") $(grep -c 'scope.md' "$T/err")"
if [ -n "$CUR" ]; then ln -sfn "$CUR" "$HOME/.mergeworthy/current"; else rm -f "$HOME/.mergeworthy/current"; fi
# ---------- GitLab: a stub glab answers `glab api --hostname gitlab.com <path>` from $FX/gl_<path> ----------
cat > "$T/bin/glab" <<'EOF'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1
f="$FX/gl_$(printf '%s' "$4" | tr '/?&=%' '_____')"
[ -f "$f" ] && cat "$f" || { echo 'glab: 404 Not found (HTTP 404)' >&2; exit 1; }
EOF
chmod +x "$T/bin/glab"
echo '{"iid": 3}' > "$FX/gl_projects_ns_2Fproj_issues_3"
glref() { printf 'See #%s.\n' "$1" > "$T/glref.md"; python3 "$R/bin/post-lint" "$T/glref.md" --kind reply --repo gitlab.com/ns/proj --parent none 2>&1 | grep -c "bare #"; }
check "post-lint: a bare #N is checked in the GitLab project: there, missing" "0 1" "$(glref 3) $(glref 7)"
trk() { printf '%sTracks x.\n\n## Work\n\n- [ ] o/r#1: the fix.\n%s\n' "$1" "$2" > "$T/trk.md"; python3 "$R/bin/post-lint" "$T/trk.md" --kind tracker --parent none 2>&1 | grep -c 'link the Decisions comment'; }
check "tracker: a GitLab note link is the Decisions link, in either URL form" "0 0" "$(trk '' 'All decisions made so far: https://gitlab.com/ns/proj/-/issues/2#note_55 (kept up to date).') $(trk '' 'All decisions made so far: https://gitlab.com/ns/proj/-/work_items/2#note_55 (kept up to date).')"
check "tracker: the issue's creation needs no Decisions link yet, an edit does" "0 1" "$(trk 'Title: Tracking: x
' '') $(trk '' '')"
bash -c 'exec -a gh-watch-daemon sleep 600' & GPID=$!  # the guard takes a watcher as live when its command names gh-watch-daemon
GW="$T/glw"; mkdir -p "$GW"; : > "$GW/threads.txt"; : > "$GW/repos.txt"
echo "$GPID" > "$GW/gh-watch.pid"; echo sess-gl > "$GW/session"; echo "$GW" > "$HOME/.claude/gh-watch-dirs.txt"
glguard() { python3 -c 'import json,sys; print(json.dumps({"session_id":"sess-gl","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "${2:-$T}" | python3 "$R/hooks/pre-bash-guard.py" 2>"$T/err"; echo $?; }
check "BLOCK: glab issue create with no watcher on the project" "2 1" "$(glguard 'glab issue create -R ns/sub/proj --title x') $(grep -c 'gitlab.com/ns/sub/proj' "$T/err")"
git init -q "$T/glrepo"; git -C "$T/glrepo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a; git -C "$T/glrepo" remote add origin git@gitlab.com:ns/sub/proj.git; (cd "$T/glrepo" && bash "$R/bin/pr-steps" approach "$T/approach.md" >/dev/null)
check "BLOCK: glab mr create --draft in a clone of an unwatched project" 2 "$(glguard 'glab mr create --draft --title x' "$T/glrepo")"
echo gitlab.com/ns/sub/proj > "$GW/repos.txt"
check "glab issue create passes once a watcher covers the project" "0 0" "$(glguard 'glab issue create -R https://gitlab.com/ns/sub/proj --title x') $(glguard 'glab mr create --draft --title x' "$T/glrepo")"
echo 'o/r all' > "$GW/repos.txt"
check "an 'owner/repo all' line covers the repo for opening an issue" 0 "$(glguard 'gh issue create -R o/r --title x --body-file x.md' >/dev/null; grep -c 'no running watcher' "$T/err")"
check "gh issue create without -R opens it on GH_REPO, which the watcher covers, not on the checkout's origin" "0 0" "$(glguard 'GH_REPO=o/r gh issue create --title x --body-file x.md' "$ODR" >/dev/null; grep -c 'no running watcher' "$T/err") $(GH_REPO=o/r glguard 'gh issue create --title x --body-file x.md' "$ODR" >/dev/null; grep -c 'no running watcher' "$T/err")"
PG="$T/glpass"; mkdir -p "$PG"; echo 'p/q all' > "$PG/repos.txt"; echo sess-g > "$PG/passed"; printf '%s\n' "$GW" "$PG" > "$HOME/.claude/gh-watch-dirs.txt"
glsess() { python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"tool_input":{"command":"gh issue create -R p/q --title x --body-file x.md"},"cwd":sys.argv[2]}))' "$1" "$T" \
  | python3 "$R/hooks/pre-bash-guard.py" 2>"$T/err" >/dev/null; grep -c 'no running watcher' "$T/err"; }
check "BLOCK: a dir a steward pass read today covers no repo for opening an issue, its session's or another's, saying to start a watcher" "1 1 1" "$(glsess sess-g) $(glsess sess-h) $(grep -c 'gh-watch-start' "$T/err")"
# a watcher wakes the session that started it: a subagent leaves it to the main session, which owns the PR
check "BLOCK: a subagent starting a watcher, or told to by an unwatched issue create; the main session, or a subagent's steward round, passes" "2 2 1 0 0" \
  "$(guard 'gh-watch-start /w o/r 5' a1) $(guard 'gh issue create -R p/q --title x --body-file x.md' a1) $(grep -c 'asking the main session to run .gh-watch-start' "$T/err") $(guard 'gh-watch-start /w o/r 5') $(guard 'gh-watch-start --round /w o/r' a1)"
echo "$GW" > "$HOME/.claude/gh-watch-dirs.txt"
echo gitlab.com/ns/sub/proj > "$GW/repos.txt"
glreg() { python3 -c 'import json,sys; print(json.dumps({"session_id":"sess-gl","tool_input":{"command":sys.argv[1]},"tool_response":{"stdout":sys.argv[2]}}))' "$1" "$2" | python3 "$R/hooks/post-bash-register.py"; }
glreg 'glab issue create -R ns/sub/proj --title x' 'https://gitlab.com/ns/sub/proj/-/work_items/12'
glreg 'glab mr create --draft --title x' 'https://gitlab.com/ns/sub/proj/-/merge_requests/3'
glreg 'glab issue list' 'https://gitlab.com/ns/sub/proj/-/issues/13'
check "post-bash-register: glab's new issue and MR join threads.txt, the repo line goes, a list adds nothing" "gitlab.com/ns/sub/proj 12|gitlab.com/ns/sub/proj !3|+" "$(tr '\n' '|' < "$GW/threads.txt")+$(cat "$GW/repos.txt")"
kill "$GPID"
# ---------- .githooks/pre-push: a pushed skill change names its cold read's record ----------
git init -q --bare "$T/cr.git"; git init -q -b main "$T/cr"; mkdir -p "$T/cr/skills/a" "$T/crh"
printf '#!/bin/sh\nexec "%s/.githooks/cold-read"\n' "$R" > "$T/crh/pre-push"; chmod +x "$T/crh/pre-push"
git -C "$T/cr" config core.hooksPath "$T/crh"; git -C "$T/cr" remote add origin "$T/cr.git"
echo a > "$T/cr/README"; git -C "$T/cr" add README; git -C "$T/cr" commit -qm base
crpush() { git -C "$T/cr" push -q origin main > "$T/cr.out" 2>&1; echo $?; }
echo one > "$T/cr/skills/a/SKILL.md"; git -C "$T/cr" add skills; git -C "$T/cr" commit -qm 'skill: one'
echo two > "$T/cr/always-on.md"; git -C "$T/cr" add always-on.md; git -C "$T/cr" commit -qm 'rules: two' -m "Cold-read: $T/missing.md"
check "BLOCK: a new branch's skill and always-on.md commits with no Cold-read trailer naming an existing file, naming both" "1 1 1 0" "$(crpush) $(grep -c 'skill: one' "$T/cr.out") $(grep -c 'rules: two' "$T/cr.out") $(grep -c ' base$' "$T/cr.out")"
echo record > "$T/coldread.md"; echo three > "$T/cr/other"; git -C "$T/cr" add other; git -C "$T/cr" commit -qm later -m "Cold-read: $T/coldread.md"
check "a later commit of the same push with the trailer covers them" 0 "$(crpush)"
echo four > "$T/cr/skills/a/SKILL.md"; git -C "$T/cr" commit -qam 'skill: four' -m "Cold-read: $T/coldread.md"
echo five > "$T/cr/skills/a/SKILL.md"; git -C "$T/cr" commit -qam 'skill: five'
check "BLOCK: on a pushed branch, a skill commit after the last trailer, naming only it" "1 0 1" "$(crpush) $(grep -c 'skill: four' "$T/cr.out") $(grep -c 'skill: five' "$T/cr.out")"
git -C "$T/cr" checkout -qb f origin/main; mkdir -p "$T/cr/skills/b"; echo six > "$T/cr/skills/b/SKILL.md"; git -C "$T/cr" add skills
git -C "$T/cr" commit -qm 'skill: six' -m "Cold-read: $T/coldread.md"; git -C "$T/cr" push -q origin f
git clone -q -b main "$T/cr.git" "$T/cr2"; echo squash > "$T/cr2/skills/a/SKILL.md"; git -C "$T/cr2" commit -qam 'skill: squash (#1)'; git -C "$T/cr2" push -q origin main
git -C "$T/cr" fetch -q; git -C "$T/cr" merge -q origin/main -m 'Merge main'
check "a merged main's squash commit, already on a remote-tracking ref, needs no trailer of the push" "0 Merge main" \
  "$(git -C "$T/cr" push -q origin f > "$T/cr.out" 2>&1; echo $?) $(git -C "$T/cr.git" log -1 --format=%s f)"
# pre-push on a checkout without node_modules: tests/all.sh names the install command, and each push keeps its own log
mkdir -p "$T/pp/tests"; cp -r "$R/.githooks" "$T/pp/"; cp "$R/tests/all.sh" "$T/pp/tests/"
pp() { TMPDIR="$T/pplogs" sh "$T/pp/.githooks/pre-push" </dev/null | sed -n 's/.*see //p'; }
mkdir -p "$T/pplogs"; L1=$(pp); L2=$(pp)
check "pre-push: two failed pushes keep two logs, each naming the install command" "2 1 1" "$(ls "$T/pplogs" | wc -l) $(grep -c 'pnpm install' "$L1") $([ -n "$L1" ] && [ "$L1" != "$L2" ] && grep -c 'pnpm install' "$L2")"
# ---------- fail closed: a check that can't run blocks; the vikejs/vike#3671 session ("Fix CI"), replayed command by command ----------
# shellcmd.parse lexes the whole command as bash does: that session's commit messages and PR body spanned lines, the old
# line-by-line split raised, and its fallback saw only `cd`, so every check after it was skipped
sp() { python3 - "$R/hooks" "$1" <<'PY'
import json, sys; sys.path.insert(0, sys.argv[1]); import shellcmd as s
segs, err = s.parse(sys.argv[2])
print(json.dumps([s.prog(x)[:3] for x in segs]) + (' ERR' if err else ''))
PY
}
check "parse: a commit message with trailers over several lines, and the push after it" '[["cd", "/r"], ["git", "commit", "-qam"], ["git", "push", "origin"], ["tail", "-3"]]' \
  "$(sp $'cd /r; git commit -qam "fix: pass \\`headers\\`\n\nCo-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>" && git push origin HEAD:b 2>&1 | tail -3')"
check "parse: gh pr create with a body typed inline over several lines" '[["gh", "pr", "create"]]' "$(sp $'gh pr create --repo v/v --draft --title "fix: x" --body "Fixes CI.\n\nIt\'s the headers."')"
check "parse: a message from a heredoc inside \$( ), an apostrophe and a parenthesis in it" '[["git", "commit", "-m"], ["cat", "<<", "EOF"], ["git", "push"]]' \
  "$(sp $'git commit -m "$(cat <<\'EOF\'\nit\'s (one\nEOF\n)" && git push')"
pushes() { python3 - "$R/hooks" "$1" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import shellcmd as s
print('yes' if any(s.prog(x)[:2] == ['git', 'push'] for x in s.parse(sys.argv[2])[0]) else 'no')
PY
}
check "parse: a push in bash -c, if/then, sudo -u, a heredoc a shell reads, eval, a subshell in \$( ); none in a heredoc python reads" "yes yes yes yes yes yes no" \
  "$(pushes 'bash -lc "cd x && git push"') $(pushes 'if true; then git push; fi') $(pushes 'sudo -u bob git push') $(pushes $'cat <<EOF | bash\ngit push\nEOF') $(pushes 'eval "git push"') $(pushes 'x=$( (cd a; git push) )') $(pushes $'python3 - <<\'E\'\ns = "git push"\nE')"
check "parse: an unterminated quote says so, its words still showing the command" '[["git", "commit", "-m"]] ERR' "$(sp 'git commit -m "oops')"
# the session's checkout, outside any work folder, as /home/collab/projects/vike was
VK="$T/projects/vike"; git init -q -b fix-telefunc "$VK"; git -C "$VK" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$VK" remote add origin https://github.com/vikejs/vike.git; git -C "$VK" config user.name me; git -C "$VK" config user.email 42+me@users.noreply.github.com
bg() { # command [cwd]: pre-bash-guard's exit code, its message in $T/err
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "${2:-$VK}" | python3 "$R/hooks/pre-bash-guard.py" 2>"$T/err"; echo $?; }
gql() { # viewer owner [PR URL]: GitHub's answer to whether a push updates a PR's head (pre-bash-guard's collaboration())
  python3 -c 'import json,sys; v, o, u = (sys.argv[1:] + [""])[:3]
print(json.dumps({"data": {"viewer": {"login": v}, "repository": {"owner": {"login": o}, "b0": {"associatedPullRequests": {"nodes": [{"url": u, "isDraft": True}] if u else []}}}}}))' "$@" > "$FX/graphql"; }
gql nitedani-agent nitedani-agent https://github.com/vikejs/vike/pull/3675  # the session's pushes went to its draft PR's head
C1="cd $VK; "$'git commit -qam "fix: pass \\`headers\\` to telefunc \\`serve()\\` (telefunc 0.3.0)\n\nCo-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>" && git push origin HEAD:dependabot/npm_and_yarn/telefunc-0.3.0 2>&1 | tail -3'
check "replay: the first commit and push (a multi-line message), with no preflight: blocked at the commit" "2 1" "$(bg "$C1") $(grep -c 'pr-steps preflight' "$T/err")"
(cd "$VK" && bash "$R/bin/pr-steps" preflight 'none, because the test repo has no UI' >/dev/null)
check "replay: with a preflight, the push from a checkout in no task's work folder is blocked" "2 1" "$(bg "$C1") $(grep -c "isn't in a task's work folder" "$T/err")"
check "replay: the push through a git alias, or bash -c, is the same push" "2 2" "$(bg 'git -c alias.p=push p origin HEAD:b') $(bg 'bash -c "git push origin HEAD:b"')"
C2="cd $VK; "$'gh pr create --repo vikejs/vike --base dependabot/npm_and_yarn/telefunc-0.3.0 --head nitedani-agent:fix-telefunc --draft --title "fix: pass \\`headers\\` to telefunc \\`serve()\\`" --body "Fixes CI of #3671.\n\nPasses \\`headers\\` at the three \\`serve()\\` call sites."'
check "replay: the draft PR with its title and body typed inline, multi-line: blocked (the title)" "2 1" "$(bg "$C2") $(grep -c 'typed inline' "$T/err")"
check "replay: an inline multi-line body, from a scoped and gated checkout: blocked (post from a draft file)" "2 1" \
  "$(MERGEWORTHY_WATCHER=off bg $'gh pr create --repo o/r --draft --title "$(cat /w/drafts/title.md)" --body "Fixes CI.\n\nIt\'s the headers."' "$TCO") $(grep -c 'post from a draft file' "$T/err")"
git -C "$TCO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'style: format'
check "replay: a push to a draft PR's branch whose head ran no gates ('I'll push and let CI verify'): blocked, naming pr-steps quick" "2 1" \
  "$(MERGEWORTHY_WATCHER=off bg 'git push https://github.com/nitedani-agent/vike.git HEAD:fix-telefunc' "$TCO") $(grep -c 'pr-steps quick' "$T/err")"
printf 'pnpm test -> exit 0 (3 tests)\nTypeScript: types not installed here, let CI verify -> exit 0\n' > "$T/q-ci.log"
check "pr-steps quick refuses a log whose gate didn't run ('not installed', 'let CI verify')" "1 1" "$(cd "$TCO" && bash "$R/bin/pr-steps" quick "$T/q-ci.log" 2>"$T/err" >/dev/null; echo $?) $(grep -c "says a gate didn't run" "$T/err")"
printf "replay: a push whose head ran no gates ('I'll push and let CI verify'): blocked: 2 (want 2)\nbash tests/hooks.sh . -> exit 0 (739 tests)\nbash tests/word-budget . -> exit 0 (32586 words)\n" > "$T/q-titles.log"
check "pr-steps quick records a log whose test titles quote 'let CI', with a word-count gate" 0 "$(git -C "$TCO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m q; cd "$TCO" && bash "$R/bin/pr-steps" quick "$T/q-titles.log" >/dev/null 2>&1; echo $?)"
printf 'bash tests/word-budget . -> exit 0 (32586 words)\n' > "$T/q-words.log"
check "pr-steps quick records a log whose only gate counts words" 0 "$(git -C "$TCO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m qw; cd "$TCO" && bash "$R/bin/pr-steps" quick "$T/q-words.log" >/dev/null 2>&1; echo $?)"
printf 'pnpm run test:types -> exit 0 (15 projects)\npnpm exec tsc --noEmit -p tsconfig.spec.json -> exit 0 (1 project)\n' > "$T/q-types.log"; printf 'pnpm run test:types -> exit 0 (0 projects)\n' > "$T/q-types0.log"
printf 'pnpm lint -> exit 0\npnpm exec tsc --noEmit -p tsconfig.spec.json -> exit 0 (0 projects)\n' > "$T/q-tsc0.log"
check "pr-steps quick records a type-check script's line counting its projects, and refuses 0 projects, under any command" "0 1 1" "$(git -C "$TCO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m qt; cd "$TCO" && bash "$R/bin/pr-steps" quick "$T/q-types.log" >/dev/null 2>&1; echo $?) $(cd "$TCO" && bash "$R/bin/pr-steps" quick "$T/q-types0.log" >/dev/null 2>&1; echo $?) $(cd "$TCO" && bash "$R/bin/pr-steps" quick "$T/q-tsc0.log" >/dev/null 2>&1; echo $?)"
printf 'pnpm exec biome ci test/discord-clone test-e2e.config.mjs -> exit 0 (36 files)\n' > "$T/q-files.log"; printf 'pnpm exec biome ci test/discord-clone test-e2e.config.mjs -> exit 0 (0 files)\n' > "$T/q-files0.log"; printf 'pnpm exec biome ci packages -> exit 0 (0 files)\n' > "$T/q-lint0.log"
for g in 'tests/hooks.sh .' 'VAR=x ./tests/hooks.sh .' 'netns-run ./tests/hooks.sh .' 'bash -x tests/hooks.sh .' '/bin/bash tests/hooks.sh .'; do printf '%s -> exit 0\n' "$g"; done > "$T/q-scripts.log"
check "pr-steps quick records a check naming test paths that counts its files, refuses 0 files, and asks a count of each test script however it's called" "0 1 1 5" "$(git -C "$TCO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m qf; cd "$TCO" && bash "$R/bin/pr-steps" quick "$T/q-files.log" >/dev/null 2>&1; echo $?) $(cd "$TCO" && bash "$R/bin/pr-steps" quick "$T/q-files0.log" >/dev/null 2>&1; echo $?) $(cd "$TCO" && bash "$R/bin/pr-steps" quick "$T/q-lint0.log" >/dev/null 2>&1; echo $?) $(n=0; while read -r l; do printf '%s\n' "$l" > "$T/q-one.log"; (cd "$TCO" && bash "$R/bin/pr-steps" quick "$T/q-one.log" >/dev/null 2>&1) || n=$((n+1)); done < "$T/q-scripts.log"; echo $n)"
printf 'pnpm test -> exit 0 (3 tests)\npnpm typecheck was not run: dependency unavailable\n' > "$T/q-unrun.log"
check "BLOCK: pr-steps quick on a log saying a gate was not run, on a line of its own" "1 1" "$(git -C "$TCO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m qu; cd "$TCO" && bash "$R/bin/pr-steps" quick "$T/q-unrun.log" 2>"$T/err" >/dev/null; echo $?) $(grep -c "says a gate didn't run" "$T/err")"
TK2="$HOME/.mergeworthy/work/vike-3671"; CK="$TK2/vike"; mkdir -p "$TK2"
printf 'Tier: S, because one CI fix in one repo\n\n- [ ] Fix CI https://github.com/vikejs/vike/pull/3671\n' > "$TK2/scope.md"
git init -q -b fix-telefunc "$CK"; git -C "$CK" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a; git -C "$CK" remote add upstream https://github.com/vikejs/vike.git
(cd "$CK" && bash "$R/bin/pr-steps" approach "$T/approach.md" >/dev/null)
printf '[{"name":"TypeScript","bucket":"fail"},{"name":"Examples Vue/Others (ubuntu-latest)","bucket":"fail"},{"name":"Lint","bucket":"pass"}]' > "$FX/pr_checks_https___github.com_vikejs_vike_pull_3671"
quick "$CK"
check "replay: a CI fix whose gate log doesn't run the failing jobs: blocked, naming each failing one" "2 1 1 0" \
  "$(MERGEWORTHY_WATCHER=off bg 'git push https://github.com/nitedani-agent/vike.git HEAD:fix-telefunc' "$CK") $(grep -c '"TypeScript"' "$T/err") $(grep -c '"Examples Vue/Others (ubuntu-latest)"' "$T/err") $(grep -c '"Lint"' "$T/err")"
git -C "$CK" -c user.name=t -c user.email=t@t commit -q --allow-empty -m b
quick "$CK" $'TypeScript: pnpm exec tsc --noEmit -> exit 0\nExamples Vue/Others (ubuntu-latest): pnpm -C examples/vue test -> exit 0 (12 tests)\n'
check "the same push passes once its head's log runs each failing job" 0 "$(MERGEWORTHY_WATCHER=off bg 'git push https://github.com/nitedani-agent/vike.git HEAD:fix-telefunc' "$CK")"
echo "$T/nowatch" > "$HOME/.claude/gh-watch-dirs.txt"
check "replay: the same push with no watcher on vikejs/vike (or the fork): blocked, naming the repos" "2 1" "$(bg 'git push https://github.com/nitedani-agent/vike.git HEAD:fix-telefunc' "$CK") $(grep -c 'covers nitedani-agent/vike or vikejs/vike' "$T/err")"
bash -c 'exec -a gh-watch-daemon sleep 600' & FPID=$!; echo "$FPID" > "$TK2/gh-watch.pid"; echo vikejs/vike > "$TK2/repos.txt"; echo "$TK2" > "$HOME/.claude/gh-watch-dirs.txt"
check "a watcher of the checkout's work folder on the upstream repo covers it" 0 "$(bg 'git push https://github.com/nitedani-agent/vike.git HEAD:fix-telefunc' "$CK")"
# two tasks' work folders, one watched by session sess-a: its events wake that session alone, so a session acting from the other folder needs a watcher of its own
printf 'vikejs/vike\ngitlab.com/ns/proj\n' > "$TK2/repos.txt"; echo sess-a > "$TK2/session"
TK4="$HOME/.mergeworthy/work/vike-other"; CK4="$TK4/vike"; mkdir -p "$TK4"; printf 'Tier: S, because one fix\n\n- [ ] Fix it https://github.com/vikejs/vike/issues/1\n' > "$TK4/scope.md"
git init -q -b fix-telefunc "$CK4"; git -C "$CK4" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a; git -C "$CK4" remote add upstream https://github.com/vikejs/vike.git; quick "$CK4"; (cd "$CK4" && bash "$R/bin/pr-steps" approach "$T/approach.md" >/dev/null)
bgs() { # session command cwd: pre-bash-guard's exit code, its message in $T/err
  python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"tool_input":{"command":sys.argv[2]},"cwd":sys.argv[3]}))' "$@" | python3 "$R/hooks/pre-bash-guard.py" 2>"$T/err"; echo $?; }
unwatched() { bgs "$@" >/dev/null; grep -c 'no running watcher' "$T/err"; }
PUSH='git push https://github.com/nitedani-agent/vike.git HEAD:fix-telefunc'
PRC="gh pr create --repo vikejs/vike --draft --title \"\$(cat $TK4/drafts/title.md)\" --body-file $TK4/drafts/pr.md"
MRC='glab mr create --draft -R gitlab.com/ns/proj --title x'
check "BLOCK: a push, a PR and an MR from a work folder another session's watcher doesn't watch, naming the folder to watch" "2 1 1 1" \
  "$(bgs sess-b "$PUSH" "$CK4") $(grep -c "gh-watch-start $TK4 " "$T/err") $(unwatched sess-b "$PRC" "$CK4") $(unwatched sess-b "$MRC" "$CK4")"
check "the same from the watched work folder pass, whichever session acts there" "0 0 0" "$(bgs sess-b "$PUSH" "$CK") $(unwatched sess-b "$PRC" "$CK") $(unwatched sess-b "$MRC" "$CK")"
check "outside any work folder, only the session's own watcher counts" "0 1" "$(unwatched sess-a "$MRC" "$T") $(unwatched sess-b "$MRC" "$T")"
oreg() { # session cwd command: the thread post-bash-register adds to the watched folder
  python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"cwd":sys.argv[2],"tool_input":{"command":sys.argv[3]},"tool_response":{"stdout":"https://github.com/vikejs/vike/pull/9"}}))' "$@" \
    | python3 "$R/hooks/post-bash-register.py"; cat "$TK2/threads.txt" 2>/dev/null || echo none; rm -f "$TK2/threads.txt"; }
check "a PR opened from the unwatched folder joins no other session's watcher; from the watched one (after a cd, to a variable too), it joins its watcher" \
  "none|vikejs/vike 9|vikejs/vike 9|vikejs/vike 9" "$(oreg sess-b "$CK4" "$PRC")|$(oreg sess-b "$CK" "$PRC")|$(oreg sess-b "$T" "cd $CK && $PRC")|$(oreg sess-b "$T" "D=$CK; cd \"\$D\" && $PRC")"
# two MRs opened in one command from two work folders: the second folder needs its own watcher
TWO="cd $CK; $MRC; cd $CK4; $MRC"
check "BLOCK: two MRs from two work folders in one command while the second folder has no watcher" 2 "$(bgs sess-b "$TWO" "$T")"
check "BLOCK: an MR where the dir can't be told (cd -, a cd to an unset variable, a cd in a subshell or bash -c), saying to cd to an absolute path" "2 2 2 2 1" \
  "$(bgs sess-b "cd $CK; $MRC; cd -; $MRC" "$CK4") $(bgs sess-b "cd \"\$NOWHERE\" && $MRC" "$CK") $(bgs sess-b "(cd $CK4); $MRC" "$CK") $(bgs sess-b "bash -c 'cd $CK4'; $MRC" "$CK") $(grep -c 'cd to an absolute path first' "$T/err")"
check "a redirect on cd or pushd (pushd x >/dev/null, cd x 2>/dev/null) and cd \$(git rev-parse --show-toplevel) leave the dir known: an MR in the watched folder passes" "0 0 0 0" \
  "$(bgs sess-b "pushd $CK >/dev/null && $MRC" "$CK") $(bgs sess-b "pushd $CK >/dev/null; $MRC; popd >/dev/null" "$CK") $(bgs sess-b "cd $CK 2>/dev/null && $MRC" "$CK") $(bgs sess-b "cd \$(git rev-parse --show-toplevel) && $MRC" "$CK")"
echo "$FPID" > "$TK4/gh-watch.pid"; echo gitlab.com/ns/proj > "$TK4/repos.txt"; echo "$TK4" >> "$HOME/.claude/gh-watch-dirs.txt"
check "the same passes once each folder has its watcher" 0 "$(bgs sess-b "$TWO" "$T")"
treg() { # stdout [command [cwd]]: post-bash-register on the command ($TWO, from $T), then exit code|the first folder's threads|the second's
  python3 -c 'import json,sys; print(json.dumps({"session_id":"sess-b","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]},"tool_response":{"stdout":sys.argv[3]}}))' "${3:-$T}" "${2:-$TWO}" "$1" \
    | python3 "$R/hooks/post-bash-register.py" 2>"$T/err"; echo "$?|$(paste -sd, "$TK2/threads.txt" 2>/dev/null)|$(paste -sd, "$TK4/threads.txt" 2>/dev/null)"; rm -f "$TK2/threads.txt" "$TK4/threads.txt"; }
check "BLOCK: a URL from posting commands in two folders joins neither, and the hook names the gh-watch-start that adds it" "2|||1" \
  "$(treg 'https://gitlab.com/ns/proj/-/merge_requests/9')|$(grep -c "gh-watch-start <work folder> gitlab.com/ns/proj '!9'" "$T/err")"
mkdir -p "$TK2/vike2"
check "one URL for two posting commands in two checkouts of one work folder joins that folder's watcher" "0|gitlab.com/ns/proj !9|" \
  "$(treg 'https://gitlab.com/ns/proj/-/merge_requests/9' "cd $CK; $MRC; cd $TK2/vike2; $MRC")"
U9='https://gitlab.com/ns/proj/-/merge_requests/9'
check "an MR after pushd x >/dev/null joins x's folder; one where the dir can't be told (a cd to an unset variable) joins no watcher, saying why" "0||gitlab.com/ns/proj !9 2|| 1" \
  "$(treg "$U9" "pushd $CK4 >/dev/null; $MRC" "$CK") $(treg "$U9" "cd \"\$NOWHERE\"; $MRC" "$CK4") $(grep -c "which dir a posting command ran in can't be told" "$T/err")"
rm "$TK4/gh-watch.pid" "$TK4/repos.txt"
rm "$TK2/gh-watch.pid" "$TK2/repos.txt" "$TK2/session"
kill "$FPID"
check "BLOCK: a shell write of a step record, and a Write of one" "2 2" "$(bg 'echo "quick /x 2026-10-27T00:00:00Z" >> ~/.claude/pr-steps/$(git rev-parse HEAD)') $(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","tool_input":{"file_path":sys.argv[1]},"cwd":sys.argv[2]}))' "$HOME/.claude/pr-steps/abc" "$T" | python3 "$R/hooks/pre-design-gate.py" 2>/dev/null; echo $?)"
check "BLOCK: a GitHub write through curl" 2 "$(bg 'curl -X POST -H "Authorization: token x" https://api.github.com/repos/o/r/issues/5/comments -d @body.json')"
check "BLOCK: a command that doesn't parse, holding a guarded verb, saying so; one without passes" "2 1 0" "$(bg 'git commit -m "oops') $(grep -c "doesn't parse" "$T/err") $(bg 'echo "oops')"
check "BLOCK: a comment while gh can't read the thread (two in a row can't be checked)" "2 1" "$(GH_STUB_403=1 bg "gh issue comment 5 --repo o/r --body-file $D/new.md" "$T") $(grep -c "couldn't read o/r#5" "$T/err")"
(cd "$TCO" && bash "$R/bin/pr-steps" preflight 'none, because the test repo has no UI' >/dev/null); rm -f "$FX/user" "$HOME/.claude/gh-user.txt"
check "a commit while gh can't say which account pushes (offline, nothing cached) passes: it stays local" 0 "$(bg 'git commit -m x' "$TCO")"
check "an identity the command computes (\${id}, \$(git log ...)) isn't compared as written" 0 "$(echo 'me 42' > "$HOME/.claude/gh-user.txt"; bg 'id=42; git -c user.name=me -c user.email=${id}+me@users.noreply.github.com commit -m x' "$TCO")"
echo 'me 42' > "$HOME/.claude/gh-user.txt"
check "the account gh last named is the one checked while gh can't answer" "2 1" "$(bg 'git -c user.name=me -c user.email=me@example.com commit -m x' "$TCO") $(grep -c '42+me@users.noreply.github.com' "$T/err")"
check "BLOCK: a hook that crashes (here on input it can't read) blocks, saying the check failed" "2 1" "$(printf 'not json' | python3 "$R/hooks/pre-bash-guard.py" 2>"$T/err"; echo $?) $(grep -c 'the check itself failed' "$T/err")"
mkdir -p "$T/hk"; cp "$R/hooks/run" "$T/hk/run"; printf 'import sys; sys.exit(3)\n' > "$T/hk/bad.py"; printf 'import time; time.sleep(5)\n' > "$T/hk/slow.py"
check "hooks/run: a hook exiting with neither 0 nor 2, or past its time, blocks" "2 2 1" "$(bash "$T/hk/run" bad.py </dev/null 2>/dev/null; echo $?) $(MERGEWORTHY_HOOK_SECONDS=1 bash "$T/hk/run" slow.py </dev/null 2>"$T/err"; echo $?) $(grep -c 'after 1s' "$T/err")"
TK3="$HOME/.mergeworthy/work/unscoped"; git init -q "$TK3/r"; (cd "$TK3/r" && bash "$R/bin/pr-steps" preflight 'none, because the test repo has no UI' >/dev/null)
check "BLOCK: an edit in a task's checkout before scope.md has its Tier line" "2" "$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1]},"cwd":sys.argv[2]}))' "$TK3/r/a.ts" "$TK3/r" | python3 "$R/hooks/pre-design-gate.py" 2>/dev/null; echo $?)"
sg_tr "$T/sg.jsonl" skill:mergeworthy:task skill:mergeworthy:merging
check "replay: the inline-body draft PR waits for pull-request, post and writing" "2 mergeworthy:post mergeworthy:pull-request mergeworthy:writing" \
  "$(sg_in Bash "$(python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1]}))' "$C2")" | python3 "$R/hooks/pre-skill-gate.py" 2>"$T/sg.err"; echo $?) $(grep -o '^- mergeworthy:[a-z-]*' "$T/sg.err" | cut -c3- | sort | xargs)"
# stop-lint: the final message from the hook's input, hand-backs, the PR states it claims, an unfinished task
slj() { # [last_assistant_message] [stop_hook_active] [session] [cwd]: stop-lint on $T/tr.jsonl
  python3 -c 'import json,sys; d={"transcript_path":sys.argv[1],"cwd":sys.argv[2],"stop_hook_active":sys.argv[3]=="1","session_id":sys.argv[4]}
if sys.argv[5]: d["last_assistant_message"]=sys.argv[5]
print(json.dumps(d))' "$T/tr.jsonl" "${4:-$T}" "${2:-0}" "${3:-s-fc}" "${1:-}" | MERGEWORTHY_STOP_CHECKIN=off python3 "$R/hooks/stop-lint.py" 2>"$T/err"; echo $?; }
: > "$HOME/.claude/gh-watch-dirs.txt"
hb=; for m in 'The fix is committed locally on `fix-telefunc`. Pushing it, or telling me to open a PR from a fork instead, is your call.' \
             $'I split them across lines by hand.\n\nTell me when to re-check CI.' \
             "I haven't opened one and haven't replied on the thread. Should I open the Telefunc PR and keep the workaround until it's released?" \
             'Telefunc would need a change to accept a full `request.url`. Do you want me to open that Telefunc PR and post the reply?' \
             'Nothing will notify me when they finish. Tell me to check, or to post the reply now.' \
             "The reply to brillout is drafted and reviewed as CLEAN, but it isn't posted yet. Do you want me to post it now that CI is green?"; do tr_file "$m" work; hb="$hb $(slj)"; done
check "BLOCK: the session's six hand-backs, as it wrote them" " 2 2 2 2 2 2" "$hb"
tr_file 'README tidied.' work
check "a hand-back a tool printed, in a ~~~ code block or an indented one, is not the agent's" "0 0" "$(slj $'The tool printed:\n\n~~~\nShould I retry?\n~~~') $(slj $'The tool printed:\n\n    Should I retry?')"
check "the final message is the hook input's, not the transcript's last line (which may not be written yet)" "2 1" "$(slj 'Tell me when to re-check CI.') $(grep -ci 'tell me when' "$T/err")"
tr_file 'Ask me to check the run when you want it.' work
check "stop_hook_active no longer lets the next stop through: the hand-back still blocks" 2 "$(slj '' 1)"
# a claude -p --no-session-persistence run's Stop input, as captured: its transcript_path names a file that is never written
nopersist() { # CLAUDE_PID
  python3 -c 'import json,sys; print(json.dumps({"session_id":"4c63f963","transcript_path":sys.argv[1]+"/never/4c63f963.jsonl","cwd":sys.argv[1],"prompt_id":"e89cd96c","permission_mode":"default","effort":{"level":"medium"},"hook_event_name":"Stop","stop_hook_active":False,"last_assistant_message":"OK","background_tasks":[],"session_crons":[]}))' "$T" \
    | CLAUDE_PID=$1 MERGEWORTHY_STOP_CHECKIN=off python3 "$R/hooks/stop-lint.py" 2>"$T/err"; echo "$? $(wc -c < "$T/err")"; }
(exec -a 'claude -p --no-session-persistence reply with exactly OK' sleep 600) & NPID=$!
check "a claude -p --no-session-persistence run ends silently; a session whose transcript can't be read still blocks once" "0 0 2" "$(nopersist $NPID) $(nopersist $$ | cut -d' ' -f1)"
kill "$NPID"; wait "$NPID" 2>/dev/null
tr_file 'README tidied.' work
ci() { # session [cwd]
  python3 -c 'import json,sys; print(json.dumps({"transcript_path":sys.argv[1],"cwd":sys.argv[2],"session_id":sys.argv[3]}))' "$T/tr.jsonl" "${2:-$T}" "$1" | MERGEWORTHY_STOP_CHECKIN=on python3 "$R/hooks/stop-lint.py" 2>"$T/err"; echo $?; }
check "the check-in is per session: another session gets its own, the first not twice within 30 minutes" "2 2 0" "$(ci sess-a) $(ci sess-b) $(ci sess-a)"
echo 1 > "$HOME/.claude/mergeworthy-stop-checkin"  # the stamp an older stop-lint shared between sessions
check "the old shared check-in stamp file doesn't crash the per-session one" 2 "$(ci sess-c)"
git init -q "$T/vkr"; git -C "$T/vkr" remote add origin https://github.com/vikejs/vike.git
printf '{"state":"open","draft":false,"merged":false,"html_url":"https://github.com/vikejs/vike/pull/3675","head":{"sha":"abc"},"base":{"repo":{"full_name":"vikejs/vike"}}}' > "$FX/repos_vikejs_vike_pulls_3675"
printf '{"check_runs":[{"name":"test","status":"completed","conclusion":"success"}]}' > "$FX/repos_vikejs_vike_commits_abc_check-runs_per_page_100"; cp "$FX/repos_vikejs_vike_commits_abc_check-runs_per_page_100" "$FX/repos_vikejs_vike_commits_abc_check-runs"
tr_file 'x'
check "replay: 'PR #3675 is still a draft' while the maintainer had marked it ready: blocked, saying what GitHub says (the repo from the checkout's remote)" "2 1" \
  "$(slj "I'm watching #3675 for replies. PR #3675 is still a draft with CI green. It waits on brillout." 0 s-fc "$T/vkr") $(grep -c 'is a draft, you say.*ready for review' "$T/err")"
check "a PR state that matches GitHub passes; a conditional is no claim" "0 0" "$(slj 'https://github.com/vikejs/vike/pull/3675 is ready for review, and its CI is green.') $(slj 'Once vikejs/vike#3675 is merged, I will update the docs.')"
check "BLOCK: a PR state claimed about a PR gh can't read" "2 1" "$(slj 'PR o/r#99 is still a draft.') $(grep -c "gh couldn't read that PR" "$T/err")"
check "BLOCK: a done message linking a PR gh can't read" "2 1" "$(slj 'All done: https://github.com/o/r/pull/404 has the fix.') $(grep -c "couldn't read it" "$T/err")"
TK4="$HOME/.mergeworthy/work/fc-task"; mkdir -p "$TK4"; printf 'Tier: S, because one fix\n\n- [ ] Fix CI https://github.com/o/r/pull/71\n' > "$TK4/scope.md"
uf() { python3 - "$T/tr.jsonl" "$@" <<'PY'
import json, sys
out = open(sys.argv[1], 'w'); w = lambda e: out.write(json.dumps(e) + '\n')
w({"type": "user", "message": {"content": "Fix CI https://github.com/o/r/pull/71"}})
w({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "s1", "name": "Skill", "input": {"skill": "mergeworthy:task"}}]}})
for ev in sys.argv[2:-1]:
    k, _, v = ev.partition(':')
    if k == 'monitor':
        w({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "m-" + v, "name": "Monitor", "input": {"command": "gh run watch 1"}}]}})
        w({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "m-" + v, "content": f"Monitor started (task {v}, expires in 30m unless the source ends first)"}]}})
    elif k == 'ended':
        w({"type": "user", "message": {"content": f"<task-notification>\n<task-id>{v}</task-id>\n<status>completed</status>\n</task-notification>"}})
w({"type": "assistant", "message": {"content": [{"type": "text", "text": sys.argv[-1]}]}})
PY
}
check "BLOCK: a task's turn ending with a scope.md box open and nothing armed to wake it, naming the item" "2 1" "$(uf 'I pushed the fix; CI runs on the new head.'; slj '' 0 s-uf "$TK4") $(grep -c 'Fix CI https://github.com/o/r/pull/71' "$T/err")"
check "a Monitor it armed lets the turn end; once that Monitor ended, it doesn't" "0 2" "$(uf monitor:m1 'Waiting on CI.'; slj '' 0 s-uf "$TK4") $(uf monitor:m1 ended:m1 'Waiting on CI.'; slj '' 0 s-uf "$TK4")"
check "a GENUINE-FORK the user must answer ends it; every box ticked ends it" "0 0" "$(uf $'Two ways remain.\n\nGENUINE-FORK: a or b; I recommend a.'; slj '' 0 s-uf "$TK4") $(sed -i 's/- \[ \]/- [x]/' "$TK4/scope.md"; uf 'Done.'; slj '' 0 s-uf "$TK4")"
check "replay: the session's first turn (task opened, no scope.md anywhere): blocked, naming task steps 2-3" "2 1" "$(uf 'I could not push the fix.'; slj '' 0 s-uf "$VK") $(grep -c 'task steps 2-3' "$T/err")"
WD2="$T/deadw"; mkdir -p "$WD2"; echo 999999 > "$WD2/gh-watch.pid"; echo 'o/r 5 comment 42 by maint' > "$WD2/replies-owed.md"; echo "$WD2" > "$HOME/.claude/gh-watch-dirs.txt"
tr_file 'README tidied.'
check "BLOCK: a dead watcher's open owed line; a retired watcher's passes" "2 0" "$(slj '' 0 s-fc "$WD2") $(touch "$WD2/retired"; slj '' 0 s-fc "$WD2")"
: > "$HOME/.claude/gh-watch-dirs.txt"
# the verifier's round on this change: each case it reproduced
check "parse: a push after (( << )), in an unquoted heredoc's \$( ), in \${x:-\$( )}, in \$(( \$( ) )), after a case in \$( ); none in a quoted heredoc" "yes yes yes yes yes no" \
  "$(pushes $'(( y = 1 << 3 ))\ngit push origin HEAD') $(pushes $'cat > f <<EOF\n$(git push)\nEOF') $(pushes 'echo ${x:-$(git push)}') $(pushes 'echo $(( $(git push) + 1 ))') $(pushes 'echo $(case y in y) git push;; esac)') $(pushes $'cat > f <<\'EOF\'\n$(git push)\nEOF')"
check "parse: a heredoc with no end line says so; a quoted } in \${x:-\"a}b\"} parses" "yes no" "$(sp $'cat <<E\nno end' | grep -q ERR && echo yes || echo no) $(sp 'echo ${x:-"a}b"}; git push' | grep -q ERR && echo yes || echo no)"
check "a cd to \$(git rev-parse --show-toplevel), or cd -P, is followed" "0 0" \
  "$(MERGEWORTHY_WATCHER=off bg 'cd "$(git rev-parse --show-toplevel)" && git push https://github.com/nitedani-agent/vike.git HEAD:fix-telefunc' "$CK") $(MERGEWORTHY_WATCHER=off bg "cd -P $CK && git push https://github.com/nitedani-agent/vike.git HEAD:fix-telefunc" "$T")"
check "BLOCK: a push to GitLab while glab can't say whose repo it is or list its MRs" 2 "$(GH_STUB_NOHOST=1 MERGEWORTHY_WATCHER=off bg 'git push https://gitlab.com/ns/p.git HEAD:fix-telefunc' "$CK")"
tr_cmd 'git stash push -u -m wip-tag'
check "git stash push is no push: the session isn't a task's by it" 0 "$(slj)"
tr_file 'README tidied.'
check "words that only contain an offer (your callback, ping messages) aren't one" "0 0" "$(slj 'The new hook now fires your callback once per event.') $(slj 'The bot no longer sends duplicate ping messages.')"
echo '{"number":42,"title":"a bug"}' > "$FX/repos_o_r_issues_42"
check "a state with no PR in its sentence, local checks, or an issue's state is no PR claim" "0 0 0" \
  "$(slj 'Pushed the fix to o/r#12. Local checks are passing; CI is still running.') $(slj 'Fixes o/r#42 (the issue). The upstream fix is merged into main.') $(slj 'o/r#42 is merged.')"
python3 -c 'import json; print(json.dumps({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"Act as the review sub-agent for this task"}]}})); print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"README tidied."}]}}))' > "$T/tr.jsonl"
check "a tool result quoting the sub-agent line is no crash (and no child)" 0 "$(slj)"
# Only collaboration pays the push gates: a push of its own (its own repo, no PR) is free, a PR's head or another owner's repo is not
OWN="$T/own"; git init -q -b scratch "$OWN"; git -C "$OWN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a; git -C "$OWN" remote add origin https://github.com/nitedani-agent/notes.git
gql nitedani-agent nitedani-agent
check "a push through git -C \"\$D\" reads its remote in the checkout \$D names" 0 "$(bg "D=$OWN; git -C \"\$D\" push origin HEAD:scratch" "$T")"
check "a push to its own repo's branch with no PR, from no work folder, passes; once that branch is a PR's head it is blocked, naming the PR" "0 2 1" \
  "$(bg 'git push origin HEAD:scratch' "$OWN") $(gql nitedani-agent nitedani-agent https://github.com/nitedani-agent/notes/pull/1; bg 'git push origin HEAD:scratch' "$OWN") $(grep -c 'updates https://github.com/nitedani-agent/notes/pull/1' "$T/err")"
gql nitedani-agent vikejs
check "BLOCK: a push to another owner's repo, with no PR, naming why" "2 1" "$(bg 'git push https://github.com/vikejs/vike.git HEAD:scratch' "$OWN") $(grep -c "vikejs/vike isn't nitedani-agent's" "$T/err")"
rm "$FX/graphql"; echo nitedani-agent > "$FX/login"
check "gh can't answer: a push to its own repo passes from a checkout of no one else's repo, and blocks from a fork of another owner's" "0 2 1" \
  "$(bg 'git push origin HEAD:scratch' "$OWN") $(git -C "$OWN" remote add upstream https://github.com/vikejs/vike.git; bg 'git push origin HEAD:scratch' "$OWN") $(grep -c "gh couldn't tell whether this push" "$T/err")"
rm "$FX/login"
check "a cd this hook can't follow doesn't block a local commit or a read; a push from there blocks, saying why" "0 0 2 1" \
  "$(bg 'cd "$(mktemp -d)" && git init -q && git commit -q --allow-empty -m x' "$T") $(bg 'cd "$W" && gh pr view 5 -R o/r' "$T") $(bg 'cd "$W" && git push origin HEAD' "$T") $(grep -c "can't tell which checkout this push runs in" "$T/err")"
PD="$T/pydeps"; mkdir -p "$PD"; echo 'its install failed (offline)' > "$PD/$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()[:16])' "$R/hooks/requirements.txt").failed"
check "the parser can't be installed: a push blocks, saying why; a command with no guarded verb passes" "2 1 0" \
  "$(MERGEWORTHY_PYDEPS=$PD bg 'git push origin HEAD' "$OWN") $(grep -c "shell parser.*its install failed (offline)" "$T/err") $(MERGEWORTHY_PYDEPS=$PD bg 'ls -la' "$OWN")"
check "parse: mvdan/sh reads what tree-sitter-bash dropped: a commit after a sed with (a|b), the - of python3 - <<E" '1 [["python3", "-", "<<"]]' \
  "$(sp $'grep -E x l | sed -E \'s/"o":(true|false)//\' | cut -c1-9\ngit add f\ngit commit -q -F - <<\'EOF\'\nmsg\nEOF' | grep -c '\["git", "commit", "-q"\]') $(sp $'python3 - <<E\nx\nE')"
printf '{"state":"open","draft":false,"merged":false,"html_url":"https://github.com/o/r/pull/12","head":{"sha":"abc"},"base":{"repo":{"full_name":"o/r"}}}' > "$FX/repos_o_r_pulls_12"
tr_file 'README tidied.'
check "a PR-state claim is checked only with the PR as its subject: not my reply to it, a quote, inline code or a code block" "2 0 0 0 0" \
  "$(slj 'o/r#12 is still a draft.') $(slj 'My reply to o/r#12 is a draft.') $(slj '> o/r#12 is still a draft') $(slj 'The lint flagged `o/r#12 is a draft`.') $(slj $'```\no/r#12 is a draft\n```')"
# the bug hunt's push cases: every URL form, a computed remote, pushurl, --repo, pushInsteadOf, a later syntax error, an array
gql nitedani-agent nitedani-agent; gql nitedani-agent vikejs; mv "$FX/graphql" "$FX/graphql_vikejs"; gql nitedani-agent nitedani-agent
OWN2="$T/own2"; git clone -q "$OWN" "$OWN2"; git -C "$OWN2" remote set-url origin https://github.com/nitedani-agent/notes.git
bp=; for c in 'git push https://x-access-token:T@github.com/vikejs/vike.git HEAD:s' 'git push ssh://git@github.com:22/vikejs/vike.git HEAD:s' \
             'git push https://GitHub.com/vikejs/vike HEAD:s' 'git push git@example.org:me/x.git HEAD:s' 'U=https://github.com/vikejs/vike.git; git push $U HEAD:s' \
             'git push --repo=https://github.com/vikejs/vike.git' $'"g"it push origin HEAD:s\nfi' 'a=(git push https://github.com/vikejs/vike.git HEAD:s); "${a[@]}"'; do
  bp="$bp $(bg "$c" "$OWN2")"; done
check "BLOCK: a push to another owner's repo however written: a token in the URL, ssh://host:port, GitHub.com, an unknown host, a variable, --repo, a quoted verb before a syntax error, an array" \
  " 2 2 2 2 2 2 2 2" "$bp"
git -C "$OWN2" config remote.origin.pushurl https://github.com/vikejs/vike.git
check "BLOCK: a remote whose pushurl is another owner's repo" 2 "$(bg 'git push origin HEAD:s' "$OWN2")"
git -C "$OWN2" config --unset remote.origin.pushurl; git -C "$OWN2" config url.https://github.com/vikejs/.pushInsteadOf https://github.com/nitedani-agent/
check "BLOCK: a URL that pushInsteadOf rewrites to another owner's repo; without the rewrite it passes" "2 0" \
  "$(bg 'git push https://github.com/nitedani-agent/notes.git HEAD:s' "$OWN2") $(git -C "$OWN2" config --unset url.https://github.com/vikejs/.pushInsteadOf; bg 'git push https://github.com/nitedani-agent/notes.git HEAD:s' "$OWN2")"
check "parse: bash -c -- '<script>', \$'\\x67it', a herestring to bash -s, bash /dev/stdin <<EOF, find -exec, watch" "yes yes yes yes yes yes" \
  "$(pushes "bash -c -- 'git push'") $(pushes "\$'\\x67it' push") $(pushes "bash -s x <<< 'git push'") $(pushes $'bash /dev/stdin <<EOF\ngit push\nEOF') $(pushes 'find . -maxdepth 0 -exec git push \;') $(pushes 'watch -n 5 git push')"
printf '{"state":"open","draft":false,"merged":false,"html_url":"https://github.com/o/r/pull/12","head":{"sha":"abc"},"base":{"repo":{"full_name":"o/r"}}}' > "$FX/repos_o_r_pulls_12"
printf '{"check_runs":[{"name":"t","status":"completed","conclusion":"failure"}]}' > "$FX/repos_o_r_commits_abc_check-runs_per_page_100"
tr_file 'README tidied.'
check "a condition or a plan names no state: once, until, if, will, next week, next Tuesday, next sprint" "0 0 0 0 0" \
  "$(slj 'I will update the docs once PR o/r#12 is merged.') $(slj 'I am waiting until PR o/r#12 is green.') $(slj 'If the maintainer agrees, PR o/r#12 is merged next week.') $(slj 'o/r#12 is green next Tuesday.') $(slj 'o/r#12 is green next sprint.')"
check "BLOCK: a CI claim GitHub contradicts, however phrased" "2 2 2 2" \
  "$(slj 'o/r#12: CI is green.') $(slj 'CI is green on o/r#12.') $(slj 'All 12 checks pass on o/r#12.') $(slj 'o/r#12 is green.')"
check "the condition words count only in the claim's own clause: an earlier clause doesn't hide it" "2 2 2" \
  "$(slj 'After the rebase, o/r#12 is green.') $(slj 'Fixed the test that failed when run in parallel; o/r#12 is green now.') $(slj 'No need to wait: o/r#12 is green.')"
check "BLOCK: a plan in the next clause doesn't hide a state claim" "2 2" "$(slj 'o/r#12 is green, and I will merge it.') $(slj 'o/r#12 is green and I am waiting for review.')"
check "BLOCK: a negation after the state words doesn't take the claim back" 2 "$(slj 'o/r#12 is green with no failures.')"
check "BLOCK: a question after it doesn't hide a state claim" 2 "$(slj 'o/r#12 is green, any questions?')"
check "BLOCK: a time word after the state words doesn't hide the claim" 2 "$(slj 'o/r#12 is green after the rebase.')"
check "BLOCK: an expectation after the state words doesn't hide the claim" 2 "$(slj 'o/r#12 is green as expected.')"
tr_file 'All done with the next steps documented: https://gitlab.com/g/p/-/merge_requests/96'
check "BLOCK: \"next\" that isn't a time leaves the claim standing" 2 "$(stop "$T")"
tr_file 'https://gitlab.com/research-and-development/next/-/merge_requests/96 is ready for review.'
check "BLOCK: words inside a URL take nothing back" 2 "$(stop "$T")"
tr_file 'Waiting on https://example.com/build; https://gitlab.com/g/p/-/merge_requests/96 is ready for review.'
check "BLOCK: the semicolon after a URL still ends its part" 2 "$(stop "$T")"
check "a condition over the claim's part (past a URL's colon) states nothing; one opening the next part leaves it standing" "0 0 2" \
  "$(slj 'Once CI passes and o/r#12 is green, I merge.') $(slj 'Once CI passes and https://github.com/o/r/pull/12 is green, I merge.') $(slj 'o/r#12 is merged, if the maintainer agrees.')"
rm -f "$FX/repos_o_r_commits_abc_check-runs_per_page_100"
# the second bug hunt: where git really pushes (-c, GIT_CONFIG_*, every -C, pushDefault), --git-dir and GIT_DIR, a name that is no remote
OTH="$T/oth"; git clone -q "$OWN" "$OTH"; git -C "$OTH" remote set-url origin https://github.com/vikejs/vike.git
bp=; for c in 'git -c remote.x.url=https://github.com/vikejs/vike.git push x HEAD:s' 'git push nosuch HEAD:s' \
             'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.pushurl GIT_CONFIG_VALUE_0=https://github.com/vikejs/vike.git git push origin HEAD:s' \
             "GIT_DIR=$OTH/.git git push origin HEAD:s" "git --git-dir=$OTH/.git push origin HEAD:s" "git -C /tmp -C $OTH push origin HEAD:s"; do
  bp="$bp $(bg "$c" "$OWN2")"; done
git -C "$OWN2" remote add upstream https://github.com/vikejs/vike.git; git -C "$OWN2" config remote.pushDefault upstream; git -C "$OWN2" checkout -q -b fresh
check "BLOCK: a push redirected by -c, GIT_CONFIG_*, a later -C, --git-dir or GIT_DIR, to a name that is no remote, or by remote.pushDefault" " 2 2 2 2 2 2 2" "$bp $(bg 'git push' "$OWN2")"
git -C "$OWN2" checkout -q scratch; git -C "$OWN2" config --unset remote.pushDefault
fp=; for c in '"$(npm bin)/vitest" run tests/git-push.test.ts' '$PYTHON -m pytest -k "git push"' '"$VENV/bin/pytest" -k git-commit' \
             '${PNPM:-pnpm} test && git log --oneline | grep -i commit' '"$CLAUDE" -p "summarize the last git commit"'; do fp="$fp $(bg "$c" "$OWN2")"; done
check "a command named by an expansion that only mentions git (a test name, a prompt) passes" " 0 0 0 0 0" "$fp"
check "env's assignment named by a variable (\"\$v=host\") is no command name: the glab call after it passes, a push after it is still checked" "0 2" \
  "$(bg 'env -i HOME="$HOME" "$v=code.example.com" timeout 20 glab api projects/x' "$OWN2") $(bg 'env "$v=x" git push nosuch HEAD:s' "$OWN2")"
check "a command named by a variable the command set is checked as what it runs: \$G commit with the right author passes, a wrong one blocks" "0 2" \
  "$(echo 'me 42' > "$HOME/.claude/gh-user.txt"; bg 'G="git -c user.name=me -c user.email=42+me@users.noreply.github.com"; $G commit -m x' "$TCO") $(bg 'G="git -c user.name=x -c user.email=x@x"; $G commit -m x' "$TCO")"
check "a git -C to a variable the command set is the checkout it names: a commit there with the right author passes, a wrong one blocks" "0 2" \
  "$(bg "D=$TCO; git -C \"\$D\" -c user.name=me -c user.email=42+me@users.noreply.github.com commit -m x" "$T") $(bg "D=$TCO; git -C \"\$D\" -c user.name=x -c user.email=x@x commit -m x" "$T")"
gql nitedani-agent nitedani-agent
check "a computed sha pushed to its own repo with no PR passes (an evidence upload); a computed lease is a lease" "0 0" \
  "$(bg 'c=$(git rev-parse HEAD); git push origin $c:refs/heads/shots' "$OWN2") $(bg 'git push --force-with-lease=scratch:$(git rev-parse HEAD) origin HEAD:scratch' "$OWN2")"
check "BLOCK: a computed sha on a collaboration push, and a computed branch" "2 2" \
  "$(bg 'c=$(git rev-parse HEAD); git push https://github.com/vikejs/vike.git $c:refs/heads/x' "$OWN2") $(bg 'b=x; git push origin HEAD:$b' "$OWN2")"
# the T3 worktree layout: <task>-work/ holding scope.md, its checkouts inside it or beside it under the task's prefix (fu185-work/, fu185-gps/)
TW="$T/t3wt"; mkdir -p "$TW/fu185-work"; printf 'Tier: S, because x\n\n- [ ] y https://github.com/o/r/issues/1\n' > "$TW/fu185-work/scope.md"
for c in fu185-gps fu185-work/stack other; do git clone -q "$OTH" "$TW/$c"; git -C "$TW/$c" remote set-url origin https://github.com/vikejs/vike.git; done
check "a checkout inside <task>-work/ or beside it under the task's prefix is in that work folder; an unrelated one isn't" "0 0 1" \
  "$(bg 'git push origin HEAD:s' "$TW/fu185-gps" >/dev/null; grep -c "isn't in a task's work folder" "$T/err") $(bg 'git push origin HEAD:s' "$TW/fu185-work/stack" >/dev/null; grep -c "isn't in a task's work folder" "$T/err") $(bg 'git push origin HEAD:s' "$TW/other" >/dev/null; grep -c "isn't in a task's work folder" "$T/err")"
AS="$T/assets"; git clone -q "$OWN" "$AS"; git -C "$AS" update-ref refs/remotes/origin/HEAD HEAD; git -C "$AS" checkout -q --orphan shots; git -C "$AS" -c user.name=t -c user.email=t@t commit -q --allow-empty -m s
check "a commit on a branch that shares no history with origin's default (a PR's screenshots) needs no preflight; one on a branch of the product does" "0 2" \
  "$(bg 'git commit -q --allow-empty -m s2' "$AS") $(git -C "$AS" checkout -q scratch; bg 'git commit -q --allow-empty -m c' "$AS")"
check "a push from a checkout the command makes first passes when it goes to a local path or the local repo it was cloned from (named by variables too), or is a dry run" "0 0 0 0 2" \
  "$(bg 'T=$(mktemp -d); cd $T; git init -q --bare o.git; git init -q r; cd r; git push -q ../o.git main' "$T") $(bg 'git clone -q /tmp/o.git seed && cd seed && git push -q origin HEAD:main' "$T") $(bg 'S=/tmp/o.git; D=seed2; git clone -q "$S" "$D" && cd "$D" && git push -q origin HEAD:main' "$T") $(bg 'git worktree add -q --detach ../wt HEAD; cd ../wt; git push --dry-run https://github.com/vikejs/vike.git HEAD:x' "$T") $(bg 'git clone -q https://github.com/vikejs/vike.git v; cd v; git push origin HEAD:x' "$T")"
check "a draft path through a variable the command set (D=...; --body-file \$D/x.md) is the path written out" 1   "$(MERGEWORTHY_WATCHER=off bg "X=$T/vdir; gh issue create --repo o/r --title t --body-file \$X/nogate.md" "$T" >/dev/null; grep -c "no gate record for $T/vdir/nogate.md" "$T/err")"
check "parse: a script handed to watch or parallel, and git run by pnpm exec, npx, uv run, direnv exec, flock, taskset, chronic, su -c, script -c, fish -c" \
  "yes yes yes yes yes yes yes yes yes yes yes yes yes" "$(for c in "watch 'git push x HEAD:y'" "parallel 'git push {} HEAD:y' ::: x" 'pnpm exec git push' 'npx git push' 'uv run git push' \
    'direnv exec . git push' 'flock /tmp/l git push' 'taskset 0x1 git push' 'chronic git push' "su -c 'git push' me" "script -qc 'git push' /dev/null" "fish -c 'git push'" 'parallel -k git push ::: x'; do printf '%s ' "$(pushes "$c")"; done | xargs)"
check "BLOCK: a shell running a computed script that holds a guarded verb" 2 "$(bg 'sh -c "$(printf "git push x")"' "$OWN2")"
# GitLab: a push to a group's repo is collaboration; one to the user's own namespace only while it is an open MR's source branch
cat > "$T/bin/glab" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2 $3" = "config get user" ] && { [ ! -f "$FX/gl_login" ] || cat "$FX/gl_login"; exit; }
[ "$1" = api ] || exit 1
f="$FX/gl_$(printf '%s' "$4" | tr '/?&=%' '_____')"
[ -f "$f" ] && cat "$f" || { echo 'glab: 404 Not found (HTTP 404)' >&2; exit 1; }
[ "$5" != --paginate ] || [ ! -f "$f.page2" ] || cat "$f.page2"  # glab prints the next page's array right after the first
EOF
GL="$T/gl"; git init -q -b scratch "$GL"; git -C "$GL" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a; git -C "$GL" remote add origin git@gitlab.com:me/app.git
for mr in me_2Fapp_merge_requests_4 me_2Fapp_merge_requests_5 me_2Fapp_merge_requests_6 acme_2Fapp_merge_requests_9; do echo '{"head_pipeline":null}' > "$FX/gl_projects_$mr"; done  # the MRs below have no pipeline
echo me > "$FX/gl_login"; echo '[]' > "$FX/gl_projects_me_2Fapp_merge_requests_state_opened_source_branch_scratch"; echo '[]' > "$FX/gl_projects_acme_2Fapp_merge_requests_state_opened_source_branch_scratch"
(cd "$GL" && bash "$R/bin/pr-steps" preflight 'none, because the test repo has no UI' >/dev/null)
check "a commit in a checkout of a GitLab repo isn't held to gh's account" 0 "$(bg 'git -c user.name=Someone -c user.email=me@example.com commit -q --allow-empty -m x' "$GL")"
check "GitLab: ssh://git@gitlab.com:22/ is the same own namespace" 0 "$(bg 'git push ssh://git@gitlab.com:22/me/app.git HEAD:scratch' "$GL")"
check "GitLab: a push to its own namespace with no MR passes; to a group's repo, or an open MR's branch, it is blocked, naming why" "0 2 1 2 1" \
  "$(bg 'git push origin HEAD:scratch' "$GL") $(bg 'git push git@gitlab.com:acme/app.git HEAD:scratch' "$GL") $(grep -c "acme/app isn't me's" "$T/err") $(echo '[{"web_url":"https://gitlab.com/me/app/-/merge_requests/4","draft":true}]' > "$FX/gl_projects_me_2Fapp_merge_requests_state_opened_source_branch_scratch"; bg 'git push origin HEAD:scratch' "$GL") $(grep -c 'updates https://gitlab.com/me/app/-/merge_requests/4' "$T/err")"
# pull-request step 5 comes before the build and the draft PR: a branch with no approach record opens no PR or MR, draft or not, and updates no open one
NA="$TASKW/mr-b"; git init -q -b mr-b "$NA"; git -C "$NA" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a; git -C "$NA" remote add origin git@gitlab.com:me/app.git; quick "$NA"
echo '[{"web_url":"https://gitlab.com/me/app/-/merge_requests/5","draft":true}]' > "$FX/gl_projects_me_2Fapp_merge_requests_state_opened_source_branch_mr-b"
printf '%s\n**State: draft** (my bug check is still running)\n\nRoutes after vike(app) skip the auth +middleware. This PR runs it first.\n' '<img src="https://github.com/claude.png" width="20" height="20" alt="Claude">' > "$T/na.md"; sha256sum "$T/na.md" | cut -d' ' -f1 > "$T/na.md.gate"
na() { for c in "gh pr create --draft --repo o/r --title \"\$(cat /w/drafts/title.md)\" --body-file $T/na.md" "gh api repos/o/r/pulls -f title=x -f head=mr-b -f base=main -F body=@$T/na.md" \
                'glab mr create --draft --title x' 'glab api projects/me%2Fapp/merge_requests -X POST -f source_branch=mr-b -f target_branch=main -f title=x' 'git push origin HEAD:mr-b'; do
    printf '%s %s ' "$(MERGEWORTHY_WATCHER=off bg "$c" "$NA")" "$(grep -c 'pull-request step 5).*pr-steps approach <work folder>/approach.md' "$T/err")"; done | xargs; }
check "BLOCK: with no approach record, a draft gh pr create, gh api POST pulls, a draft glab mr create, glab api POST merge_requests and a push updating an open MR, naming step 5" "2 1 2 1 2 1 2 1 2 1" "$(na)"
echo '[]' > "$FX/gl_projects_acme_2Fapp_merge_requests_state_opened_source_branch_mr-b"
check "a collaboration push updating no PR or MR needs no approach record" 0 "$(MERGEWORTHY_WATCHER=off bg 'git push git@gitlab.com:acme/app.git HEAD:mr-b' "$NA")"
api_forms() { for c in "GH_REPO=o/r gh api 'repos/{owner}/{repo}/pulls' -f title=x -f head=mr-b -f base=main -F body=@$T/na.md" "gh api /repos/o/r/pulls -f title=x -f head=mr-b -f base=main -F body=@$T/na.md" \
                       "gh api https://api.github.com/repos/o/r/pulls -f title=x -f head=mr-b -f base=main -F body=@$T/na.md" "gh api https://github.example.com/api/v3/repos/o/r/pulls -f title=x -f head=mr-b -f base=main -F body=@$T/na.md" \
                       'glab api api/v4/projects/me%2Fapp/merge_requests -X POST -f source_branch=mr-b -f target_branch=main -f title=x' "glab api 'projects/me%2Fapp/merge_requests?foo=bar' -X POST -f source_branch=mr-b -f target_branch=main -f title=x" \
                       'glab api https://gitlab.com/api/v4/projects/me%2Fapp/merge_requests -X POST -f source_branch=mr-b -f target_branch=main -f title=x'; do
    printf '%s ' "$(MERGEWORTHY_WATCHER=off bg "$c" "$NA")"; done | xargs; }
check "BLOCK: with no approach record, a PR or MR created through the API in each form gh and glab take ({owner}/{repo}, a leading slash, a full URL, GitHub Enterprise's, api/v4/, a query)" "2 2 2 2 2 2 2" "$(api_forms)"
check "BLOCK: an issue opened through the API in those forms, in a repo no watcher covers, naming it with its host" "2 1 2 1 2 1 2 1" \
  "$(bg "GH_REPO=nobody/x gh api 'repos/{owner}/{repo}/issues' -f title=x -F body=@$T/na.md" "$NA") $(grep -c 'no running watcher of this task or session covers nobody/x' "$T/err") $(bg "glab api '/api/v4/projects/nobody%2Fx/issues?x=1' -X POST -f title=x" "$NA") $(grep -c 'no running watcher of this task or session covers gitlab.com/nobody/x' "$T/err") $(bg 'glab api https://gitlab.example.com/api/v4/projects/nobody%2Fx/issues -X POST -f title=x' "$NA") $(grep -c 'no running watcher of this task or session covers gitlab.example.com/nobody/x' "$T/err") $(bg "gh api https://github.example.com/api/v3/repos/nobody/x/issues -f title=x -F body=@$T/na.md" "$NA") $(grep -c 'no running watcher of this task or session covers github.example.com/nobody/x' "$T/err")"
check "BLOCK: an issue or MR opened through the API by a project's numeric id, since which project it is can't be told, naming that" "2 1" \
  "$(bg 'glab api projects/123/issues -X POST -f title=x' "$NA") $(grep -c "can't tell which repo this acts on" "$T/err")"
check "a GitLab project path through the API is on --hostname's or GITLAB_HOST's host" "2 1 2 1" \
  "$(bg 'glab api --hostname gl.example.com projects/nobody%2Fx/issues -X POST -f title=x' "$NA") $(grep -c 'no running watcher of this task or session covers gl.example.com/nobody/x' "$T/err") $(bg 'GITLAB_HOST=https://h.example.com glab api projects/nobody%2Fx/issues -X POST -f title=x' "$NA") $(grep -c 'no running watcher of this task or session covers h.example.com/nobody/x' "$T/err")"
(cd "$NA" && bash "$R/bin/pr-steps" approach "$T/approach.md" >/dev/null)
check "each passes once the branch has its approach record" "0 0 0 0 0 0 0 0 0 0" "$(na)"
check "the API forms pass too" "0 0 0 0 0 0 0" "$(api_forms)"
# a push is held to the approach of each branch it publishes, whichever is checked out
git -C "$NA" checkout -q -b unrelated
echo '[{"web_url":"https://gitlab.com/me/app/-/merge_requests/6","draft":true}]' > "$FX/gl_projects_me_2Fapp_merge_requests_state_opened_source_branch_unrecorded"
check "a push of a recorded branch passes from an unrecorded one; of an unrecorded branch with an open MR, from a recorded one, it blocks, naming the branch" "0 2 1" \
  "$(MERGEWORTHY_WATCHER=off bg 'git push origin mr-b:mr-b' "$NA") $( (cd "$NA" && bash "$R/bin/pr-steps" approach "$T/approach.md" >/dev/null); git -C "$NA" branch -q unrecorded; MERGEWORTHY_WATCHER=off bg 'git push origin unrecorded:unrecorded' "$NA") $(grep -c 'unrecorded has no approach record' "$T/err")"
# a PR or MR create is held to the record of the branch it names (--head, -H owner:branch, --source-branch, -s, head=, source_branch=), else the checked-out one
named() { for c in 'glab mr create --draft --source-branch unrecorded --title x' 'glab mr create --draft -s unrecorded --title x' \
    "gh pr create --draft --repo o/r --title \"\$(cat /w/drafts/title.md)\" --body-file $T/na.md --head $1" "gh pr create --draft --repo o/r --title \"\$(cat /w/drafts/title.md)\" --body-file $T/na.md -H someone:$1" \
    "gh api repos/o/r/pulls -f title=x -f head=someone:$1 -f base=main -F body=@$T/na.md" "glab api projects/me%2Fapp/merge_requests -X POST -f source_branch=$1 -f target_branch=main -f title=x"; do
    printf '%s %s ' "$(MERGEWORTHY_WATCHER=off bg "${c//unrecorded/$1}" "$NA")" "$(grep -c "$1 has no approach record" "$T/err")"; done | xargs; }
check "BLOCK: from a recorded checkout, a PR or MR create naming a branch with no record, in each form, naming it" "2 1 2 1 2 1 2 1 2 1 2 1" "$(named unrecorded)"
check "from a checkout with no record, a PR or MR create naming a recorded branch passes, in each form" "0 0 0 0 0 0 0 0 0 0 0 0" "$(git -C "$NA" checkout -q unrecorded; named mr-b; git -C "$NA" checkout -q unrelated)"
git -C "$NA" branch -q fresh; echo '[]' > "$FX/gl_projects_me_2Fapp_merge_requests_state_opened_source_branch_fresh"
check "BLOCK: a push updating an open MR needs the record of every branch it publishes, a new one beside it too, naming it" "2 1" \
  "$(MERGEWORTHY_WATCHER=off bg 'git push origin mr-b:mr-b fresh:fresh' "$NA") $(grep -c 'fresh has no approach record' "$T/err")"
ghpr() { python3 -c 'import json,sys; print(json.dumps({"data": {"viewer": {"login": "me"}, "repository": {"owner": {"login": "me"}, **{f"b{i}": {"associatedPullRequests": {"nodes": [{"url": "https://github.com/me/app/pull/7", "isDraft": True}] if x == "pr" else []}} for i, x in enumerate(sys.argv[1:])}}}}))' "$@" > "$FX/graphql_me"; }
check "BLOCK: the same on GitHub, naming it" "2 1" \
  "$(ghpr pr none; MERGEWORTHY_WATCHER=off bg 'git push https://github.com/me/app.git mr-b:mr-b fresh:fresh' "$NA") $(grep -c 'fresh has no approach record' "$T/err")"
echo '[{"web_url":"https://gitlab.com/acme/app/-/merge_requests/9","draft":true}]' > "$FX/gl_projects_acme_2Fapp_merge_requests_state_opened_source_branch_fresh"
check "BLOCK: a push updating an open MR of a group's GitLab project (not the login's) needs the record too, naming it" "2 1" \
  "$(MERGEWORTHY_WATCHER=off bg 'git push git@gitlab.com:acme/app.git fresh:fresh' "$NA") $(grep -c 'fresh has no approach record' "$T/err")"
# an MR's failing jobs are read from its head pipeline through glab, on the MR's host
git -C "$NA" checkout -q fresh; (cd "$NA" && bash "$R/bin/pr-steps" approach "$T/approach.md" >/dev/null); git -C "$NA" checkout -q unrelated
echo '{"head_pipeline":{"id":77}}' > "$FX/gl_projects_acme_2Fapp_merge_requests_9"
echo '[{"name":"flaky","status":"failed","allow_failure":true}]' > "$FX/gl_projects_acme_2Fapp_pipelines_77_jobs_scope[]_failed_scope[]_canceled_per_page_100"
check "a push updating a draft MR of a group's GitLab project passes with its approach recorded and only an allowed-to-fail job failing" 0 \
  "$(MERGEWORTHY_WATCHER=off bg 'git push git@gitlab.com:acme/app.git fresh:fresh' "$NA")"
echo '[{"name":"lint","status":"failed"}]' > "$FX/gl_projects_acme_2Fapp_pipelines_77_jobs_scope[]_failed_scope[]_canceled_per_page_100"
check "BLOCK: the same push while the MR's pipeline has a failed job its gate log doesn't name, naming the job and the MR" "2 1" \
  "$(MERGEWORTHY_WATCHER=off bg 'git push git@gitlab.com:acme/app.git fresh:fresh' "$NA") $(grep -c 'these CI jobs fail (https://gitlab.com/acme/app/-/merge_requests/9).*"lint"' "$T/err")"
python3 -c 'import json; print(json.dumps([{"name": f"flaky-{i}", "status": "failed", "allow_failure": True} for i in range(100)]))' > "$FX/gl_projects_acme_2Fapp_pipelines_77_jobs_scope[]_failed_scope[]_canceled_per_page_100"
echo '[{"name":"lint","status":"failed"}]' > "$FX/gl_projects_acme_2Fapp_pipelines_77_jobs_scope[]_failed_scope[]_canceled_per_page_100.page2"
check "BLOCK: the same with the failed job on the second page of the pipeline's jobs, behind 100 allowed-to-fail ones, naming it" "2 1" \
  "$(MERGEWORTHY_WATCHER=off bg 'git push git@gitlab.com:acme/app.git fresh:fresh' "$NA") $(grep -c 'these CI jobs fail (https://gitlab.com/acme/app/-/merge_requests/9).*"lint"' "$T/err")"
tr_cmd 'cd /tmp/x && git push origin HEAD:fix'
check "a session that pushed, with no scope.md in a work folder it used, is told to write one (stop-lint reads its git commands)" "2 1" "$(slj 'Pushed the fix.') $(grep -c 'no work folder it used has a scope.md' "$T/err")"
check "the parses a stop made are kept for the session's next stop, which blocks the same" "1 2" "$(ls "$HOME/.claude/mergeworthy-parses/s-fc.json" | wc -l) $(slj 'Pushed the fix.')"
# a plain question answered (no task, work folder, push, post, watcher or agent) is no mergeworthy work: no check-in, no hand-back check
qa() { python3 -c 'import json,sys
print(json.dumps({"type":"user","message":{"content":"can you access ssh the opensource machine?"}}))
print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":"b1","input":{"command":"hostname"}}]}}))
print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":sys.argv[1]}]}}))' "$1" > "$T/tr.jsonl"; }
QA1="No. This session runs on a different box, not opensource. T3 Code also runs on this machine, so I can give you a pairing link if you want to use it from a phone."
QA2="opensource doesn't show up in this machine's Tailscale peer list. If the firewall note is out of date and you want me to test it, say so and I'll check port 22."
check "a plain Q&A answer (the user's 'can you access ssh the opensource machine?' session) gets no check-in and no hand-back block" "0 0 0" "$(qa "$QA1"; ci qa-1) $(qa "$QA1"; slj) $(qa "$QA2"; slj)"
# the check-in asks only where work can still be waiting: a work folder it worked in, an agent it started, a Monitor
python3 -c 'import json
print(json.dumps({"type":"user","message":{"content":"make me four fox images, then pause"}}))
print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","id":"s1","input":{"skill":"mergeworthy:task"}}]}}))
print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"All four images are generated."}]}}))' > "$T/tr.jsonl"
check "a session that only opened the task skill gets no check-in" "0 0" "$(ci qa-2) $(grep -c 'Before you stop' "$T/err")"
CIW="$HOME/.mergeworthy/work/ci"; mkdir -p "$CIW"; printf 'Tier: 0, because one answer\n\n- [x] answer it\n' > "$CIW/scope.md"
check "a session in a work folder still gets the check-in" "2 1" "$(qa 'Answered.'; ci qa-3 "$CIW") $(grep -c 'Before you stop' "$T/err")"
tr_file $'#20 is in review.\n\nGENUINE-FORK: publish as 0.1.0, or 1.0.0; I recommend 0.1.0.' work
check "a message ending with a GENUINE-FORK line waits on the user: no check-in" 0 "$(ci qa-4)"
tr_file "$QA2" work
check "the same answer in a session that started an agent is a hand-back" 2 "$(slj)"
tr_file 'I have nothing else to start. The review waits on the maintainer, and the watcher will tell me when that happens.' work
check "'the watcher will tell me when' is no hand-back; 'Tell me when' and 'or ask me to' are" "0 2 2" "$(slj) $(slj 'Tell me when to re-check CI.') $(slj 'I can rerun it, or ask me to stop.')"
# ---------- pre-bash-guard: a code file's 6th change on the branch waits for `pr-steps simplify` ----------
SP="$T/simp"; git init -q -b main "$SP"; sc() { git -C "$SP" -c user.name=t -c user.email=t@t commit -q "$@"; }
echo 0 > "$SP/a.py"; mkdir "$SP/tests"; echo 0 > "$SP/tests/a_test.py"; git -C "$SP" add -A; sc -m base
git -C "$SP" update-ref refs/remotes/origin/main HEAD; git -C "$SP" checkout -q -b fix; (cd "$SP" && bash "$R/bin/pr-steps" preflight 'none, because no UI' >/dev/null)
for i in 1 2 3 4 5 6; do echo "d$i" >> "$SP/a.py"; sc -am "d$i"; done; echo d7 >> "$SP/a.py"; git -C "$SP" add a.py
check "before the branch's first review, a code file's 7th change passes: building counts nothing" 0 "$(bg 'git commit -m d7' "$SP")"
sc -m d7; printf 'NO LOOP B COMMITS\n' > "$T/rv.md"; (cd "$SP" && bash "$R/bin/pr-steps" reverify "$T/rv.md" >/dev/null) || echo "pr-steps verify failed in the simplify setup"
for i in 1 2 3 4; do echo "p$i" >> "$SP/a.py"; sc -am "p$i"; done
echo p5 >> "$SP/a.py"; r5=$(bg 'git commit -am p5' "$SP"); sc -am p5
echo p6 >> "$SP/a.py"; r6=$(bg 'git commit -am p6' "$SP"); n6=$(grep -c 'a.py would get a 6th change' "$T/err")
git -C "$SP" checkout -q a.py; echo t >> "$SP/tests/a_test.py"; git -C "$SP" add tests
check "a code file's 5th change on the branch passes; its 6th is refused, naming it; a test-only commit passes" "0 2 1 0" "$r5 $r6 $n6 $(bg 'git commit -m t' "$SP")"
echo p5b >> "$SP/a.py"; git -C "$SP" add a.py
check "an amend of the 5th change is no 6th" 0 "$(bg 'git commit --amend --no-edit' "$SP")"
git -C "$SP" checkout -q HEAD -- a.py
sc -m t; printf 'Class: each patch narrows which lines a counts\nDISTINCT\n' > "$T/simp.md"; (cd "$SP" && bash "$R/bin/pr-steps" simplify "$T/simp.md" >/dev/null)
echo p6 >> "$SP/a.py"; git -C "$SP" add a.py
check "with a simplify record on the head, the 6th change passes" 0 "$(bg 'git commit -m p6' "$SP")"
for i in 7 8 9 10 11 12; do echo "p$i" >> "$SP/a.py"; git -C "$SP" add a.py; sc -m "p$i"; done  # 6 changes since the record, made without the hook
echo p13 >> "$SP/a.py"; git -C "$SP" add a.py; r13=$(bg 'git commit -m p13' "$SP"); (cd "$SP" && bash "$R/bin/pr-steps" simplify "$T/simp.md" >/dev/null)
check "BLOCK: a 7th change; a simplify record on the head that holds the 6th unblocks it" "2 0" "$r13 $(bg 'git commit -m p13' "$SP")"
printf 'Class: each patch narrows which lines a counts\nSIMPLIFIED\n' > "$T/simp2.md"
check "BLOCK: pr-steps simplify SIMPLIFIED while the worktree's diff is no smaller than HEAD's" "1 1" "$(cd "$SP" && bash "$R/bin/pr-steps" simplify "$T/simp2.md" 2>"$T/err" >/dev/null; echo $?) $(grep -c 'no smaller than HEAD' "$T/err")"
# merges: a merge of the base, being made or in the history, is no change, and a simplify record on a merge commit counts
SM="$T/simpm"; git init -q -b main "$SM"; mc() { git -C "$SM" -c user.name=t -c user.email=t@t "$@"; }
seq 1 10 > "$SM/a.py"; git -C "$SM" add -A; mc commit -q -m base
git -C "$SM" update-ref refs/remotes/origin/main HEAD; git -C "$SM" checkout -q -b fix; (cd "$SM" && bash "$R/bin/pr-steps" preflight 'none, because no UI' >/dev/null)
(cd "$SM" && bash "$R/bin/pr-steps" reverify "$T/rv.md" >/dev/null)
for i in 1 2 3 4 5; do echo "p$i" >> "$SM/a.py"; mc commit -qam "p$i"; done
base_edit() { mc checkout -q main; sed -i "$1s/.*/main$1/" "$SM/a.py"; mc commit -qam "main$1"; git -C "$SM" update-ref refs/remotes/origin/main HEAD; mc checkout -q fix; mc merge -q --no-commit origin/main >/dev/null; }
base_edit 1
check "committing a merge of the base is no change, though the branch changed its file 5 times" 0 "$(bg 'git commit --no-edit' "$SM")"
mc commit -q --no-edit; (cd "$SM" && bash "$R/bin/pr-steps" simplify "$T/simp.md" >/dev/null)
for i in 6 7 8; do echo "p$i" >> "$SM/a.py"; mc commit -qam "p$i"; done; echo p9 >> "$SM/a.py"; git -C "$SM" add a.py
check "a simplify record on a merge commit starts the counts over" 0 "$(bg 'git commit -m p9' "$SM")"
mc commit -q -m p9; base_edit 2; mc commit -q --no-edit; echo p10 >> "$SM/a.py"; git -C "$SM" add a.py
check "a merge of the base in the history is no change either: the 5th change since the record passes" 0 "$(bg 'git commit -m p10' "$SM")"
mc commit -q -m p10; mc checkout -q -b side; for i in 1 2 3 4 5 6; do echo "s$i" >> "$SM/b.py"; mc add b.py; mc commit -qm "s$i"; done
mc checkout -q fix; mc merge -q --no-ff --no-edit side; echo f1 >> "$SM/b.py"; git -C "$SM" add b.py
check "the commits a merge of another branch brings in are not the branch's own: its next change of their file passes" 0 "$(bg 'git commit -m f1' "$SM")"
rm -rf "$T"
echo "failures: $fails"; [ "$fails" = 0 ]
