#!/usr/bin/env bash
# Tests for the hooks: stop-lint, pre-bash-guard's check_turn, post-bash-register. Usage: tests/hooks.sh [repo root]
# Runs every case under a temp HOME with a stub `gh` first on PATH; prints "case: <got> (want <want>)".
# Exits 0 only when every case gives what it wants. Stub URLs are example.invalid on purpose, except where
# post-bash-register must see github.com URLs (those go only into the hook's stdin, never to this script's output).
set -u
R=$(readlink -f "${1:-$(dirname "$0")/..}")
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME/.claude" "$T/bin" "$T/fx"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# stub gh: answers `gh api <path>` from $FX/<path with / ? & = replaced by _>; exit 1 when the fixture is missing (a 404)
[ "$1" = api ] || exit 1
f="$FX/$(printf '%s' "$2" | tr '/?&=' '____')"
[ -n "$GH_STUB_403" ] && { echo 'gh: API rate limit exceeded for user ID 1. (HTTP 403)' >&2; exit 1; }
[ -f "$f" ] && cat "$f" || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
EOF
chmod +x "$T/bin/gh"; export PATH="$T/bin:$PATH" FX="$T/fx"
fails=0
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
tr_file() { # final assistant text
  python3 -c 'import json,sys; print(json.dumps({"type":"user","message":{"content":"tidy up the README"}})); print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":sys.argv[1]}]}}))' "$1" > "$T/tr.jsonl"
}
stop() { # cwd (the other checks; the check-in has its own test)
  python3 -c 'import json,sys; print(json.dumps({"transcript_path":sys.argv[1],"cwd":sys.argv[2]}))' "$T/tr.jsonl" "$1" \
    | MERGEWORTHY_STOP_CHECKIN=off python3 "$R/hooks/stop-lint.py" 2>"$T/err"; echo $?
}
checkin() { # stop_hook_active
  python3 -c 'import json,sys; print(json.dumps({"transcript_path":sys.argv[1],"cwd":sys.argv[2],"stop_hook_active":sys.argv[3]=="1"}))' "$T/tr.jsonl" "$T" "$1" \
    | MERGEWORTHY_STOP_CHECKIN=on python3 "$R/hooks/stop-lint.py" 2>"$T/err"; echo $?
}
tr_file "Loop A is done."
check "the first stop of a turn gets the check-in" 2 "$(checkin 0)"
check "the next stop goes through" 0 "$(checkin 1)"
check "no second check-in within 30 minutes of the last" 0 "$(checkin 0)"
python3 -c 'import json; print(json.dumps({"type":"user","message":{"content":"Act as the review sub-agent for this task.\n\nCheck the diff."}})); print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"CLEAN"}]}}))' > "$T/tr.jsonl"
check "a delegated child ends with its result, no check-in" 0 "$(checkin 0)"
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
tr_cmd "gh issue comment 5 --repo o/r --body-file $WD/drafts/r.md"
check "BLOCK: a post with no Monitor on the watcher" 2 "$(stop "$T/work")"
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
  echo 2 > "$FX/repos_o_r_issues_5"
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
python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh issue comment 41 --repo o/r --body-file "+sys.argv[2]},"cwd":sys.argv[1]}))' "$T" "$TD/r.md" > "$T/in.json"
check "BLOCK: the same draft posted again as new" 2 "$(python3 "$R/hooks/pre-bash-guard.py" < "$T/in.json" 2>"$T/err"; echo $?)"
grep -c 'was already posted' "$T/err"
python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh pr edit 41 --repo o/r --body-file "+sys.argv[2]},"cwd":sys.argv[1]}))' "$T" "$TD/r.md" > "$T/in.json"
check "an edit from a posted draft may repeat" 0 "$(python3 "$R/hooks/pre-bash-guard.py" < "$T/in.json" 2>/dev/null; echo $?)"
touch -d '+1 minute' "$TD/r.parent.md"
check "BLOCK: older than the comment the draft answers" 2 "$(tcguard)"
rm "$TD/r.parent.md"
printf 'Tracking: x\n' > "$T/tdrafts/t.md"; sha256sum "$T/tdrafts/t.md" | cut -d' ' -f1 > "$T/tdrafts/t.md.gate"; echo "--kind tracker" > "$T/tdrafts/t.md.lint"
python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh issue comment 41 --repo o/r --body-file "+sys.argv[2]},"cwd":sys.argv[1]}))' "$T" "$T/tdrafts/t.md" > "$T/in.json"
check "a tracker draft needs no thread-context.md" 0 "$(python3 "$R/hooks/pre-bash-guard.py" < "$T/in.json" 2>/dev/null; echo $?)"
printf 'Tracking: x\n' > "$T/tdrafts/u.md"; sha256sum "$T/tdrafts/u.md" | cut -d' ' -f1 > "$T/tdrafts/u.md.gate"
python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh pr edit 41 --repo o/r --body-file "+sys.argv[2]},"cwd":sys.argv[1]}))' "$T" "$T/tdrafts/u.md" > "$T/in.json"
check "BLOCK: a PR body edit is covered too" 2 "$(python3 "$R/hooks/pre-bash-guard.py" < "$T/in.json" 2>/dev/null; echo $?)"

