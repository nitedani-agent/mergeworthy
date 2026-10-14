---
name: reply
description: "Woken by the Monitor, a `/ai` comment or a resume; a comment to answer; any watcher event: the event table, then the answer through post."
---

# Reply

The watcher is a daemon that records GitHub events in `<work folder>/events.log` and adds 👀 to each comment you owe; the Monitor (`task` step 5) wakes you when it records one. You answer; agents only draft a reply or sort a follow-up. A maintainer's comment is handled like the user typing in this chat: highest priority, full effort. A `/ai` or `/agent` comment is the user typing: start it at once, in parallel with what's running, through `task`, and tell the user in chat.

## Steps

1. **Read `events.log` past the line in `events.cursor`;** move the cursor as you handle each event. After any resume, or any time the Monitor wasn't armed, do this before anything else; when the Monitor expires, its notice wakes you: re-arm it at once. Never poll GitHub in a loop. Work in this order: the user's chat message (a `/ai` comment counts as one), red CI on your PR, a maintainer's comment, the critical path, side work.
   Open: `<work folder>/events.log` · Record: `events.cursor`
2. **Route each event** by its row of §Events.
   Open: §Events · Hook: the watcher
3. **A comment that takes more than ~15 minutes to answer:** post a holding reply first through `post`'s fast form, carrying what you've found so far and when the answer comes, and make its owed line `holding: <URL> <ETA>`; while a drafter works, `drafting: <comment URL> <ETA>`. Before acting on any comment, check that its reason fits the line it's anchored to; if it fits another line better, ask before changing anything.
   Open: `post` · Record: the line in `replies-owed.md` · Hook: stop-lint
4. **Decide what it asks,** yourself, not an agent: an instruction, a question about your work's quality, a decision question, an acknowledgement, a 👍 or 👎, "I don't understand", a bot's finding (§Kinds of comment). An instruction on a ready PR: 80 lines or fewer and adding no behavior, do it and carry the pass (`converge §Batching`); otherwise a holding reply with the pipeline's ETA.
   Open: §Kinds of comment
5. **A decision question or a design point:** `design` steps 1–3 before any answer. Anything else: do the work it asks (code through an implementer, then `merging` step 1).
   Open: `design`; `delegate/implementer.md`
6. **Answer through `post`,** as a new comment, because edits don't notify ("Done in <sha>" for done work). Beyond this answer and the wait ping, a question gets no further comments from you; later changes are edits.
   Open: `post` steps 1–5 · Record: the gate file · Hook: pre-bash-guard
7. **Same step:** clear the owed line; put every "OK?" you asked and every promise into `proposals-open.md`; Tier M: a ledger row; Tier L: the umbrella and its Decisions comment through `post`. After a burst of maintainer comments, check the PR: no comment is the last word without a change, an answer or a reaction.
   Open: `task §Files`; `task §Umbrella` · Record: the owed line, proposals-open.md · Hook: stop-lint, gate-pass (PROMISED)
