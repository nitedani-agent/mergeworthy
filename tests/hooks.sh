#!/usr/bin/env bash
# Tests for the hooks: stop-lint, pre-bash-guard's check_turn, post-bash-register. Usage: tests/hooks.sh <repo root>
# Runs every case under a temp HOME with a stub `gh` first on PATH; prints "case: <got> (want <want>)".
# Exits 0 only when every case gives what it wants. Stub URLs are example.invalid on purpose, except where
# post-bash-register must see github.com URLs (those go only into the hook's stdin, never to this script's output).
set -u
R=$(readlink -f "$1")
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
ss_first=$(CLAUDE_PLUGIN_ROOT="$R" bash "$R/hooks/session-start" 2>/dev/null | head -1)
check "session-start opens as the user's instructions, like CLAUDE.md" yes "$(printf '%s' "$ss_first" | grep -q '^IMPORTANT: These are the user.s instructions.*OVERRIDE any default behavior' && echo yes || echo no)"
check "session-start still carries the always-on rules" yes "$(CLAUDE_PLUGIN_ROOT="$R" bash "$R/hooks/session-start" 2>/dev/null | grep -q '^## Always-on rules (mergeworthy)' && echo yes || echo no)"

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
gp() { MERGEWORTHY_BADGE=off GATED_POSTS="$T/gp.txt" "$R/bin/gate-pass" "$GD/r.md" "$GD/r.review.out" --kind reply --parent none >"$T/gp.out" 2>&1; echo $?; }
check "BLOCK: gate-pass on a reply without thread-context.md" 1 "$(gp)"
grep -c 'no thread-context.md' "$T/gp.out"
cp "$TD/thread-context.md" "$GD/thread-context.md"
check "BLOCK: gate-pass with a thread-context.md newer than the draft" 1 "$(gp)"
touch -d '+1 minute' "$GD/r.md"
check "gate-pass passes with thread-context.md beside the draft, written before it" 0 "$(gp)"
check "gate-pass records the thread context in the gate" 1 "$(grep -c '^tc ' "$GD/r.md.gate")"

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
# ---------- post-lint + gate-pass: a reply shows the mergeworthy commits the repo's maintainers asked to see ----------
S="$T/mwsrc"; git init -q "$S"; for m in one two three; do git -C "$S" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$m"; done
mkdir -p "$HOME/.mergeworthy/harness-shown"; git -C "$S" rev-parse --short=7 HEAD~2 > "$HOME/.mergeworthy/harness-shown/acme"
h2=$(git -C "$S" rev-parse --short=7 HEAD~1); h3=$(git -C "$S" rev-parse --short=7 HEAD)
hl() { printf '%s\n' "$1" > "$T/hs.md"; MERGEWORTHY_SRC="$S" python3 "$R/bin/post-lint" "$T/hs.md" --kind reply --repo "$2" --parent none 2>&1 | grep -c 'asked to see'; }
check "BLOCK: a reply in acme/x that leaves out unseen mergeworthy commits" 1 "$(hl 'Fixed the bug.' acme/x)"
check "a reply that shows both unseen commits passes" 0 "$(hl "Fixed. Mergeworthy: $h2 and $h3." acme/x)"
check "another owner's repo asked for nothing" 0 "$(hl 'Fixed the bug.' other/x)"
git clone -q --depth 1 "file://$S" "$T/mwshallow"
check "a shallow clone fetches the history it needs" 1 "$(printf 'Fixed the bug.\n' > "$T/hs.md"; MERGEWORTHY_SRC="$T/mwshallow" python3 "$R/bin/post-lint" "$T/hs.md" --kind reply --repo acme/x --parent none 2>&1 | grep -c 'asked to see')"
printf 'Fixed. Mergeworthy: %s and %s.\n' "$h2" "$h3" > "$T/hs.md"; printf 'CLEAN\n' > "$T/hs.review"
MERGEWORTHY_SRC="$S" bash "$R/bin/gate-pass" "$T/hs.md" "$T/hs.review" --kind tracker --repo acme/x >/dev/null 2>&1 || true
check "gate-pass of a tracker post doesn't mark them shown" "$(git -C "$S" rev-parse --short=7 HEAD~2)" "$(cat "$HOME/.mergeworthy/harness-shown/acme")"