# gate-pass wants the same file beside a reply draft
GD="$T/gdrafts/x"; mkdir -p "$GD"; printf 'Agreed, option A it is.\n' > "$GD/r.md"; echo CLEAN > "$GD/r.review.out"
gp() { touch -d '+10 minutes' "$GD/r.review.out"; MERGEWORTHY_BADGE=off GATED_POSTS="$T/gp.txt" "$R/bin/gate-pass" "$GD/r.md" "$GD/r.review.out" --kind reply --parent none >"$T/gp.out" 2>&1; echo $?; }
check "BLOCK: gate-pass on a reply without thread-context.md" 1 "$(gp)"
grep -c 'no thread-context.md' "$T/gp.out"
cp "$TD/thread-context.md" "$GD/thread-context.md"
check "BLOCK: gate-pass with a thread-context.md newer than the draft" 1 "$(gp)"
touch -d '+1 minute' "$GD/r.md"
check "gate-pass passes with thread-context.md beside the draft, written before it" 0 "$(gp)"
check "gate-pass records the thread context in the gate" 1 "$(grep -c '^tc ' "$GD/r.md.gate")"
printf 'The test checks that "I'"'"'ll switch it once X is released" passes.\n' > "$GD/r.md"; touch -d '+2 minutes' "$GD/r.md"
check "a quoted \"I'll\" is someone else's words, not a promise" 0 "$(gp)"
printf "I'll open a PR for it.\n" > "$GD/r.md"; touch -d '+3 minutes' "$GD/r.md"
check "BLOCK: the draft's own \"I'll\" needs a PROMISED line" "1 1" "$(gp) $(grep -c 'promises work' "$T/gp.out")"
WP="$T/wp"; mkdir -p "$WP"; echo sess1 > "$WP/session"; echo "$WP" >> "$HOME/.claude/gh-watch-dirs.txt"; echo "PROMISED o/r#1: a PR (r.md)" > "$WP/proposals-open.md"
check "a PROMISED line in the session's watch dir counts, wherever the draft lives" 0 "$(CLAUDE_CODE_SESSION_ID=sess1 gp)"

# ---------- post-bash-register: only a real gh post registers, and only the thread it posted to ----------
sleep 600 & SPID=$!
WD="$T/reg"; mkdir -p "$WD"; echo "$SPID" > "$WD/gh-watch.pid"
echo "$WD" > "$HOME/.claude/gh-watch-dirs.txt"
U5='https://github.com/o/r/issues/5#issuecomment-1'
register() { # command stdout -> the watch dir's threads.txt, space-joined
  rm -f "$WD/threads.txt"
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"tool_response":{"stdout":sys.argv[2]}}))' "$1" "$2" \
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
check "the thread replaces that dir's bare repo line, so the watcher can retire" "|o/r" "$(cat "$D2/repos.txt")|$(cat "$D1/repos.txt")"
kill "$SPID"; wait "$SPID" 2>/dev/null