8. **Before the turn ends,** name the first open critical-path item and move it (`task §Drive`). Once per session, schedule a check every 3 hours (T3 Code: `schedule_task`, bound to this thread; elsewhere Claude Code's `CronCreate`), its prompt naming the goal, not only the owed lists: a wakeup that only confirms nothing waits on you has stalled.
   Open: `task §Drive`; §Wait ping · Record: the scheduled task · Hook: stop-lint

### Events

| Event | Do |
|---|---|
| a comment you answer (§Which comments) | steps 3–7 |
| `### CI … red=` on your PR | Fix it first. When the red isn't the PR's doing (a secret forks don't get, a flaky job), one PR comment through `post` with the cause and the evidence (the workflow line, or the same failure on another PR or `main`), right away; explaining it only in chat leaves the PR looking broken. |
| `### MAINTAINER COMMITS` | §Maintainer commits |
| `### ACK` | step 4 as an acknowledgement: it answers your last open proposal, which is now an instruction |
| `### THUMBS UP` / `### THUMBS DOWN` | §Reactions |
| `WAIT PING DUE` | §Wait ping |
| `### DEPENDENT of merged …`, or a release you wait on | In the same step, apply what waited on it and post the progress on the dependent PR. Check releases and unwatched PRs in `waiting-on.txt` yourself at every wakeup. |
| `### TRACKER STALE` | `task §Umbrella`, through `post --kind tracker` |
| `### SHAPE STALE` | `converge` step 2 on the whole diff, before the next "Done" reply |
| `### AGENT DONE <ticket>` | `delegate` step 6 |
| `### FOLLOW-UP` | the steward runs `rules` step 6. Another session gets it only while no steward is declared in `~/.mergeworthy/steward`, and then runs `rules` step 6 itself. |
| `### AGENT COMMAND`, `### UNROUTED /agent` | the user typing: `task` |
| `### NEW ISSUE`, `### NEW PR` (a repo watched whole: `owner/repo all`) | answer it like a comment you owe (steps 3–7) |

### Which comments

Answer these, and nothing else (the watcher reports exactly these and records each in `replies-owed.md`):
- **On a thread you opened:** every human's comment (maintainer, contributor, the user) and every inline finding of a review bot (a bot's summary comments ask nothing). A bot's finding is a reviewer's finding: run its case first (`review` step 3), then reply with the fix's commit or the output that declines it.
- **On a thread you only posted in:** a maintainer's comment (write access to the repo) or the user's.
- **On a repo watched whole** (`owner/repo all` in `repos.txt`): every issue, PR and comment without the agent's badge.
- **On any other thread:** the user's comment containing `/ai` or `/agent`.

### Kinds of comment

- **An instruction** ("Let's…", "Remove…", "Merge origin/main") or a suggestion block: do it, then reply "Done in <sha>."
- **A question about your work's quality** ("Is it all DRY?", "Is this tested?") is answered by the work: if the answer is no, fix it, push, and answer with what was missing and the commit. Never ask permission to close a gap they just pointed at.
- **A question or soft suggestion about a decision** ("Overkill?", "How about…?", "why…?", "I think we can…") gets an answer, never a code change that reverses the decision until they answer it. "Why did you X?" asks for the reason: give it, and if you now think X was wrong, say so with your recommendation and ask. "How about X?" starts with yes or no and the one real obstacle; when their idea is simpler than yours, recommend it. If the answer needs work, say what you're checking; never agree with a premise or promise a change you haven't measured. Hold any loop finding on the questioned lines until they answer.
- **A short acknowledgement** ("OK", "Good!", 👍) is not the end of the thread. It answers your last open proposal or question in that thread; if that thread has none, your latest one elsewhere in the same PR, posted just before it. That proposal is now an instruction. If it could answer two, do both if they don't conflict, else ask which in one line. "The rest LGTM" agrees to every unquestioned proposal in the comment it answers: record them as agreed and start. Only an acknowledgement of a finished change needs nothing but a 👍.
- **"I don't understand this"** on a docs or code-comment line reports a bug in that text: push clearer wording and reply "Done in <sha>: <new sentence>"; ask "OK?" only if the meaning changes.
- **A request for a full review** of their own commits: run `converge` only when they ask.

### Maintainer commits

Fetch, fast-forward, and run the gates on the head. Then one table through `post`, `| Commit | What it does, and the idea behind it | Rating |`, rated N/10: the middle column one short sentence; a rating below 10 carries its reason (`8/10 (invalid keys untested now)`); 10/10 only when nothing could be better; findings with the exact fix. A big change goes to the PR's Loop B agent (`converge` step 2) for its review and re-rating. Never just "looks good", and don't push onto the branch while they're committing unless asked.

### Reactions

A 👍 or 👎 from the user or a maintainer on one of your comments is feedback on it. 👍: note what they liked; on a proposal it is also the approval. 👎: a named failure: `rules` steps 1–2. Then, if the thread is still on that point, post a new reply with the fix that @-mentions them; if it has moved on, edit the 👎'd comment to add how you'll do better. Leave the 👎.

### Wait ping

The watcher owes a `WAIT PING DUE` in `replies-owed.md` after 3 hours of silence on your last comment. Post it only when the wait blocks your work now: your next step can't move without it. A release or review your own unmerged work will need later blocks nothing yet: clear the line with that reason. The ping is one @-mention on that PR with the decisions you need, each with your pick and its link; once per thread per wait, never while they're mid-review (a maintainer who commented, reviewed or pushed in any of your threads since your ask is mid-review). In a long design thread, update the WIP comment instead (`design §WIP comment`).
