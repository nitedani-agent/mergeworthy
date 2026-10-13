---
name: past-failures
description: "When a rule failed or the user names a failure: the table of past failures and the rule that covers each."
---

# Failures that already happened

Each failure below happened, most more than once. When a rule fails or the user names a failure, find its row. A new failure goes in an existing row when one covers its rule; otherwise a new row of at most one line. Either way the rule is fixed (1.1.12).

| What happened | Rule |
|---|---|
| Replies posted unreviewed; correction comments stacked on top; one draft posted twice. | 1.6, `pre-bash-guard` |
| Maintainer comments unanswered for hours (watcher gaps, an expired watch, 👀 then silence); asked why, the agent explained and waited for a go. | 1.5 watcher, 1.1.13, always-on (named failure), `gh-watch-start`, `pre-bash-guard`, `stop-lint` |
| "Good!" read as closing an old point, and left unanswered. | 1.5 acknowledgements, `proposals-open.md` |
| Stale tracker lines and Decisions comment, hours and many merges behind. | 1.2 |
| Red CI noticed by the user. | the watcher's `### CI` events |
| An LGTM'd item still "waiting"; a superseded statement cited. | 1.1.9 |
| Maintainer instructions ignored ("remove the test right before merging"). | 1.7 checkboxes, 1.7 Ready list |
| Briefs pasted from stale copies; a review passed on the author's evidence without a run. | `delegating`, `converge` |
| A subagent started six agents of its own, then ended its turn while they ran; its report never came. | `delegating` (what the agent must not do) |
| Behavior verdicts taken by reasoning, without a run; a bot's opposite "fix" went in within seconds, and a probe showed the reviewer was right. | `review` (behavior is settled by a run), `converge` |
| "Ready" without review, refactor or guardian verdict; fixes pushed to ready PRs unreviewed, a CI result recorded as their review. | always-on 1–3, `pr-steps`, `pre-bash-guard` |
| "Stacked on #N" without `gh stack`. | `writing` links, `post-lint` |
| "Should I…? / your call" on our own recommendation. | 1.1.3, `stop-lint` |
| A modal question answered by accident. | 1.1.3 |
| User questions absorbed into work and never answered. | 1.1.4 |
| Claims from memory, false "can't"s (no browser, a DevTools MCP loaded), work "running" after its agents stopped, a reversed close-the-PR advice. | 1.1.5, `writing` |
| Workarounds shipped as fixes; defects documented as caveats. | 1.1.6, `converge` (phantom and removal gates) |
| Upstream PR for a problem our own hook choice caused. | 1.1.6 |
| A design that sent the payload three times "for now". | 1.1.2 |
| Hooks named against their behavior; options nobody asked for. | 1.1.10 |
| A proposal that pulled in unrelated behavior, with unexplained shorthand. | 1.4 walkthrough |
| PR prose moved into table cells to pass the word ceiling. | `writing`, `post-lint` |
| A design comparison sent as a table; the user needed code. A PR body's decisions sat in long notes-table rows, semver and an export among them; the maintainer: "not have to read Harry Potter … don't defer it to us". | `writing` (a decision block: code, each option's output, our pick), 1.4, `post-lint` |
| Side-PR review rounds while the critical-path feature stayed a prototype. | 1.1.1 |
| "Separate PR" meaning "later"; a 5-minute item deferred twice; a promised PR never opened. | 1.1.7, 1.5 `PROMISED`, `gate-pass` |
| Parts of the task and of an accepted design silently dropped. | 1.1.8 |
| Throughput losses called trade-offs; a `read(n)` that grew the buffer until 20 GB stalled passed 200 MB probes. | 1.1.11 |
| A regression for users of an existing feature called "limitation: experimental"; Room joins past ~100 at once rejected by a retry cap and called a limitation. | 1.1.11, `post-lint` |
| UI bugs found by the user; UI "verified" by computed styles and scripted events; UI built before browser control was tried. | `evidence` (reproduce it as a person would), `pr-steps preflight` |
| A transport fix opened with Node-script evidence only. | `evidence` (reproduce it as a person would) |
| A release unlike the maintainer's past releases. | 1.3 precedent |
| Docs in the agent's voice; repeated "I don't understand"; a coined term. | 1.3, 1.5 |
| A docs section reviewed only for truth: wrong page, every edge case, a dependency's internals, nothing like its sibling pages (vikejs/vike#3557). | `docs` |
| Jargon, AI phrasing, out-of-context replies; replies that only complied or restated. | `writing`, `post-lint` |
| Class-wide bugs got narrow fixes: a query-parser default; a router that didn't decode paths, fixed by an opt-in option rated for Vike from an anchored brief. | 1.5 step 3, `pull-request` step 3 |
| A reply claim no longer true after a revert. | 1.6 step 4 |
| Soft suggestions answered "Done"; the wrong paragraph removed. | 1.5 step 2, `post-lint` |
| Choices handed back that we could settle. | 1.6, `post-lint` |
| A design credited to the maintainer who couldn't recall it. | `writing` credit |
| Review reports and raw rater output posted on PRs. | `writing` process invisible, `post-lint` |
| Over-engineering the maintainer cut (long collision checks, a tiny cache, rare-case docs, lookup tests, most test lines, planner hints after a 250× index fix). | 1.1.15, 1.1.16 |
| A 100-line feature with no user. | 1.1.16 feature list |
| Five new core hooks where an existing extension point sufficed; a diff viewer the named project already had, rewritten; a "reference" project imported. | 1.4 step 0, 1.3, 1.1.8 |
| A panel shipped unreadable. A browser extension went through 30 tickets passing its own frame timings and the orchestrator's glance at 1280 px screenshots. In the user's Chrome, every page still popped in and shifted, and Octave's layers added noise. | 1.1.11 (fresh reviewer, whole page, screencast) |
| Instruction files bloated with rationale and opt-outs. | 1.9 |
| A lesson from one repo repeated in another. | 1.1.12 |
| Work stopped at every rate limit; hundreds of headless browsers; a preview left running for hours. | 1.1.13, 1.8 |
| Shared pnpm store modified, logs overwritten, backups lost in `/tmp`, a colleague's commits force-pushed over. | 1.8, 1.2, `core` (artifact root), 1.7 |
| A subagent's model picked outside `delegating`; global config edited instead of the skill. | `core` (models), 1.1.3 |
| A subagent's design merged without understanding it. | 1.10 |
| Squash merges carrying full PR history. | 1.7, `pre-bash-guard` |
| `ps \| awk '/<port>/'` matched and killed another session's server. | 1.8 |
| Posting with inline bodies; `gh run rerun` on upstream (needs admin: ask a maintainer); fork PRs lack CI secrets, so those jobs fail. | 1.6 step 4, 1.7 CI |
| The watcher started a headless agent per event instead of waking the session that owned the thread; the user saw 👀 and no answer. | 1.5 (the session is the agent, woken by its Monitor), `stop-lint` |
| The agent watched and answered every thread in the scope repos, not only threads it opened or posted in and the user's `/ai` calls. | 1.5 (which comments you answer), the watcher (`watcher/gh-watch.py`), `post-bash-register` |
| Held work while the budget was red with nothing watching it, then only re-armed the watcher. | 1.1.13 (a hold has a Monitor on what lifts it) |
| A type check a sibling PR's validators already covered; the owner called it bloat. | 1.1.16 |
| Two decision issues were filed with text and code references only; the owner couldn't see where in the app the problem was. | `open-issue`, with `evidence` shared by `pull-request`; `post-lint --kind issue` fails without `### How to reproduce` and its evidence. |
| A security fix also changed a legitimate user's flow, which needed the business's decision first. | 1.1.9 and the project file: a fix closes only the hole; a behavior change gets its own issue with options. |
| Branches were pushed and worked on for hours with no PR; GitHub showed them as "no pull request yet", and merged PRs' branches were left behind. | `pull-request` (draft PR with the first push), 1.7 (`--delete-branch` at merge). |
| A symptom behind several clicks got stills; the owner wanted a video. | `evidence`, `post-lint --kind issue` |
| A tool result saying the user doesn't want the action, with no user message after it, was a harness cancellation; the session went idle. | 1.1.13 (a cancellation with no user message after it is re-run) |
| A benchmark regression sent as a GENUINE-FORK, then kept by default. | 1.1.3 (no default on a regression), 1.1.11 |
| Stuck on a fix whose every option regressed, the agent asked the user to pick instead of running the finality pass; the user had to name it. | finality (when to run it), 1.1.3 |
| Phase B branches were about to get the code map and angles phrased in the current design's terms, anchoring them on what exists; the user named it. | finality (Phase B: the clean problem) |
| A reproduced upstream bug with a known location was filed as an issue with tests offered, then a nudge asked the maintainer where the fix should go; the user: "Is it not clear where the bug is?" | 1.1.7: find the fix first and open the PR; an issue only when you can't, and no nudges about one that blocks nothing. |
| The 3-hour wakeup only checked that nothing waited on the session, so the critical path sat still between maintainer replies; the user: "You need to be actively working on making rsc happen." | `github-threads` 1.5, Drive the goal at every wakeup |
| Fifteen mergeworthy pushes in a row left CI red: the tests were run without their argument and a stale `docs/graphs.md` went unnoticed. | `delegating` 1.9, `tests/all.sh` |
| A PR's gates were picked by hand and missed the repo's `test:types`, so a type error rode along for several heads. | `converge`, Gates (the list comes from CI) |
| A PR's head went to `origin`, which was upstream, creating a branch in vikejs/vike; a docs e2e, and a follow-up agent whose brief dropped the port limits, started servers on port 3000 outside the network namespace; a compose stack took host ports another session needed. | `merging` 1.7 (push by the PR's head repository); `core` 1.8 (any test command may start a server; compose stacks, `pre-bash-guard`); `delegating` (every brief carries the safety limits) |
| A research agent ended its own probe script with `pkill -f` patterns, which the hook can't see inside a script. | `delegating` (the safety limits name PID-only kills, scripts included) |
| Wait pings repeated the same open items in new comments; the maintainer: "the aggressive pinging is annoying because you end up repeating yourself". | `github-threads` 1.5, A TODO comment instead of repeated pings |
| A reply told the maintainer "the rule you agreed to" for a design he never agreed to, written from a session summary instead of the thread; he had proposed the opposite days before. | `writing` (Credit), `post-lint` (credit without a link) |
| An upstream PR branch started from a stale fork's main and carried upstream's already-merged commits. | `pull-request` (branch from the target repository's base) |
| Asked an upstream maintainer for a release two hours after a review ping, while the Vike PR that would use it wasn't merged; the user: "Don't ping magne too much unless it's really blocking you." | `github-threads` 1.5, The wait ping (blocking means now) |
| A decision issue recommended the smallest change over the option users want. | `mergeworthy:writing`, How a good colleague writes (recommendations) |
| Agents taken for dead when their turn ended or T3 showed them cancelled, retried (once in the live one's worktree) and killed; the orchestrator blocked on wait loops. | 1.10, `pre-agent-dedupe`, `agent-job`, `pre-bash-guard` |
| Agents lost: runs that ended interrupted or failed and were revived, or wrote their report with no final message, sent no notice; their results went unread for hours, one contradicting a reply already posted. | 1.10 (relay every report), `agent_jobs.py`, the watcher's `### AGENT DONE`, `stop-lint` |
| Under T3 Code, Codex reviews ran as `codex exec` in a shell, invisible to the user. | `review` (start it in the orchestrator), `pre-bash-guard` |
| Design-thread replies chased the latest comment, flipped without evidence, argued from execution cost and left invariants open (the user's too). | `writing` (Design threads), `github-threads` 1.5 step 3, `finality`, `design-loop` (end state first) |
| Replies read like reports: label lines ("Two decisions:"), options described in words instead of code, a bug backlog sent as "holes". | `writing` (draft by talking; the reply that carries the load) |
| A reply to a maintainer was drafted from the agent's memory or a session summary and misstated who agreed to what; the full record also bloats the main session until compaction drops it. | `writing` step 0 (a drafter subagent reads `thread-context.md`), `thread-context`, `gate-pass`, `pre-bash-guard` |
| Design replies restated what was agreed and what was open each time; the maintainer: "I don't like that you repeat again and again (low entropy)". | `github-threads` 1.5, A TODO comment (Agreed, Open); `finality` |
| The orchestrator implemented a review's changes itself; the rule lived only in an on-demand skill. | 1.1.14, reaching every session through always-on.md (no hook) |
| A wait ping restated an open question while the maintainer was pushing to and reviewing the agent's other PRs; brillout: "Harness: don't be pushy (you're repeating yourself)". | `github-threads` 1.5, The wait ping; the watcher's `WAIT PING DUE` |
| Asked to rewrite a PR from scratch, the agent kept parts of the user's old code and then asked their OK to change four of them as owner code; the user: "I asked for a full rewrite. Did not ask to preserve any code of mine." | `converge`, Authority: a rewrite the user asked for replaces all of their code |
| PR bodies ignored `pull-request` step 7's template, written from a recalled skill instead of an opened one; the user: "a wall of cryptic text I can't simply scan". | always-on 1, `pre-skill-gate`, `post-lint --kind pr` |
| After compactions the orchestrator forgot finished work: it rebuilt a finished, gated finality build through four stacked patches and a redo, relaunched research already written up, repeated a stale status for hours, and labeled local times UTC. | 1.2 `memory.md`, `memory-prep`, `session-start`, `pre-agent-dedupe`, `stop-lint` |
| Claude Code cut a 14 KB session-start output to a 2 KB preview, dropping the memory digest and refresh order; `memory.md` fell 21 h behind. | `session-memory`, `stop-lint` |
| 25 of 46 maintainer follow-ups went unsorted; the notes reached 0 of 96 universal-middleware briefs. | `github-threads` (`FOLLOW-UP`), `stop-lint`, `pre-agent-dedupe`, `review` |
