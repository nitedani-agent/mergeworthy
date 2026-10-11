---
name: github-threads
description: "Any GitHub thread you're in: the live loop (watcher, 👀, replies, which threads are yours) and the posting gate every post, edit and PR body passes."
---

## 1.5 The live GitHub loop (every tier, from your first post until every thread you're in is merged or closed)

**A maintainer's comment is handled like the user typing in this chat:** highest priority, full effort.

**Red CI on your PR is the maintainer's first question.** Fix it. When the red isn't the PR's doing (a secret forks don't get, a flaky job), say so on the PR right away. One comment gives the cause and the evidence: the workflow line, or the same failure on another PR or `main`. Explaining it only in chat leaves the PR looking broken.

**Which comments you answer.** Answer these, and nothing else:
- **On a thread you opened:** everything a person would answer on their own PR. That is every human's comment (maintainer, contributor, the user) and every inline finding of a review bot (CodeRabbit and the like; a bot's summary comments ask nothing).
- **A bot's finding is a reviewer's finding:** run its case first (`review`), then reply with the fix's commit or the output that declines it.
- **On a thread you only posted in:** a maintainer's comment (write access to the repo) or the user's.
- **On any other thread:** the user's comment, when it contains `/ai` or `/agent`.
- **What the watcher does with them:** it reports exactly these comments and adds 👀 to each (GitHub has no reactions on reviews). It records each comment and review in `replies-owed.md`.
- **A `/ai` comment is the user typing in this chat.** Start the work at once, in parallel with what's running rather than queued behind it. Follow the skill the comment calls for (`pull-request` for "fix it" or "open a PR"), and tell the user in chat.

Each comment you answer goes through these steps:

1. **On detection:** the watcher adds 👀 to new answerable comments; reviews cannot receive reactions. New comments on a watched thread arrive within about two minutes, through feeds polled once a minute; edits wait for the thread's next check (5 minutes to 6 hours).
2. **The answer, or a holding reply.** A drafter subagent drafts it from `thread-context.md` (`writing` step 0); answer through the gate (1.6). Only when the answer needs long work (more than about 15 minutes) post a holding reply first, through the fast gate, and make it carry something: what you've found so far, and when the answer comes. Before acting on any comment, check that its reason fits the line it's anchored to; if the reason fits another line better, ask before changing anything.
   - **An instruction** ("Let's…", "Remove…", "Merge origin/main") or a suggestion block: do it, then reply "Done in <sha>."
   - **A question about your own work's quality** ("Is it all DRY?", "Is this tested?") is answered by the work: if the answer is no, fix it, push, and answer with what was missing and the commit. Never ask permission to close a gap they just pointed at; maintainers prefer a proactive colleague to one who asks (vikejs/vike#3590).
   - **A question or soft suggestion about a decision** ("Overkill?", "How about…?", "why…?", "I think we can…") gets an answer, never a code change that reverses the decision until they answer it. "Why did you X?" asks for the reason: give it, and if you now think X was wrong, say so with your recommendation and ask. "How about X?" or "Is X possible?" starts with yes or no and the one real obstacle. When their idea is simpler than yours, recommend their idea. If the answer needs work, say what you're checking ("Measuring the calls"); never agree with a premise or promise a change you haven't measured. Hold any loop finding on the questioned lines until they answer.
   - **A short acknowledgement** ("OK", "Good!", 👍) is not the end of the thread: read the whole thread to find what the acknowledgement answers. It answers your last open proposal or question in that thread. If that thread has none, it answers your latest open proposal or question elsewhere in the same PR, posted just before the acknowledgement. That proposal is now an instruction. If the acknowledgement could answer two, do both if they don't conflict; otherwise ask which in one line. Only an acknowledgement of a finished change needs nothing but a 👍.
   - **A 👍 or 👎 reaction** from the user or a maintainer on one of your comments is feedback on that comment. For 👍, note what they liked and reinforce the rule that produced it; on a proposal, the 👍 is also the approval. For 👎, work out why and fix the rule behind it (1.1.12). Then, if the thread is still on that point, post a new reply with the fix that @-mentions them. If the thread has moved on, edit the 👎'd comment to add how you'll do better. Leave the 👎 either way.
   - **A maintainer's commits pushed to your PR** (the watcher's `### MAINTAINER COMMITS`): fetch, fast-forward, and run the gates on the head. Then review each commit in one table, `| Commit | What it does, and the idea behind it | Rating |`, rated N/10:
     - the middle column says in one short sentence what the commit does;
     - a rating below 10 carries its reason in a few words next to it (`8/10 (invalid keys untested now)`);
     - 10/10 only when nothing could be better;
     - findings come with the exact fix; where the change is big, send the commits to the PR's Loop B agent (`converge`) and use its review and re-rating; with no loop running, apply `review`'s reviewer charter and `refactor`'s prompt to it;
     - never just "looks good", and don't push onto the branch while they're committing unless asked;
     - end offering a full review; run `converge` only when they ask, mark it ready or request your review.
   - **"I don't understand this"** on a docs or code-comment line reports a bug in that text. Push clearer wording and reply "Done in <sha>: <new sentence>"; ask "OK?" only if the meaning changes.