# ---------- finality trigger: the third proposal on a thread needs a thread map ----------
AR="$T/art"; mkdir -p "$AR/drafts/r1" "$AR/maps"; ctx "$AR/drafts/r1" o/r#9
rm -f "$HOME/.claude/proposal-rounds.txt"
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
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh pr create --draft --repo o/r --title \"$(cat /w/drafts/title.md)\" --body-file "+sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$T" \
    | MERGEWORTHY_WATCHER=off python3 "$R/hooks/pre-bash-guard.py" 2>"$T/err"; echo $?
}
printf '%s\nRoutes after vike(app) skip the auth +middleware. This PR runs it first.\n' "$B" > "$T/dg.md"; sha256sum "$T/dg.md" | cut -d' ' -f1 > "$T/dg.md.gate"
check "BLOCK: gh pr create --draft with a body that doesn't say why it's a draft" "2 1" "$(dguard "$T/dg.md") $(grep -c 'State: draft' "$T/err")"
printf '%s\n**State: draft** (my bug check is still running)\n\nRoutes after vike(app) skip the auth +middleware. This PR runs it first.\n' "$B" > "$T/dg.md"; sha256sum "$T/dg.md" | cut -d' ' -f1 > "$T/dg.md.gate"
check "gh pr create --draft with the State line, gated, passes" 0 "$(dguard "$T/dg.md")"
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
# ---------- pre-agent-dedupe: one agent per job ----------
launch_in() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"mcp__t3-code__delegate_task","tool_input":{"task":sys.argv[1],"title":"t"}}))' "$1"; }
launch() { # task text; a launch that passes runs, so the PostToolUse half registers it
  launch_in "$1" | python3 "$R/hooks/pre-agent-dedupe.py" 2>/dev/null; local rc=$?
  [ $rc = 0 ] && launch_in "$1" | python3 "$R/hooks/pre-agent-dedupe.py" register; echo $rc
}
check "first launch of a ticket passes" 0 "$(launch 'Execute the ticket at /tmp/x/ticket-check.md exactly')"
check "BLOCK: a second launch of the same ticket" 2 "$(launch 'Retry: execute /tmp/x/ticket-check.md')"
check "another ticket passes" 0 "$(launch 'Execute /tmp/x/other.md')"
launch_in 'Execute /tmp/x/blocked.md' | python3 "$R/hooks/pre-agent-dedupe.py" >/dev/null 2>&1
check "a launch another hook blocked (never ran) leaves no job" 0 "$(launch 'Execute /tmp/x/blocked.md')"
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
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"mcp__t3-code__delegate_task","cwd":sys.argv[1],"tool_input":{"task":sys.argv[2],"title":sys.argv[2][:50],"role":sys.argv[3]}}))' "$1" "$2" "${3:-implementation}" \
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
echo "Studied: 2026-01-01" > "$HOME/.mergeworthy/projects/o/r.study.md"
check "BLOCK: an implementer brief whose repo study is over 30 days old, or missing; research needs none" "2 1 2 0" "$(ag "$T" 'Fix o/r#5 by skills/code/SKILL.md, notes in ~/.mergeworthy/projects/o/r.md') $(grep -c 'write the repo study first' "$T/err") $(rm "$HOME/.mergeworthy/projects/o/r.study.md"; ag "$T" 'Fix o/r#5 by skills/code/SKILL.md, notes in ~/.mergeworthy/projects/o/r.md') $(ag "$T" 'Mine session logs for o/r' research)"
echo "Studied: $(date -u +%F)" > "$HOME/.mergeworthy/projects/o/r.study.md"
check "BLOCK: an implementation brief for that repo without code/SKILL.md, naming it" "2 1" "$(ag "$T" 'Build o/r#6 per ~/.mergeworthy/projects/o/r.md') $(grep -c 'skills/code/SKILL.md' "$T/err")"
check "a review brief needs no code/SKILL.md" 0 "$(ag "$T" 'Review o/r#8 per ~/.mergeworthy/projects/o/r.md' review)"
check "BLOCK: a drafter brief (it reads thread-context.md) without writing/SKILL.md; with it, it passes" "2 0" "$(ag "$T" 'Draft the reply from /w/drafts/x/thread-context.md' review) $(ag "$T" 'Write a reply draft by skills/writing/SKILL.md from /w/drafts/y/thread-context.md; list each claim with a scope word beside its source' review)"
check "BLOCK: a drafter brief without the template's scope-word check, naming the template; a review of a draft (CLEAN) needs none" "2 1 0" "$(ag "$T" 'Write a reply draft by skills/writing/SKILL.md from /w/drafts/z/thread-context.md' review) $(grep -c 'delegate/drafter.md' "$T/err") $(ag "$T" 'Review /w/drafts/z/r.md against /w/drafts/z/thread-context.md by skills/writing/SKILL.md; final message CLEAN or findings' review)"
# pre-agent-dedupe: a template's placeholder left in the brief, by the plugin's own skills/delegate templates
check "BLOCK: a brief with a template's placeholder unfilled, naming it and its template" "2 1" "$(ag "$T" $'Verify the slice.\n- try the edges: <the slice\'s risky edges>, each Recurring misses line' review) $(grep -c "<the slice's risky edges> (delegate/verifier.md)" "$T/err")"
check "a filled brief passes with the paste-in rules (their <work folder>), an output form in backticks and a quoted HTML tag" 0 "$(ag "$T" "$(printf 'Verify the slice: try the edges: the abort path.\nFinal message: the gates as `<command> -> exit <code>`; check the <head> tags.\n'; cat "$R/skills/delegate/agent.md")" review)"
check "a brief quoting a line format in backticks that holds a template's slot passes (a format, not a slot)" 0 "$(ag "$T" 'Check each `PROMISED <thread>: <what> (<draft>)` line in proposals-open.md.' review)"
# pre-agent-dedupe: a worktree another agent still works in (its process's cwd, or its fresh transcript naming it)
git -C "$T/gr" worktree add -q -b a "$T/aw"; AD="$HOME/.claude/projects/-aw"; mkdir -p "$AD" "$T/aw/src"
alive() { # task [transcript_path]
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"mcp__t3-code__delegate_task","cwd":sys.argv[1],"transcript_path":sys.argv[3],"tool_input":{"task":sys.argv[2],"title":sys.argv[2][:50]}}))' "$OC" "$1" "${2:-}" \
    | python3 "$R/hooks/pre-agent-dedupe.py" 2>"$T/err"; echo $?; }