check "a badge followed on its line by an italic model line passes, model names included" 0 "$(printf '%s\n\nFixed the bug.\n' '<img src="https://github.com/claude.png" width="20" height="20" alt="Claude"><img src="https://github.com/openai.png" width="20" height="20" alt="Codex"> *Opus 5.5 (medium effort) wrote this; a second Opus 5.5 (high effort) reviewed it; GPT-6.1-Sol (Codex, high effort) reviewed it.*' > "$T/ml.md"; MERGEWORTHY_BADGE=on python3 "$R/bin/post-lint" "$T/ml.md" --kind reply --parent none >/dev/null 2>&1; echo $?)"
# ---------- post-lint: a limitation names what imposes it (core 1.1.11) ----------
llint() { printf '| Note | Kind | Blocks merge | Next |\n|---|---|---|---|\n| %s | limitation | no | nothing |\n' "$1" > "$T/lim.md"; python3 "$R/bin/post-lint" "$T/lim.md" --kind pr --parent none 2>&1 | grep -c 'names nothing that imposes it'; }
check "a limitation our own design could create is flagged" 1 "$(llint 'Joins past 100 at once fail with a contention error')"
check "a limitation imposed by an outside system passes" 0 "$(llint 'Receipts omit receivers, imposed by Redis Cluster: PUBLISH counts one node')"
# ---------- post-lint: each list item is its own sentence ----------
B=$'<img src="https://github.com/claude.png" width="20" height="20" alt="Claude">\n'
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
mkdir -p "$T/cx"; printf '%s Fixed in abc1234.\n' "$B" > "$T/cx/reply.md"; printf 'model: gpt-x\nCLEAN\n' > "$T/cx/review.log"
check "a post Codex reviewed needs the Codex icon" 1 "$(python3 "$R/bin/post-lint" "$T/cx/reply.md" --parent none 2>&1 | grep -c 'badge without Codex')"
printf '<img src="https://github.com/claude.png" width="20" height="20" alt="Claude"><img src="https://github.com/openai.png" width="20" height="20" alt="Codex">\n\nFixed in abc1234.\n' > "$T/cx/reply.md"
check "with the Codex icon it passes" 0 "$(python3 "$R/bin/post-lint" "$T/cx/reply.md" --parent none 2>&1 | grep -c 'badge without Codex')"
printf 'Refactor this PR. Print the lists again with old rating => new rating.\n' > "$T/rp.parent.md"
printf '%s Done, the lists are below.\n\n<details>\n<summary>Lists</summary>\n\nS1 and S2 were rated in the refactor pass. %s\n</details>\n' "$B" "$(printf 'word %.0s' $(seq 400))" > "$T/rp.md"
check "lists a maintainer asked for, in <details>, are not linted or counted" 0 "$(python3 "$R/bin/post-lint" "$T/rp.md" --kind pr --parent "$T/rp.parent.md" 2>&1 | grep -c 'internal label\|words >\|process in the thread')"
check "the same lists nobody asked for are" 4 "$(python3 "$R/bin/post-lint" "$T/rp.md" --kind pr --parent none 2>&1 | grep -c 'internal label\|words >\|process in the thread')"
printf 'The code came from Sonnet subagents, and Codex (gpt-6.1-sol) reviewed every post.\n' > "$T/pm.md"
printf 'What AI model did you use? Explain the agent orchestration.\n' > "$T/pm.parent.md"
check "a maintainer who asks about models and agents gets them named" 0 "$(python3 "$R/bin/post-lint" "$T/pm.md" --kind reply --parent "$T/pm.parent.md" 2>&1 | grep -c 'process in the thread')"
printf 'Can you fix the typo?\n' > "$T/pm2.parent.md"
check "the same reply to an unrelated comment is flagged" 3 "$(python3 "$R/bin/post-lint" "$T/pm.md" --kind reply --parent "$T/pm2.parent.md" 2>&1 | grep -c 'process in the thread')"
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
printf '%s Draft until the release ships.\n\nThe fix.\n' "$B" > "$T/st.md"
check "a PR body that opens with its status is flagged" 1 "$(python3 "$R/bin/post-lint" "$T/st.md" --kind pr --parent none 2>&1 | grep -c 'opens with its status')"
printf '%s Routes after vike(app) skip the auth +middleware. This PR runs it first.\n\nDraft until the release ships.\n' "$B" > "$T/st2.md"
check "status after the opening is fine" 0 "$(python3 "$R/bin/post-lint" "$T/st2.md" --kind pr --parent none 2>&1 | grep -c 'opens with its status')"
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
# ---------- pr-steps: a refactor record is a real pass ----------
G="$T/prs"; mkdir -p "$G"; git -C "$G" init -q; git -C "$G" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a
prs() { (cd "$G" && bash "$R/bin/pr-steps" "$@" >/dev/null 2>&1; echo $?); }
printf '# Loop B fix log\nfixed the README\n' > "$T/fixlog.md"
check "BLOCK: a fix log recorded as the refactor pass" 1 "$(prs refactor "$T/fixlog.md")"
printf '| express vike() | 5 ⇒ 8 | abc | named steps |\n✅ express vike()\n' > "$T/pass.md"
printf '| express vike() | 5 ⇒ 8 | abc | named steps |\n| render() | 10 = | Unchanged since ratings17. |\n✅ express vike()\n' > "$T/copied.md"
check "BLOCK: a re-rating that copies earlier ratings is not a pass" 1 "$(prs refactor "$T/copied.md")"
check "a pass with ratings and the ✅ list records" 0 "$(prs refactor "$T/pass.md")"
A=$(git -C "$G" rev-parse HEAD); printf 'x\n' > "$G/f"; git -C "$G" add f; git -C "$G" -c user.name=t -c user.email=t@t commit -q -m b
printf 'carries the pass of %s: one docs line\n' "$A" > "$T/carry.md"
check "a small follow-up carries the earlier pass" 0 "$(prs refactor "$T/carry.md")"
printf 'NO BUGS\n' > "$T/vA.md"; G_A=$A; (cd "$G" && git checkout -q "$G_A" && bash "$R/bin/pr-steps" verify "$T/vA.md" >/dev/null 2>&1; git checkout -q -); 
cp "$T/carry.md" "$T/carry-v.md"
check "a small follow-up carries an earlier head's Loop A" 0 "$(prs verify "$T/carry-v.md")"
cp "$T/carry.md" "$T/carry-f.md"
check "BLOCK: carrying a step the earlier head never recorded" 1 "$(prs fresh "$T/carry-f.md")"
seq 1 100 > "$G/big"; git -C "$G" add big; git -C "$G" -c user.name=t -c user.email=t@t commit -q -m c
printf 'carries the pass of %s: big change\n' "$A" > "$T/carry2.md"
check "BLOCK: carrying across more than 80 changed lines" 1 "$(prs loopb "$T/carry2.md")"
# ---------- pr-steps: every converge step leaves its proof; the guard needs all six ----------
G2="$T/prs2"; mkdir -p "$G2"; git -C "$G2" init -q; git -C "$G2" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a
prs2() { (cd "$G2" && bash "$R/bin/pr-steps" "$@" >/dev/null 2>&1; echo $?); }
ready() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh pr ready 5"},"cwd":sys.argv[1]}))' "$G2" | python3 "$R/hooks/pre-bash-guard.py" >/dev/null 2>&1; echo $?; }
check "BLOCK: gh pr ready with no step recorded" 2 "$(ready)"
printf 'slice 1: no bug that counts\n' > "$T/v0.md"
check "BLOCK: a Loop A output without NO BUGS" 1 "$(prs2 verify "$T/v0.md")"
printf 'slice 1: no bug that counts\nNO BUGS\n' > "$T/v.md"; check "Loop A ending NO BUGS records" 0 "$(prs2 verify "$T/v.md")"
printf 'nothing worth changing\nCLEAN\n' > "$T/lb.md"; check "Loop B's review ending CLEAN records" 0 "$(prs2 loopb "$T/lb.md")"
printf '| vike() | 5 ⇒ 8 | abc | why |\n✅ vike()\n' > "$T/rf.md"; check "Loop B's ratings record" 0 "$(prs2 refactor "$T/rf.md")"
printf 'NO LOOP B COMMITS\n' > "$T/rv.md"; check "Loop A again, with no Loop B commits, records" 0 "$(prs2 reverify "$T/rv.md")"
printf 'CLEAN\n' > "$T/fr0.md"; check "BLOCK: a fresh read without MERGE AS IS: yes" 1 "$(prs2 fresh "$T/fr0.md")"
printf 'MERGE AS IS: yes\nCLEAN\n' > "$T/fr.md"; check "the fresh reader's merge-as-is and CLEAN record" 0 "$(prs2 fresh "$T/fr.md")"
printf 'pnpm test -> exit 0\npnpm lint -> exit 1\n' > "$T/g1.md"
check "BLOCK: a gates log with a red gate" 1 "$(prs2 gates "$T/g1.md")"
check "BLOCK: gh pr ready with five of six steps" 2 "$(ready)"
printf 'pnpm test -> exit 0\npnpm lint -> exit 0\n' > "$T/g2.md"; check "a green gates log records" 0 "$(prs2 gates "$T/g2.md")"
check "BLOCK: gh pr ready with the six steps but no approach record" 2 "$(ready)"
printf '| Candidate | Rating | Why |\n|---|---|---|\n| Not building it | 3 | the bug stays |\n| Fix in place | 5 | misses siblings |\n| Fix the shared helper | 8 | one place for all |\n\nChosen: Fix the shared helper\n' > "$T/ap.md"
printf '| Candidate | Rating | Why |\n|---|---|---|\n| Fix the shared helper | 8 | only one |\n\nChosen: Fix the shared helper\n' > "$T/ap1.md"
printf '| Candidate | Rating | Why |\n|---|---|---|\n| Not building it | 3 | the bug stays |\n| Fix in place | 6 | misses siblings |\n\nChosen: Fix in place\n' > "$T/ap6.md"
printf '| Candidate | Rating | Why |\n|---|---|---|\n| Not building it | 3 | the bug stays |\n| Fix in place | 8 | ok |\n\nChosen: Rewrite\n' > "$T/apx.md"
check "BLOCK: an approach with one candidate" 1 "$(prs2 approach "$T/ap1.md")"
check "BLOCK: a chosen approach rated 6" 1 "$(prs2 approach "$T/ap6.md")"
check "BLOCK: a chosen approach that is no candidate" 1 "$(prs2 approach "$T/apx.md")"
check "BLOCK: gh pr ready after refused approach records" 2 "$(ready)"
check "an approach with three rated candidates and a chosen 8 records" 0 "$(prs2 approach "$T/ap.md")"
check "gh pr ready passes once all six steps and the approach hold" 0 "$(ready)"
printf 'm\n' > "$G2/m"; git -C "$G2" add m; git -c user.name=maint -c user.email=m@m -C "$G2" commit -q -m "a maintainer's tweak"
check "a maintainer's commit on a converged head carries its steps" 0 "$(ready)"
seq 1 81 > "$G2/m2"; git -C "$G2" add m2; git -c user.name=maint -c user.email=m@m -C "$G2" commit -q -m "a maintainer's rewrite"
check "a big maintainer commit carries them too: the pipeline waits for their go" 0 "$(ready)"
git -C "$G2" reset -q --hard HEAD~1
printf 'y\n' > "$G2/g"; git -C "$G2" add g; git -c user.name=t -c user.email=t@t -C "$G2" commit -q -m c -m 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'
check "BLOCK: a new HEAD has no steps, but the approach is not what it lacks" 2 "$(ready)"
check "the approach block message does not name approach on the new HEAD" 0 "$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh pr ready 5"},"cwd":sys.argv[1]}))' "$G2" | python3 "$R/hooks/pre-bash-guard.py" 2>&1 | grep -c 'pr-steps approach')"
# ---------- pre-design-gate: Tier M code waits for prior-art.md and decisions/*.md ----------
D="$T/dg"; mkdir -p "$D" "$D-work"; git -C "$D" init -q
gate() { python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1],"tool_input":json.loads(sys.argv[2]),"cwd":sys.argv[3]}))' "$1" "$2" "$D" | python3 "$R/hooks/pre-design-gate.py" 2>/dev/null; echo $?; }
check "no scope.md: an edit passes" 0 "$(gate Edit "{\"file_path\":\"$D/a.ts\"}")"
printf 'Tier: M, because x\n' > "$D-work/scope.md"
check "BLOCK: Tier M edit with no prior art or decision" 2 "$(gate Edit "{\"file_path\":\"$D/a.ts\"}")"
check "BLOCK: Tier M implementation agent with no decision" 2 "$(gate mcp__t3-code__delegate_task '{"role":"implementation"}')"
check "a research agent passes" 0 "$(gate mcp__t3-code__delegate_task '{"role":"research"}')"
check "an artifact-root write passes" 0 "$(gate Write "{\"file_path\":\"$D-work/prior-art.md\"}")"
touch "$D-work/prior-art.md"; mkdir -p "$D-work/decisions"; touch "$D-work/decisions/x.md"
check "Tier M edit passes once prior art and a decision exist" 0 "$(gate Edit "{\"file_path\":\"$D/a.ts\"}")"
# ---------- pre-bash-guard: never kill a running agent ----------
printf '#!/bin/sh\nsleep 600\n' > "$T/claude"; chmod +x "$T/claude"
"$T/claude" --output-format stream-json >/dev/null 2>&1 & APID=$!
sleep 600 >/dev/null 2>&1 & OPID=$!
sleep 0.3
kill_guard() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"kill "+sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$T" | python3 "$R/hooks/pre-bash-guard.py" 2>/dev/null; echo $?; }
check "BLOCK: kill of an agent's claude process" 2 "$(kill_guard $APID)"
check "kill of an ordinary process passes" 0 "$(kill_guard $OPID)"
kill $(ps -o pid= --ppid $APID) $APID $OPID 2>/dev/null
printf 'See #7.\n' > "$T/ref.md"
check "post-lint: a 404 reference doesn't exist" 1 "$(python3 "$R/bin/post-lint" "$T/ref.md" --kind reply --repo o/r --parent none 2>&1 | grep -c "doesn't exist in o/r")"
check "post-lint: a rate-limited check says it couldn't check, not that it doesn't exist" "1 0" "$(GH_STUB_403=1 python3 "$R/bin/post-lint" "$T/ref.md" --kind reply --repo o/r --parent none 2>&1 | grep -c "couldn't check it") $(GH_STUB_403=1 python3 "$R/bin/post-lint" "$T/ref.md" --kind reply --repo o/r --parent none 2>&1 | grep -c "doesn't exist")"
rm -rf "$T"
echo "failures: $fails"; [ "$fails" = 0 ]