3. **Then think, as a mini debate.** Instructions and acknowledgements skip this step. Keep your argued position until evidence changes it (`writing`, Design threads).
   - **The whole picture first:** what does the maintainer want overall? Trace the actual flow in code (caller → callee, which object each side sees, in each environment). Check that every path to the same thing behaves consistently, and name any gap you find with `file:line` and the next check.
   - **Then one fresh-context agent argues it divergently,** with that evidence, what `main` does, and a measurement where one is possible. Is "over-engineering" the right call, or is there a small, cleaner fix?
   - **The agent first only generates, no judging:** the strongest case for the maintainer's view and the strongest case against. Each case comes from at least three frames, past the obvious first answers. Frames include the user who hits it, the maintainer who keeps the code, and the smallest diff. Others are the version with no new code, and the design from scratch.
   - **Only then does the agent judge:** it scores both sides, names each side's weakest point and the traps (hidden cost, a fix for a case nobody hits), and recommends.
   - **You decide.** Rate the agent's recommendation as in `pull-request` step 3 (open `pull-request` for the rating steps), and decide.
   - **Before answering "keep",** build the simpler version (theirs, or the simplest row of your own comparison) and name what breaks in it. If nothing breaks, recommend the simpler version.
   - **The reply reads as one person thinking** (`mergeworthy:writing`): your view, the reason, why the other side lost, as code at both ends where it's about behavior.
   - **Converge (design threads): head the thread to an agreed design, and carry its load.** How each reply converges (own position, evidence, invariants, agreement before code) is `mergeworthy:writing`. Keep a map of the whole thread in the artifact root: linked threads and PRs, every invariant agreed (with the link) or open, and where it is heading. A decision blocks only the part it decides: start everything else now. When the design has drifted over several rounds, run the finality pass first (`finality`), then bring the WIP comment's Agreed and Open lists (below) up to date from the map. The map stays your own file.
   - **Answer the question behind the literal one.** Your answer may show the defect is a class (a default, a parser, a shared helper). Then recommend the class-wide fix with its evidence, not only the instance the PR fixes. When they question an example or post their own code, say why not that simpler version. When a measurement rejects their suggestion, offer a measured way to reach its goal. "First principles" or "perfect world" means the ideal design, regardless of the open PR.
4. **Then reply** with the result as a new comment, because edits don't notify. Beyond this result (and the wait ping below), a question gets no further comments from you; later changes to your reply are edits.
5. **Book-keeping, in the same step:** decision packet, umbrella body, Decisions comment, ledger.

### The watcher and the owed lists

**Start the watcher before your first post on any thread.** The watcher is a daemon that records GitHub events for you; a Monitor in your session wakes you when it records one. Unless the plugin's `watcher` option is `off`:
- **Start:** before you open an issue or PR in any tier (an audit report included), run `gh-watch-start <artifact root> <owner/repo>`. The artifact root you pass becomes the watch dir: the folder holding the watcher's files.
- **Arm the Monitor** the command prints, with the longest timeout (`timeout_ms` 1800000, 30 minutes).
- **Every thread joins the watch list** in the same step you open or post in it. The hooks add it once a watcher runs. The posting guard refuses to open an issue or PR in a repo no running watcher covers.

The watcher runs independently of any session and only records events (and adds 👀); you answer them, woken by the Monitor.
- **Re-arm at once:** when the Monitor expires, its notice wakes you; re-arm it immediately.
- **No polling, no hand-off:** never poll GitHub in a loop in the conversation, and never hand events to a separate agent.
- **After a gap:** after any resume, or any time the Monitor wasn't armed, read `events.log` past the last event you handled before anything else. That event's line number is kept in `events.cursor` in the watch dir; update it as you handle events.

