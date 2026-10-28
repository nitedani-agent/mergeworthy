#!/usr/bin/env bash
# Tests for bin/steward (the steward skill's numbers and lists). Usage: tests/steward.sh [repo root]
# Temp HOME with work folders and session logs, a stub gh answering the user, the PR search and one GraphQL query per PR.
set -u
R=$(readlink -f "${1:-$(dirname "$0")/..}")
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME/.claude/projects/p" "$HOME/.codex/sessions/2026" "$HOME/.mergeworthy/work" "$T/bin"
fails=0
check() { echo "$1: $3 (want $2)"; [ "$2" = "$3" ] || fails=$((fails+1)); }
iso() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }

# ---------- owed: each folder's open reply, unsorted follow-up and promise; done lines and sorted events don't count ----------
W="$HOME/.mergeworthy/work/a"; mkdir -p "$W"
printf '# replies owed\no/r#1 comment 11 by bob https://github.com/o/r/issues/1#issuecomment-11 - why\ndone: https://x 12\n' > "$W/replies-owed.md"
printf '### FOLLOW-UP o/r#5: abcdef1234 by carol renames  at 2026-10-01T00:00:00Z\n### FOLLOW-UP o/r#5: 9999999aaa by carol touches  at 2026-10-01T00:00:00Z\n' > "$W/events.log"
echo 'abcdef1 TASTE https://x' > "$W/followups-sorted.txt"
printf 'PROMISED o/r#1: the table by 18:00 UTC (r.md)\nDONE https://x PROMISED o/r#1: old\n' > "$W/proposals-open.md"
out=$(python3 "$R/bin/steward" owed)
check "owed: one open reply, the unsorted follow-up, one promise, each line naming the folder with ~ and its watcher state" \
  "1 1 1 3" "$(echo "$out" | grep -c $'\treply\to/r#1 comment 11') $(echo "$out" | grep -c $'\tsort\to/r#5 9999999aaa') $(echo "$out" | grep -c $'\tpromise\tPROMISED o/r#1: the table') $(echo "$out" | grep -c '^~/.mergeworthy/work/a (no watcher, session unknown)')"
printf 'holding: https://x/1 2099-01-01T00:00:00Z\nholding: https://x/2 2020-01-01T00:00:00Z\n' >> "$W/replies-owed.md"
check "owed: a holding line whose ETA is ahead is its session's; one past its ETA is listed" "0 1" "$(python3 "$R/bin/steward" owed | grep -c 'x/1') $(python3 "$R/bin/steward" owed | grep -c 'x/2')"
check "owed: a sorted follow-up and a done line are not listed" "0 0" "$(echo "$out" | grep -c abcdef1234) $(echo "$out" | grep -c 'https://x 12')"
echo '### FOLLOW-UP o/r#5: https://github.com/o/r/pull/10 by dan references your PR  at 2026-10-01T00:00:00Z' >> "$W/events.log"; echo 'https://github.com/o/r/pull/1 MISS https://x' >> "$W/followups-sorted.txt"
check "owed: a referencing PR stays unsorted though a PR whose URL is a prefix of its URL is sorted" 1 "$(python3 "$R/bin/steward" owed | grep -c $'\tsort\to/r#5 https://github.com/o/r/pull/10$')"
B="$HOME/.mergeworthy/work/b"; mkdir -p "$B" "$HOME/.claude/projects/q"; echo sess-b > "$B/session"; echo 'o/r#2 comment 21 by bob' > "$B/replies-owed.md"; : > "$HOME/.claude/projects/q/sess-b.jsonl"
check "owed: a folder whose session wrote its log in the last 2 hours is left to it" 0 "$(python3 "$R/bin/steward" owed | grep -c 'comment 21')"
touch -d '-3 hours' "$HOME/.claude/projects/q/sess-b.jsonl"
check "owed: once that session is idle, its owed reply is listed with the idle hours" 1 "$(python3 "$R/bin/steward" owed | grep -c '^~/.mergeworthy/work/b (no watcher, session idle 3h)'$'\t''reply'$'\t''o/r#2 comment 21')"
rm -r "$B" "$HOME/.claude/projects/q"