(cd "$T/aw/src" && exec sleep 600) & APID=$!; sleep 0.2
check "BLOCK: a process works in the worktree, naming its PID" "2 1" "$(alive "Run e2e in $T/aw/src") $(grep -c "$APID (sleep)" "$T/err")"
kill $APID; wait $APID 2>/dev/null
echo "{\"cwd\":\"$T/aw\"}" > "$AD/agent.jsonl"
check "BLOCK: an agent transcript written minutes ago names the worktree" "2 1" "$(alive "Run e2e in $T/aw") $(grep -c "$AD/agent.jsonl" "$T/err")"
echo "Prototype report: worktree $T/aw, branch a." > "$T/aw-report.md"; printf 'Goal: e2e green.\nWork in %s.\n' "$T/aw" | tee "$T/aw-job.md" > "$T/aw-brief.md"
check "a reference file the brief names whose text names the busy worktree passes; the brief file it says to follow, or named as a brief, blocks" "0 2 2" "$(alive "Summarize the prototype. Context: $T/aw-report.md (read first)") $(alive "Follow $T/aw-job.md exactly") $(alive "Topic: e2e. Its file: $T/aw-brief.md")"
check "the orchestrator's own transcript naming the worktree doesn't count" 0 "$(alive "Run e2e in $T/aw once more" "$AD/agent.jsonl")"
echo "{\"cwd\":\"$T/aw-r\"}" > "$AD/sibling.jsonl"; touch -d '10 minutes ago' "$AD/agent.jsonl"
check "a transcript naming a longer sibling path ($T/aw-r) doesn't make the worktree busy" 0 "$(alive "Run e2e in $T/aw yet again")"
rm -f "$AD/sibling.jsonl"; touch "$AD/agent.jsonl"
touch -d '10 minutes ago' "$AD/agent.jsonl"
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
def res(name, st, title=''):
    n[0] += 1; i = f'tu{n[0]}'
    w({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": i, "name": f"mcp__t3-code__{name}", "input": {"title": title, "taskId": "x"}}]}})
    w({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": i, "content": json.dumps({"taskId": "node:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Aloop-a-1", "status": st})}]}})
w({"type": "user", "message": {"content": "run loop A"}}); res('delegate_task', 'running', 'Loop A')
for e in ev:
    if e == 'user': w({"type": "user", "message": {"content": "status?"}})
    else: res('task_status', e.split(':')[1])
w({"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}})
EOF
}
rl_tr $'Done for now.\n\nRunning:\n- Loop A on the head' user; check "BLOCK: a Running list not read from T3 since the user's last message" 2 "$(stop "$T")"
rl_tr $'Done for now.\n\nRunning:\n- Loop A on the head' user status:completed; check "BLOCK: a Running list naming a completed task" 2 "$(stop "$T")"
rl_tr $'Done for now.\n\n**Running:**\n- loop-a-1, the bug hunt' user status:failed; check "BLOCK: matched by its request id too" 2 "$(stop "$T")"
rl_tr $'Done for now.\n\nRunning:\n- Loop A on the head' user status:running; check "a Running list read live, its task still running, passes" 0 "$(stop "$T")"
rl_tr 'Running the tests found nothing.' user; check "a sentence starting with Running is no Running list" 0 "$(stop "$T")"
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
check "BLOCK: a fix log recorded as the shape pass, saying what a pass needs" "1 1" "$(prs shape "$T/fixlog.md") $(cd "$G" && bash "$R/bin/pr-steps" shape "$T/fixlog.md" 2>&1 | grep -c "needs the ✅ coverage list")"
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
printf 'NO BUGS\n' > "$T/vA.md"; std "$T/vA.md"; G_A=$A; (cd "$G" && git checkout -q "$G_A" && bash "$R/bin/pr-steps" verify "$T/vA.md" >/dev/null 2>&1; git checkout -q -); 
cp "$T/carry.md" "$T/carry-v.md"
check "a small follow-up carries an earlier head's Loop A" 0 "$(prs verify "$T/carry-v.md")"
cp "$T/carry.md" "$T/carry-f.md"
check "BLOCK: carrying a step the earlier head never recorded" 1 "$(prs fresh "$T/carry-f.md")"
seq 1 100 > "$G/big"; git -C "$G" add big; git -C "$G" -c user.name=t -c user.email=t@t commit -q -m c
printf 'carries the pass of %s: big change\n' "$A" > "$T/carry2.md"
check "BLOCK: carrying across more than 80 changed lines" 1 "$(prs shape "$T/carry2.md")"
# a branch whose latest approach record has no `contract: 2` was started by a session on v1's skills: it finishes under the old records
mkdir -p "$HOME/.mergeworthy/sessions"; echo "/p graph startup 0" > "$HOME/.mergeworthy/sessions/s-graph"; echo "/p v1 startup 0" > "$HOME/.mergeworthy/sessions/s-v1"
printf '| Candidate | Rating | Why |\n|---|---|---|\n| Not building it | 3 | stays |\n| Fix it | 8 | ok |\n\nChosen: Fix it\n' > "$T/apo.md"; CLAUDE_CODE_SESSION_ID=s-graph prs approach "$T/apo.md" >/dev/null
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
# ---------- pr-steps: every converge step leaves its proof; the guard needs all five ----------
G2="$T/prs2"; mkdir -p "$G2"; git -C "$G2" init -q; git -C "$G2" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a
prs2() { (cd "$G2" && bash "$R/bin/pr-steps" "$@" >/dev/null 2>&1; echo $?); }
ready() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh pr ready 5"},"cwd":sys.argv[1]}))' "$G2" | python3 "$R/hooks/pre-bash-guard.py" >/dev/null 2>&1; echo $?; }
check "BLOCK: gh pr ready with no step recorded" 2 "$(ready)"
printf 'slice 1: no bug that counts\n' > "$T/v0.md"
check "BLOCK: a Loop A output without NO BUGS" 1 "$(prs2 verify "$T/v0.md")"
printf 'slice 1: no bug that counts\nNO BUGS\n' > "$T/v.md"; cp "$T/v.md" "$T/v-nostd.md"; std "$T/v.md"; check "BLOCK: a Loop A file without '## Standards read', naming the missing sentence" "1 1" "$(prs2 verify "$T/v-nostd.md") $(cd "$G2" && bash "$R/bin/pr-steps" verify "$T/v-nostd.md" 2>&1 | grep -c '^Every fix passes it.$')"; check "Loop A ending NO BUGS records" 0 "$(prs2 verify "$T/v.md")"
printf '| vike() | 5 ⇒ 8 | abc | why |\n✅ vike()\nnothing worth changing\nCLEAN\n' > "$T/rf.md"; std "$T/rf.md"; check "Loop B's shape report records" 0 "$(prs2 shape "$T/rf.md")"
printf 'NO LOOP B COMMITS\n' > "$T/rv.md"; check "Loop A again, with no Loop B commits, records" 0 "$(prs2 reverify "$T/rv.md")"
printf 'Maintainer: hi-ogawa\nCLEAN\n' > "$T/fr0.md"; std "$T/fr0.md"; check "BLOCK: a fresh read without MERGE AS IS: yes" 1 "$(prs2 fresh "$T/fr0.md")"
printf 'MERGE AS IS: yes\nCLEAN\n' > "$T/fr1.md"; std "$T/fr1.md"; check "BLOCK: a fresh read that names no maintainer" 1 "$(prs2 fresh "$T/fr1.md")"
printf 'Maintainer: hi-ogawa\nMERGE AS IS: yes\nCLEAN\n' > "$T/fr.md"; std "$T/fr.md"; check "the fresh reader's maintainer, merge-as-is and CLEAN record" 0 "$(prs2 fresh "$T/fr.md")"
printf 'pnpm test -> exit 0\npnpm lint -> exit 1\n' > "$T/g1.md"
check "BLOCK: a gates log with a red gate" 1 "$(prs2 gates "$T/g1.md")"
check "BLOCK: gh pr ready with four of five steps" 2 "$(ready)"
printf 'pnpm test -> exit 0\npnpm lint -> exit 0\n' > "$T/g0.md"; printf 'pnpm test -> exit 0 (0 tests)\n' > "$T/g00.md"
check "BLOCK: a test gate without its count, or with 0 tests" "1 1" "$(prs2 gates "$T/g0.md") $(prs2 gates "$T/g00.md")"
printf 'pnpm test -> exit 0 (134 tests)\npnpm lint -> exit 0\n' > "$T/g2.md"; check "a green gates log records" 0 "$(prs2 gates "$T/g2.md")"
check "BLOCK: gh pr ready with the five steps but no approach record" 2 "$(ready)"
printf '| Candidate | Rating | Why |\n|---|---|---|\n| Not building it | 3 | the bug stays |\n| Fix in place | 5 | misses siblings |\n| Fix the shared helper | 8 | one place for all |\n\nChosen: Fix the shared helper\n' > "$T/ap.md"
printf '| Candidate | Rating | Why |\n|---|---|---|\n| Fix the shared helper | 8 | only one |\n\nChosen: Fix the shared helper\n' > "$T/ap1.md"
printf '| Candidate | Rating | Why |\n|---|---|---|\n| Not building it | 3 | the bug stays |\n| Fix in place | 6 | misses siblings |\n\nChosen: Fix in place\n' > "$T/ap6.md"
printf '| Candidate | Rating | Why |\n|---|---|---|\n| Not building it | 3 | the bug stays |\n| Fix in place | 8 | ok |\n\nChosen: Rewrite\n' > "$T/apx.md"
check "BLOCK: an approach with one candidate" 1 "$(prs2 approach "$T/ap1.md")"
check "BLOCK: a chosen approach rated 6" 1 "$(prs2 approach "$T/ap6.md")"
check "BLOCK: a chosen approach that is no candidate" 1 "$(prs2 approach "$T/apx.md")"
check "BLOCK: gh pr ready after refused approach records" 2 "$(ready)"
check "an approach with three rated candidates and a chosen 8 records, with no Browser line" 0 "$(prs2 approach "$T/ap.md")"
glab() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$T" | python3 "$R/hooks/pre-bash-guard.py" >/dev/null 2>&1; echo $?; }
mkdir -p "$HOME/.config/pnpm"; echo '//registry.npmjs.org/:_authToken=x' > "$HOME/.npmrc"; cp "$HOME/.npmrc" "$HOME/.config/pnpm/config.yaml"
check "BLOCK: printing a credential file; counting a line in it, or a file that isn't one, passes" "2 2 2 0 0" "$(glab "cat $HOME/.npmrc") $(glab 'cat ~/.config/pnpm/config.yaml') $(glab "grep token $HOME/.npmrc") $(glab "grep -c registry $HOME/.npmrc") $(glab "cat $T/tr.jsonl")"
# pre-bash-guard: a PR title is drafted in a file, never typed inline
guard() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2],"agent_id":sys.argv[3]}))' "$1" "$T" "${2:-}" | python3 "$R/hooks/pre-bash-guard.py" 2>"$T/err"; echo $?; }
check "BLOCK: a PR title typed inline (create, edit, -t), naming the title file; a title from its file passes" "2 1 2 2 0 0" "$(guard "gh pr create --draft --title 'Fix the thing' --body-file $T/b.md") $(grep -c 'drafts/title.md.*last 10 merged titles.*pull-request step 7' "$T/err") $(guard "gh pr edit 5 --title 'Fix it'") $(guard 'gh pr edit 5 -t Fix') $(guard 'gh pr edit 5 --title "$(cat /w/drafts/title.md)"') $(guard 'gh pr create --draft --title "$(cat /w/drafts/title.md)" --body-file /w/b.md' >/dev/null; grep -c 'typed inline' "$T/err")"
printf '[{"event":"renamed","actor":{"login":"brillout"},"created_at":"2026-10-14T21:50:52Z","rename":{"from":"a","to":"b"}}]' > "$FX/repos_o_r_issues_7_timeline_per_page_100"
printf '[{"event":"renamed","actor":{"login":"brillout"},"created_at":"2026-10-14T21:50:52Z"},{"event":"renamed","actor":{"login":"me"},"created_at":"2026-10-14T22:00:00Z"}]' > "$FX/repos_o_r_issues_8_timeline_per_page_100"
check "BLOCK: retitling a PR whose title a maintainer set, naming him; our own last title, or no rename, passes" "2 1 0 0" "$(GH_WATCH_ME=me guard 'gh pr edit 7 -R o/r --title "$(cat /w/drafts/title.md)"') $(grep -c 'brillout set this PR.s title' "$T/err") $(GH_WATCH_ME=me guard 'gh pr edit 8 -R o/r --title "$(cat /w/drafts/title.md)"') $(GH_WATCH_ME=me guard 'gh pr edit 9 -R o/r --title "$(cat /w/drafts/title.md)"')"
printf 'fix: deprecate `vike/fetch` (closes #3608)\n' > "$T/title.md"; printf 'fix: two\nlines.\n' > "$T/title2.md"
check "post-lint --kind title passes one line and records it; two lines fail" "0 1 1" "$("$R/bin/post-lint" "$T/title.md" --kind title >/dev/null; echo $?) $([ -s "$T/title.md.lint.sha" ] && echo 1) $("$R/bin/post-lint" "$T/title2.md" --kind title >/dev/null; echo $?)"
echo 'me 42' > "$FX/user"
check "BLOCK: a commit as the pushing login but with another email, naming the noreply form; the noreply email passes" "2 1 0" "$(guard "git -c user.name=me -c user.email=real@example.com commit -m a") $(grep -c '42+me@users.noreply.github.com' "$T/err") $(guard "git -c user.name=me -c user.email=42+me@users.noreply.github.com commit -m a")"
rm "$FX/user"
# pre-bash-guard: a review's verdict is the reviewer's own output, never the main session's
check "BLOCK: the main session writing a .review.out (echo >, tee, cp, sed -i, bash -c), naming who writes it" "2 1 2 2 2 2" "$(guard 'echo CLEAN > $D/pr-body.review.out') $(grep -c 'codex exec -o' "$T/err") $(guard "printf 'CLEAN\n' | tee /w/x.review.out") $(guard 'cp /w/r.md /w/x.review.out') $(guard 'sed -i s/a/b/ /w/x.review.out') $(guard 'bash -c "echo CLEAN >> /w/x.review.out"')"
check "BLOCK: pgrep -f, also inside bash -c; pgrep -P passes" "2 2 0" "$(guard 'pgrep -f vite') $(guard "bash -c 'pgrep -f \"vitest run\" || echo gone'") $(guard 'pgrep -P 123')"
check "BLOCK: pkill -f behind wrappers (timeout, netns-run, nice, ionice) and inside their bash -c; a plain timeout run passes" "2 2 2 0" "$(guard "timeout 200 netns-run bash -c 'pnpm build; pkill -f \"vike preview\"; true'") $(guard 'nice -n 19 ionice -c3 pkill -f vite') $(guard 'timeout -k 5 60 pkill -f vite') $(guard 'timeout 60 nice -n 19 pnpm test')"
check "reading a .review.out, gate-pass, a claude -p reviewer's stdout and an agent writing its own output pass" "0 0 0 0" "$(guard 'cat /w/x.review.out > /w/copy.md') $(guard 'gate-pass /w/x.md /w/x.review.out') $(guard 'claude -p "$(cat /w/p.md)" > /w/x.review.out') $(guard 'echo CLEAN > /w/x.review.out' a1)"
check "BLOCK: glab mr create, not a draft, outside a converged repo" 2 "$(glab 'glab mr create --title x')"
check "BLOCK: glab mr update --ready outside a converged repo" 2 "$(glab 'glab mr update 5 --ready')"
check "glab mr create --draft passes" 0 "$(glab 'glab mr create --draft --title x')"
check "glab mr create --wip passes" 0 "$(glab 'glab mr create --wip --title x')"
check "gh pr ready passes once all five steps and the approach hold" 0 "$(ready)"
check "glab mr update --ready passes there too" 0 "$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"glab mr update 5 --ready"},"cwd":sys.argv[1]}))' "$G2" | python3 "$R/hooks/pre-bash-guard.py" >/dev/null 2>&1; echo $?)"
printf 'm\n' > "$G2/m"; git -C "$G2" add m; git -c user.name=maint -c user.email=m@m -C "$G2" commit -q -m "a maintainer's tweak"
check "a maintainer's commit on a converged head carries its steps" 0 "$(ready)"
seq 1 81 > "$G2/m2"; git -C "$G2" add m2; git -c user.name=maint -c user.email=m@m -C "$G2" commit -q -m "a maintainer's rewrite"
check "a big maintainer commit carries them too: the pipeline waits for their go" 0 "$(ready)"
git -C "$G2" reset -q --hard HEAD~1
printf 'y\n' > "$G2/g"; git -C "$G2" add g; git -c user.name=t -c user.email=t@t -C "$G2" commit -q -m c -m 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'
check "BLOCK: a new HEAD has no steps, but the approach is not what it lacks" 2 "$(ready)"
check "the approach block message does not name approach on the new HEAD" 0 "$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh pr ready 5"},"cwd":sys.argv[1]}))' "$G2" | python3 "$R/hooks/pre-bash-guard.py" 2>&1 | grep -c 'pr-steps approach')"
H=$(git -C "$G2" rev-parse HEAD); for k in verify loopb refactor reverify fresh gates; do echo "$k /x/$k.md 2026-10-13T00:00:00Z" >> "$HOME/.claude/pr-steps/$H"; done
check "a head recorded before the shape pass (loopb and refactor) counts as shaped" 0 "$(ready)"
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
check "the block names exactly post, pull-request and writing" "mergeworthy:post mergeworthy:pull-request mergeworthy:writing" "$(grep -o '^- mergeworthy:[a-z-]*' "$T/sg.err" | cut -c3- | sort | xargs)"
check "the block gives the reason from the always-on row" 1 "$(grep -c '^- mergeworthy:writing, for gh pr create: Before writing any words a person reads' "$T/sg.err")"
sg_tr "$T/sg.jsonl" skill:mergeworthy:pull-request text skill:writing skill:post
check "gh pr create passes once its skills were opened (plugin-qualified or bare)" 0 "$(sgb "gh pr create --draft --body-file $T/b.md")"
sg_tr "$T/sg.jsonl" skill:mergeworthy:pull-request skill:mergeworthy:writing skill:mergeworthy:post compact text
check "BLOCK: skills opened before the last compaction don't count" 2 "$(sgb "gh pr create --draft --body-file $T/b.md")"
check "the compact summary's text doesn't open merging either" 2 "$(sgb 'git push')"
sg_tr "$T/sg.jsonl" skill:mergeworthy:writing compact skill:mergeworthy:pull-request skill:mergeworthy:writing skill:mergeworthy:post
check "opened again after the compaction: passes" 0 "$(sgb "gh pr create --draft --body-file $T/b.md")"
check "BLOCK: gh pr ready also needs merging" 2 "$(sgb 'gh pr ready 5')"
check "the ready block names only merging" "mergeworthy:merging" "$(grep -o '^- mergeworthy:[a-z-]*' "$T/sg.err" | cut -c3- | xargs)"
check "gh pr ready --undo, back to draft, never waits" 0 "$(sgb 'gh pr ready 5 --undo')"
check "BLOCK: git push without merging" 2 "$(sgb 'cd /x && git -C /x push origin HEAD')"
check "BLOCK: gh pr merge without merging" 2 "$(sgb 'gh pr merge 5 --squash')"
sg_tr "$T/sg.jsonl" typed:mergeworthy:merging
check "a skill the user typed as /mergeworthy:merging counts" 0 "$(sgb 'git push')"
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
check "the issue block names open-issue, post and writing" "mergeworthy:open-issue mergeworthy:post mergeworthy:writing" "$(grep -o '^- mergeworthy:[a-z-]*' "$T/sg.err" | cut -c3- | sort | xargs)"
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
mkdir -p "$T/s1/subagents"; sg_tr "$T/s1/subagents/agent-a1.jsonl" skill:mergeworthy:merging
check "a subagent's own Skill calls count for it" 0 "$(sg_in Bash '{"command":"git push"}' "$T/sg.jsonl" a1 | python3 "$R/hooks/pre-skill-gate.py" 2>/dev/null; echo $?)"
sg_tr "$T/s1/subagents/agent-a1.jsonl" text; sg_tr "$T/sg.jsonl" skill:mergeworthy:merging
check "BLOCK: the parent's skills aren't in a subagent's context" 2 "$(sg_in Bash '{"command":"git push"}' "$T/sg.jsonl" a1 | python3 "$R/hooks/pre-skill-gate.py" 2>/dev/null; echo $?)"
check "no transcript to read: nothing to check" 0 "$(sg Bash '{"command":"git push"}' "$T/none.jsonl")"
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
check "no transcript: nothing to check, whatever the record" 0 "$(sg_in Bash '{"command":"gh-watch-start /w o/r"}' "$T/none.jsonl" | python3 "$R/hooks/pre-skill-gate.py" 2>/dev/null; echo $?)"
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
printf '#!/bin/sh\ncase " $* " in *" config "*) [ -f "$DC_FX" ] && cat "$DC_FX";; esac\n' > "$T/bin/docker"; chmod +x "$T/bin/docker"
echo '{"services":{"db":{"ports":[{"target":5432,"published":"5432"}]}}}' > "$T/fixed.json"
echo '{"services":{"web":{"container_name":"web","ports":[{"target":80}]}}}' > "$T/named.json"
echo '{"services":{"web":{"ports":[{"target":80}]}}}' > "$T/assigned.json"
dc_guard() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$T" | python3 "$R/hooks/pre-bash-guard.py" 2>/dev/null; echo $?; }
check "BLOCK: compose up publishing a fixed host port" 2 "$(dc_guard "DC_FX=$T/fixed.json docker compose -p x up -d")"
check "BLOCK: compose up with a container_name" 2 "$(dc_guard "DC_FX=$T/named.json docker compose -p x up -d")"
check "compose up with Docker-assigned ports passes" 0 "$(dc_guard "DC_FX=$T/assigned.json docker compose -p x up -d")"
check "compose up on the usual ports when the user asked passes" 0 "$(dc_guard "MERGEWORTHY_HOST_PORTS=user-asked DC_FX=$T/fixed.json docker compose -p x up -d")"
check "compose up whose config fails passes" 0 "$(dc_guard "DC_FX=$T/missing.json docker compose -p x up -d")"
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
check "no steward declared: a push in a mergeworthy checkout passes" 0 "$(sg "git -C $T/mwc push origin HEAD:main" other-session "$T")"
echo "$SW steward-thread" > "$HOME/.mergeworthy/steward"
check "BLOCK: another session's commit or push in a mergeworthy checkout, naming the steward's inbox" "2 1 2" "$(sg "git -C $T/mwc push origin HEAD:main" other-session "$T") $(grep -c "$SW/inbox.md" "$T/err") $(sg "git commit -m x" other-session "$T/mwc")"
check "the steward's delegated agent (its T3 parent thread) and a session in its watch dir push; another repo passes" "0 0 0" "$(sg "git -C $T/mwc push origin HEAD:main" child-session "$T") $(sg "git -C $T/mwc push origin HEAD:main" x "$SW") $(sg "git -C $T/gr push origin HEAD:main" other-session "$T")"
python3 - "$HOME/.t3/userdata/statev2.sqlite" <<'EOF2'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("""insert into orchestration_v2_projection_provider_threads values ('p3', 'thread:spaced', '{"nativeThreadRef": {"nativeId": "spaced-session"}}')""")
c.execute("insert into orchestration_v2_projection_subagents values ('s2', 'steward-thread', 'thread:spaced')"); c.commit()
EOF2
echo steward-session > "$SW/session"
check "the steward's agent is found in JSON written with spaces" 0 "$(sg "git -C $T/mwc push origin HEAD:main" spaced-session "$T")"
mv "$HOME/.t3/userdata/statev2.sqlite" "$T/state.bak"
check "without T3's database, the session its watch dir's session file names is the steward; another isn't" "0 2" "$(sg "git -C $T/mwc push origin HEAD:main" steward-session "$T") $(sg "git -C $T/mwc push origin HEAD:main" other-session "$T")"
mv "$T/state.bak" "$HOME/.t3/userdata/statev2.sqlite"
printf '### FOLLOW-UP o/r#5: abcdef1234 by carol changes lines from your PR  <c>  at %s\n' "$(date -u -d '-40 minutes' +%FT%TZ)" > "$SW/events.log"; : > "$WD/events.log"; echo "$WD" > "$HOME/.claude/gh-watch-dirs.txt"
tr_file "Done."
check "with a steward, its unsorted FOLLOW-UP blocks it, not an orchestrator" "0 2" "$(stop "$WD") $(stop "$SW")"
cp "$SW/events.log" "$WD/events.log"
check "a FOLLOW-UP that fell back to the orchestrator's dir (no steward watcher ran) blocks the orchestrator" 2 "$(stop "$WD")"
echo 'abcdef1234 WORKED https://github.com/o/r/pull/5#issuecomment-1' > "$SW/followups-sorted.txt"
check "a WORKED verdict sorts it" 0 "$(stop "$SW")"
rm -f "$HOME/.mergeworthy/steward" "$WD/events.log" "$SW/followups-sorted.txt"
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
echo '{"hooks": 1}' > "$PO/hooks/hooks.json"; echo '{"hooks": 2}' > "$PN/hooks/hooks.json"; touch -d '1 hour ago' "$PO"; tr_file "Done."
rs() { python3 -c 'import json,sys; print(json.dumps({"transcript_path":sys.argv[1],"cwd":sys.argv[2],"session_id":sys.argv[3]}))' "$T/tr.jsonl" "$T" "$1" \
    | CLAUDE_PLUGIN_ROOT="$PO" MERGEWORTHY_STOP_CHECKIN=off python3 "$R/hooks/stop-lint.py" 2>"$T/err"; echo $?; }