**Each owed list is cleared only by the thing named:**
- **`replies-owed.md`:** every comment you answer (above). Cleared by replacing its line with `done: <reply URL> <what changed>`; a holding reply turns it into `holding: <reply URL> <ETA as an ISO time>` until then. While an agent drafts the answer, `drafting: <comment URL> <ETA>` keeps the stop hook from asking for it before then, so you never wait for the draft in the foreground.
- **`proposals-open.md`:** every "OK?" you ask, and every promise you post ("I'll…") as `PROMISED <thread>: <what> (<draft file name>)`, which `gate-pass` checks. Each new maintainer comment is checked against this list first. Cleared by the commit or link that delivers it. Do work you can finish in minutes before posting, so the post says "Done in <link>", never "fixing it now".
- **`FOLLOW-UP`** (a later commit to your merged PR's lines, or a PR referencing it): brief a subagent with the PR, the commit and `core` 1.3's sort, the same turn. Its MISS items become a mergeworthy fix that turn, its TASTE lines go into the project's notes file with their links, and you check one against git before installing.
- **`waiting-on.txt`,** next to the watcher's `threads.txt`: each thing a PR of yours waits on (`<owner/repo#N> -> <dependent>: <what to do>`), also in that PR's notes table. The watcher prints `DEPENDENT of merged …` when a PR it watches merges. Check releases and unwatched PRs yourself at every wakeup.
- **A dependency that lands** (a merge or release you depend on) is handled like a maintainer comment: in the same step, apply what waited on it and post the progress on the dependent PR.
- **A pending task whose condition is met is done now.**

**After a burst of maintainer comments,** check the PR: no comment is the last word without a change, an answer or a reaction.

**Drive the goal at every wakeup.** A session that drives threads schedules a check every 3 hours (T3 Code: `schedule_task`, bound to its thread), and its prompt names the goal, not only the owed lists. Each wakeup names the critical path from the tracker (the open items between now and the goal shipping, in order) and moves the first one it can, through the steps: the code, the PR, or the reply that converges its thread, asking a clarifying question when a maintainer's point is unclear and a direction question with your recommendation when the decision is theirs. Then a landed dependency gets its step, and another's wait that blocks the path, past 3 hours since your last comment, gets the wait ping. Side work (a quick-win PR, an upstream fix) is welcome, but when it's done, come back to the critical path. A wakeup that only confirms nothing waits on you has stalled.

**The wait ping.** The watcher emits `WAIT PING DUE` and owes it in `replies-owed.md` after 3 hours of silence on your last comment; when the wait blocks your work, post it then, every time; when it blocks nothing, clear it with that reason (`core` 1.1.7). Blocking means your next step can't move without it now: a release or review that your own unmerged work will need later blocks nothing yet, so ask for it only when that work is ready to use it, and keep asks to one maintainer rare:
- one @-mention on that PR with the decisions you need, each with your recommendation and link;
- once per thread per wait, never while they're mid-review. A maintainer who has commented, reviewed or pushed in any of your threads since your ask is mid-review, so no ping.

**A WIP comment instead of repeated pings.** In a long design thread, keep one comment you edit in place, in this form: `# 🚧 WIP`, then *This comment is edited upon updates.*, then `## TLDR` (the goal and where it stands), `## Scope` (what's in and out), `## State` (where each part stands), then `## TODO` with the open work and who it waits on, then `## Agreed` with each agreed point and the permalink where it was agreed, `## Open` with the open items and invariants (each with who it waits on), and `## Next steps` with your recommended order. Replies never repeat these lists. When one changed, edit the comment and say so in your next reply with a link ("I updated the [WIP comment](link)"). That comment is where the maintainer reads what is agreed and what is still open.

**Repo rules:** before a commit, merge or PR in a repo, read its CLAUDE.md / AGENTS.md on the target branch and follow it.

## 1.6 Posting gate (every tier, no exceptions)

**Everything that reaches an external service passes this gate,** with no lighter category: comments, review replies, inline comments, PR and issue bodies, filed issues, and edits of any of these. Reactions are exempt. Only the orchestrator posts, edits posts, and talks to the user; subagents hand it drafts.

1. **Write the draft to the gate’s standard before review** (`core` 1.1.17). Write in `drafts/<name>.md` (never straight into a `gh` command), with the comment it answers in `drafts/<name>.parent.md`.
   - On a thread, build `thread-context <repo#N> --out drafts/<dir>/thread-context.md` and have a drafter subagent draft from it (`writing` step 0); the main session reads only the draft and the drafter's list of conflicts with past decisions. `gate-pass` and `pre-bash-guard` require the file, newer than the parent and recording the thread's latest human comment; a newer comment blocks the post until you rebuild it and re-read.
   - First write the reader's one line (the verdict or the ask) and what they already said.
   - Write it by `mergeworthy:writing` (open it): its drafts (three only where it says), voice, budgets and badge.
   - Read as a newcomer and explain every term on first use (`writing`, How a good colleague writes).
2. **Run `post-lint`** with the draft's `--kind` (and `--repo`). It must pass; `gate-pass` re-runs it with the same flags.
3. **Run the review** (`review`: open it for who reviews) with a prompt file. Fix the draft and log what its writing step missed (`core` 1.1.17). The review checks facts and noise, not word choice:
   - **Claims:** every claim against the code (`file:line` or a command and its output), the thread and the evidence; every claim about who said, proposed or agreed what against `thread-context.md`, which the reviewer gets as a file.
   - **Noise:**
     - every con or risk names who hits it today (a caller, repo or user), or is cut;
     - write the shortest version that still answers (the verdict, its one reason, the next step); every sentence outside it that the reader wouldn't miss is a finding: mechanism nobody asked for, a justification of a justification, an "anyway" clause. True is not enough;
     - every question is answered; a gap in your own work that a question points at is fixed before the reply, not offered;
     - every absolute word ("every", "unchanged", "always", "only") quotes what proves it, or is cut;
     - maintainer requests are followed, and links are correct.
   - **Convergence** (design threads): the reply states its author's own position and the design's weakest part; a change of position names the new evidence; every open invariant is either a stated default or a question that only the other side can answer, and the questions are as few as that allows.
   - **Opening:** from the opening alone, state the problem and, for a PR, the change (`writing`); inability to do so is a finding.
   - **Reader:** "you have not seen this thread; list every term or sentence you can't understand", and "say in one line what the reader is asked to decide". If the reviewer cannot identify the decision or decisions the reply requires, or finds a pronoun with two meanings, a term or label not yet seen, a sentence to read twice, or a bold label or fragment standing in for a sentence, that's a finding. It must also read as `mergeworthy:writing` says; a finding there means the draft wasn't written that way, so rewrite it, never patch the wording.
   - **The result:** capture only the reviewer's final message (`drafts/<name>.review.out`). Fix every finding and re-review until that message is exactly `CLEAN`.
4. **Right before posting, re-read every claim against the current head** (`git fetch` first; read a PR's state before describing it). Every referenced commit is pushed (`git ls-remote`). Run `gate-pass <abs path>/drafts/<name>.md <review output>` and post with `--body-file` on that absolute path (`gh api … -F body=@<file>` for API posts).
5. **Post in the thread where the person wrote.** Log it.

**Fast gate,** for a reply of a few claims: a "Done in <sha>", or the holding reply of 1.5 with what you found so far. It runs the same steps, with the reviewer asked only about those claims. The reviewer still has to answer exactly `CLEAN`.

### Thread rules

**How a post reads** (voice, budgets, the badge, the notes table, model replies) is `mergeworthy:writing`: open it before drafting. The rules below are about the thread.

- **A maintainer who asks to see how you change this methodology** gets every mergeworthy commit in your next reply in their repos: each in plain words with its link, in a `<details>` block. Write the installed commit to `~/.mergeworthy/harness-shown/<owner>` when they ask; `post-lint` holds each reply there until it shows what came after.
- **At most two comments in a row.** The second is only the 1.5 result after its holding reply, a wait ping, a dependency's progress, a 👎 fix, or the review of commits a maintainer pushed after your last comment; anything else edits your last comment. `pre-bash-guard` blocks a third while your last two have no reply from anyone else and the last is under 3 hours old; after that, the third may be the wait ping.
- **Evidence carries no secret.** In logs, requests, payloads and screenshots, write `<REDACTED>` in place of every token, cookie, auth header and key. Quote only the lines that show the point (`post-lint` fails on common token shapes).
- **One reply per person, edits for corrections.** Several comments from one person get one reply. Correct your earlier post in place through the gate, except the explicit new-reply cases in 1.5 and the second-comment exceptions above.