# ---------- sessions: tokens, turns, PRs and the user's corrections, Claude Code and Codex alike ----------
python3 - "$HOME" "$(iso '-2 hours')" "$(iso '-1 hours')" <<'EOF'
import json, sys, os
home, t0, t1 = sys.argv[1:]
with open(os.path.join(home, '.claude/projects/p/s1.jsonl'), 'w') as f:
    for e in [{'type': 'user', 'timestamp': t0, 'message': {'role': 'user', 'content': 'fix https://github.com/o/r/pull/5 please'}},
              {'type': 'assistant', 'timestamp': t0, 'message': {'id': 'm1', 'content': [{'type': 'thinking'}], 'usage': {'input_tokens': 100, 'output_tokens': 50, 'cache_read_input_tokens': 1000}}},
              {'type': 'assistant', 'timestamp': t0, 'message': {'id': 'm1', 'content': [{'type': 'tool_use'}], 'usage': {'input_tokens': 100, 'output_tokens': 50, 'cache_read_input_tokens': 1000}}},
              {'type': 'user', 'timestamp': t1, 'message': {'role': 'user', 'content': [{'type': 'tool_result', 'content': 'why did it fail'}]}},
              {'type': 'user', 'timestamp': t1, 'message': {'role': 'user', 'content': "why did you skip the tests? that's wrong"}},
              {'type': 'user', 'isMeta': True, 'timestamp': t1, 'message': {'role': 'user', 'content': [{'type': 'text', 'text': 'Base directory for this skill: stop if it is wrong'}]}}]:
        f.write(json.dumps(e) + '\n')
with open(os.path.join(home, '.codex/sessions/2026/c1.jsonl'), 'w') as f:
    for e in [{'timestamp': t0, 'type': 'event_msg', 'payload': {'type': 'user_message', 'message': 'nem jó, revert it'}},
              {'timestamp': t1, 'type': 'event_msg', 'payload': {'type': 'token_count', 'info': {'total_token_usage': {'input_tokens': 5000, 'cached_input_tokens': 2000, 'output_tokens': 1000, 'reasoning_output_tokens': 300, 'total_tokens': 6000}}}}]:
        f.write(json.dumps(e) + '\n')
EOF
out=$(python3 "$R/bin/steward" sessions --since "$(iso '-1 day')")
check "sessions: the Claude log's hours, turns, tokens (one message's two content-block lines counted once) and PR; a tool result is no turn" "1" "$(echo "$out" | grep -c $'^~/.claude/projects/p/s1.jsonl\t.*\t1.0h\t2 turns\t150 tokens\to/r#5$')"
check "sessions: the correction, with its line; the Codex log's tokens (cache reads left out) and correction" "1 1 1" "$(echo "$out" | grep -c 's1.jsonl:5'$'\t''why did you skip') $(echo "$out" | grep -c $'\t1 turns\t4000 tokens') $(echo "$out" | grep -c 'c1.jsonl:1')"
check "sessions: text the harness injects (a skill's, isMeta) is no turn and no correction" 0 "$(echo "$out" | grep -c 's1.jsonl:6')"
check "sessions: a log older than --since is left out" 0 "$(python3 "$R/bin/steward" sessions --since "$(iso '+1 hour')" | grep -c jsonl)"