check "BLOCK once per session: a newer version changed hooks.json, so a restart loads it; the same hook list says nothing" "2 1 0 0" "$(rs rs-1) $(grep -c 'restart of this session' "$T/err") $(rs rs-1) $(cp "$PN/hooks/hooks.json" "$PO/hooks/"; rs rs-2)"
mkdir -p "$PO/skills/task" "$PN/skills/task"; echo old > "$PO/skills/task/SKILL.md"; echo new > "$PN/skills/task/SKILL.md"
check "BLOCK once per session: a newer version changed the skills, naming where the installed text is; the same skills say nothing" "2 1 0 0" "$(rs rs-3) $(grep -c 'read and follow ~/.mergeworthy/current/skills/<name>/SKILL.md' "$T/err") $(rs rs-3) $(cp "$PN/skills/task/SKILL.md" "$PO/skills/task/"; rs rs-4)"
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
echo "$GPID" > "$GW/gh-watch.pid"; echo "$GW" > "$HOME/.claude/gh-watch-dirs.txt"
glguard() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "${2:-$T}" | python3 "$R/hooks/pre-bash-guard.py" 2>"$T/err"; echo $?; }
check "BLOCK: glab issue create with no watcher on the project" "2 1" "$(glguard 'glab issue create -R ns/sub/proj --title x') $(grep -c 'gitlab.com/ns/sub/proj' "$T/err")"
git init -q "$T/glrepo"; git -C "$T/glrepo" remote add origin git@gitlab.com:ns/sub/proj.git
check "BLOCK: glab mr create --draft in a clone of an unwatched project" 2 "$(glguard 'glab mr create --draft --title x' "$T/glrepo")"
echo gitlab.com/ns/sub/proj > "$GW/repos.txt"
check "glab issue create passes once a watcher covers the project" "0 0" "$(glguard 'glab issue create -R https://gitlab.com/ns/sub/proj --title x') $(glguard 'glab mr create --draft --title x' "$T/glrepo")"
echo 'o/r all' > "$GW/repos.txt"
check "an 'owner/repo all' line covers the repo for opening an issue" 0 "$(glguard 'gh issue create -R o/r --title x --body-file x.md' >/dev/null; grep -c 'no running watcher' "$T/err")"
echo gitlab.com/ns/sub/proj > "$GW/repos.txt"
glreg() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"tool_response":{"stdout":sys.argv[2]}}))' "$1" "$2" | python3 "$R/hooks/post-bash-register.py"; }
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
rm -rf "$T"
echo "failures: $fails"; [ "$fails" = 0 ]