# ---------- metrics: two PRs of the window (one merged first pass, one reworked), one of the window before, one without a badge ----------
C1=$(iso '-3 days'); M1=$(iso '-2 days'); C10=$(iso '-8 days'); R10=$(iso '-3 days'); B10=$(iso '-2 days'); M10=$(iso '-1 days'); C9=$(iso '-1 days'); C2=$(iso '-4 days'); R2=$(iso '-3 days'); M2=$(iso '-1 days'); C3=$(iso '-7 days'); M3=$(iso '-6 days')
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "api user") echo '{"login":"me"}' ;;
  *is:open*) echo '{"items":[{"number":9,"repository_url":"https://api.github.com/repos/o/r","user":{"login":"me"},"body":"<img src=\"https://github.com/claude.png\" alt=\"Claude\"> *x*"}]}' ;;
  *search/issues*) cat <<'J'
{"items":[{"number":5,"repository_url":"https://api.github.com/repos/o/r","user":{"login":"me"},"body":"<img src=\"https://github.com/claude.png\" alt=\"Claude\"> *x*\\nbody"},
{"number":6,"repository_url":"https://api.github.com/repos/o/r","user":{"login":"me"},"body":"<img src=\"https://github.com/claude.png\" alt=\"Claude\"> *x*"},
{"number":7,"repository_url":"https://api.github.com/repos/o/r","user":{"login":"me"},"body":"<img src=\"https://github.com/claude.png\" alt=\"Claude\"> *x*"},
{"number":8,"repository_url":"https://api.github.com/repos/o/r","user":{"login":"me"},"body":"a PR the user wrote"},
{"number":10,"repository_url":"https://api.github.com/repos/o/r","user":{"login":"me"},"body":"<img src=\"https://github.com/claude.png\" alt=\"Claude\"> *x*"}]}
J
  ;;
  *n=10*) echo '{"data":{"repository":{"pullRequest":{"state":"MERGED","merged":true,"createdAt":"$C10","mergedAt":"$M10","closedAt":"$M10","author":{"login":"me"},"timelineItems":{"nodes":[]},"reviews":{"nodes":[{"author":{"login":"boss"},"authorAssociation":"OWNER","state":"APPROVED","submittedAt":"$R10","comments":{"totalCount":0}}]},"commits":{"nodes":[{"commit":{"committedDate":"$C10","parents":{"totalCount":1}}},{"commit":{"committedDate":"$B10","parents":{"totalCount":2}}}]}}}}}' ;;
  *n=9*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"createdAt":"$C9","mergedAt":null,"closedAt":null,"author":{"login":"me"},"timelineItems":{"nodes":[]},"reviews":{"nodes":[]},"commits":{"nodes":[]}}}}}' ;;
  *n=5*) echo '{"data":{"repository":{"pullRequest":{"state":"MERGED","merged":true,"createdAt":"$C1","mergedAt":"$M1","author":{"login":"me"},"timelineItems":{"nodes":[]},"reviews":{"nodes":[{"author":{"login":"boss"},"authorAssociation":"OWNER","state":"APPROVED","submittedAt":"$M1","comments":{"totalCount":0}}]},"commits":{"nodes":[{"commit":{"committedDate":"$C1","parents":{"totalCount":1}}}]}}}}}' ;;
  *n=6*) echo '{"data":{"repository":{"pullRequest":{"state":"MERGED","merged":true,"createdAt":"$C2","mergedAt":"$M2","author":{"login":"me"},"timelineItems":{"nodes":[{"createdAt":"$C2"}]},"reviews":{"nodes":[{"author":{"login":"boss"},"authorAssociation":"MEMBER","state":"CHANGES_REQUESTED","submittedAt":"$R2","comments":{"totalCount":3}},{"author":{"login":"me"},"authorAssociation":"OWNER","state":"COMMENTED","submittedAt":"$R2","comments":{"totalCount":1}}]},"commits":{"nodes":[{"commit":{"committedDate":"$C2","parents":{"totalCount":1}}},{"commit":{"committedDate":"$M2","parents":{"totalCount":1}}}]}}}}}' ;;
  *n=7*) echo '{"data":{"repository":{"pullRequest":{"state":"MERGED","merged":true,"createdAt":"$C3","mergedAt":"$M3","author":{"login":"me"},"timelineItems":{"nodes":[]},"reviews":{"nodes":[]},"commits":{"nodes":[]}}}}}' ;;
  *) echo "unexpected gh \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
S="$HOME/.mergeworthy/work/steward"; mkdir -p "$S"; echo "$(iso '-5 days') first pass" > "$S/passes.txt"
echo '### FOLLOW-UP o/r#5, #6: 1234567abc by carol changes lines from your PR  at 2026-10-01T00:00:00Z' >> "$W/events.log"
check "owed: a follow-up naming two PRs is listed once, with both" 1 "$(python3 "$R/bin/steward" owed | grep -c $'\tsort\to/r#5, #6 1234567abc')"
echo '1234567 MISS https://x' >> "$W/followups-sorted.txt"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"review https://github.com/o/r/pull/5 and https://github.com/o/r/pull/6"}}' '{"type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":0}}}' > "$HOME/.claude/projects/p/tie.jsonl"
out=$(PATH="$T/bin:$PATH" python3 "$R/bin/steward" metrics "$S"); rc=$?
rm "$HOME/.claude/projects/p/tie.jsonl"  # naming #5 and #6 once each, it is neither one's cost
rec() { python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; p=[x for x in r if x["pr"]==sys.argv[2]][-1]; print(*(p[k] for k in sys.argv[3:]))' "$S/metrics.jsonl" "$@"; }
check "metrics: exits 0 and records the five badge PRs (one still open), not the user's own" "0 5" "$rc $(wc -l < "$S/metrics.jsonl")"
check "metrics: a merge with only an approval is first-pass; its tokens (no cache reads) come from the session naming it; its TASTE and the MISS of a follow-up naming it and #6 counted" "merged True 0 0 24.0 150 this 2" "$(rec o/r#5 outcome first_pass change_requests commits_after_review hours_to_merge tokens window followup_miss_taste)"
check "metrics: a change request and a commit after it: not first-pass; the author's own review isn't a maintainer's; its MISS counted" "False 1 1 1 3 None 1" "$(rec o/r#6 first_pass review_rounds change_requests commits_after_review review_comments tokens followup_miss_taste)"
check "metrics: a PR merged before --since falls in the previous window" "previous" "$(rec o/r#7 window)"
check "metrics: a PR created before --since and merged after it counts in this window; a merge of the base after approval isn't rework" "this True 0" "$(rec o/r#10 window first_pass commits_after_review)"
check "metrics: an open PR is listed apart" "open|Open now: 1" "$(rec o/r#9 window)|$(echo "$out" | grep '^Open now')"
check "metrics: the side-by-side table, first-pass acceptance per window" "| first-pass acceptance (north star) | 1/1 (100%) | 2/3 (66%) |" "$(echo "$out" | grep 'north star')"

check "sessions <folder>: the window starts at the folder's last pass" 2 "$(python3 "$R/bin/steward" sessions "$S" | grep -c "^~")"
touch -d '-1 minute' "$HOME/.claude/projects/p/s1.jsonl" "$HOME/.codex/sessions/2026/c1.jsonl"  # written before the pass ends
PATH="$T/bin:$PATH" python3 "$R/bin/steward" done "$S" 2 replies, 1 PR
check "done: the pass's time and summary end passes.txt, and the next window starts there" "2 replies, 1 PR|0" "$(tail -1 "$S/passes.txt" | cut -d' ' -f2-)|$(python3 "$R/bin/steward" sessions "$S" | grep -c "^~")"
# round: gh-watch-start --round on the folder with each open PR of yours (steward_line adds the mergeworthy repo for a declared folder)
SB="$T/sbin"; mkdir -p "$SB"; cp "$R/bin/steward" "$SB/"; printf '#!/bin/sh
echo "$@" > "%s/args"
' "$T" > "$SB/gh-watch-start"; chmod +x "$SB/gh-watch-start"
printf '#!/bin/sh
echo %s
' "'[{\"repository\":{\"nameWithOwner\":\"o/r\"},\"number\":5,\"body\":\"<img src=x alt=\\\"Claude\\\"> *y*\"},{\"repository\":{\"nameWithOwner\":\"x/y\"},\"number\":9,\"body\":\"<img src=x alt=\\\"Codex\\\"> *y*\"},{\"repository\":{\"nameWithOwner\":\"u/v\"},\"number\":3,\"body\":\"a PR the user wrote\"}]'" > "$T/bin/gh"
PATH="$T/bin:$PATH" python3 "$SB/steward" round "$S"
check "round: one watcher round on the folder with each open PR an agent wrote, not the user's own; no repo watched whole from here" "--round $(readlink -f "$S") o/r 5 x/y 9" "$(cat "$T/args")"
echo "failures: $fails"
rm -rf "$T"
[ "$fails" -eq 0 ]
