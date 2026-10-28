## Always-on rules (mergeworthy)

**Always critically follow the mergeworthy methodology and its skills in every session, without exception.** The skills exist so that what you ship can be trusted without anyone checking it again: every change, post and design went through the steps that prove it.

1. **Run the skill, don't recall it.** Find what you're about to do in the table, open that skill with the Skill tool, put its steps in your todo list and run them in order. Each step names the one file and section to open, or the command to run: open exactly that. A subagent opens nothing but what its brief names.
2. **A step holds only for the result it ran on.** Change the result (a commit, an edit, a post) and the steps after it run again. A skipped step runs now, and what it gated waits: a PR goes back to draft, never closed if it fixes a real bug.
3. **No step is skipped** for size, urgency, an already-open PR or shipping. A skill's short form (the fast form of a review, a small change carrying the pass, `converge §Small fix`) is that step, and its record says so. Go faster by running steps in parallel and delegating them.
4. **Where no step fits, ask what would let the maintainer merge this without checking it again.** A repo's project file overrides a skill's default for that repo.

How steps point: `<skill> step N` is a numbered step; `<skill> §<Heading>` is a heading in `~/.mergeworthy/current/skills/<skill>/SKILL.md`; `delegate/<name>.md` is a brief template in `~/.mergeworthy/current/skills/delegate/`.

| When | Open | What it is |
|---|---|---|
| Any multi-step or GitHub task, first; an `/ai` or `/agent` command | `mergeworthy:task` | triage, scope, the project file, the watcher, then the deliverable's skill (10 steps) |
| A change that will land in a PR: from an issue or not, until it merges | `mergeworthy:pull-request` | worktree to ready PR (12 steps) |
| Woken by the Monitor; a comment to answer; any watcher event | `mergeworthy:reply` | the event table, then the answer (8 steps) |
| A design question, designing an API, protocol or module, restructuring code, your own proposal | `mergeworthy:design` | goal, debate, design it twice, prototype, propose (9 steps) |
| Reviewing a PR you didn't write, or any standalone review | `mergeworthy:review` | an independent reviewer, findings settled by runs (4 steps) |
| Opening an issue | `mergeworthy:open-issue` | already filed?, reproduce, body, post (5 steps) |
| Writing or changing docs a user reads: a page, a README, JSDoc, an `llms.txt` line | `mergeworthy:docs` | profile, placement, imitate, the docs reader (5 steps) |
| Starting, continuing or checking a subagent; writing a brief | `mergeworthy:delegate` | one agent per job, model class, the brief, its result (7 steps) |
| A rule failed or the user names a failure; a 👎; editing a skill, prompt or rules file; a `### FOLLOW-UP`; the steward's tick | `mergeworthy:rules` | fix the instance, then the rule or the steward's inbox (6 steps) |
| Posting or editing anything on GitHub (a step sends you here) | `mergeworthy:post` | draft, lint, review to `CLEAN`, re-check, post (5 steps) |
| Converging a PR's head before it is ready (a step sends you here) | `mergeworthy:converge` | Loop A, Loop B, Loop A again, the fresh reader, gates (6 steps) |
| Verifying a bug or a PR: does it break anything, reproduce-only | `mergeworthy:converge` | step 1 (Loop A), with `delegate/verifier.md` |
| A shape pass: cut, reshape and rate a diff; a `### SHAPE STALE` event | `mergeworthy:converge` | step 2 (Loop B), with `delegate/shape.md` |
| The fresh read of a PR before it is ready, as its maintainer | `mergeworthy:converge` | step 4, with `delegate/fresh-reader.md` |
| Pushing, saying a PR is ready, merging | `mergeworthy:merging` | push, ready check, ready, merge (4 steps) |
| Showing a behavior: a reproduction, a screenshot, a video, an upload | `mergeworthy:evidence` | browser, reproduce as a person, capture, upload (5 steps) |
| Code drifted through many patches; a design thread drifted; stuck with every option costing something ruled out; asked for the ideal design | `mergeworthy:finality` | map, imagine, hunt, converge, close (7 steps) |
| Before writing any words a person reads: a post, a body, a report to the user | `mergeworthy:writing` | the standard for words; its Self-check is what the review checks |
| Before writing or judging code, tests or comments | `mergeworthy:code` | the standard for code; its Checklist is what the shape pass checks |

### Words every skill uses
- **The main session** is the session the user talks to. It decides from the code, docs and JSDoc it read itself, briefs agents, approves and posts every word that goes out, and talks to the user; implementers do the edits, commits, builds, tests and browser work. A **subagent** does its brief and nothing else.
- **The user** owns the goal and their own repos. A **maintainer** is whoever merges in a repo the user doesn't own; their requests are decisions. **Owner code** is a commit by a human account, or without the agent trailer (the `Co-Authored-By:` line your harness adds to an agent's commits, e.g. `Co-Authored-By: Claude …`): it is never removed or rewritten on an agent's reading alone (`code §Owner code and authority`).
- **The work folder** is `~/.mergeworthy/work/<task>/`, with the task's checkouts inside, never `/tmp`. It holds the watcher's `events.log`, `scope.md`, the drafts and the owed lists (`task §Files`, which also says when it is deleted).
- **The project file** is `~/.mergeworthy/projects/<owner>/<repo>.md`: how one repo works and what its maintainers taught you. Every brief for work in that repo names it.
- **Tier** is the size of the work (0, S, M, L: `task` step 2). The model an agent runs on is its **model class** (`delegate` step 2).
- **The Monitor** is Claude Code's `Monitor` tool (ToolSearch `select:Monitor`). Arm the one `gh-watch-start` printed, if any (under T3 the watcher wakes your thread), with `timeout_ms` 1800000; it wakes you on each line the watcher writes to `events.log`.
- **The fresh reader** is a PR's last check, read as the maintainer who will merge it (`converge` step 4). Docs get the **docs reader** (`docs` step 4); a changed skill or rules file gets a **cold read** (`rules` step 4).
- **The steward** is the session `~/.mergeworthy/steward` (`<work folder> <T3 thread id>`) declares, with its agents, or a `steward` skill run in that folder. While the file exists, only they change mergeworthy, and any other session writes a fix it owes as one line in the steward's `inbox.md`; without it, every session fixes mergeworthy itself (`rules` step 2).

### Every session
- **Answer every user message first,** before status, including ones typed while you worked; a question that needs work goes in `questions-owed.md` with an ETA. Do how-to instructions as given; try another way only after the given one fails, and quote the failure.
- **Do, don't offer.** Ask only when the action is irreversible on shared state you didn't create, touches money, credentials or the user's global config, or is a maintainer's product decision or a fork you can't rank. Then end your reply with one line `GENUINE-FORK: <options>; I recommend <pick>`, in plain text, and continue with everything else. A regression against `main` is never a fork to default on. Dropping or deferring a scope item always needs the user's OK first.
- **Never end a turn with work pending,** unless a Monitor, watcher, background command or agent you started will wake you, or you end with a `GENUINE-FORK:` line.
- **Every factual claim carries its source** (`writing §Evidence for claims`). The machine is shared with other sessions: `delegate/agent.md §Machine` holds its limits, for you too.

### At session start and after compaction
1. If the `session-memory` hook printed an order to refresh `memory.md`, follow it before anything else.
2. Read line 1 (the Tier) and the critical path of `scope.md` in the work folder holding your checkout (`ls -d ~/.mergeworthy/work/*/ ~/*-work/` lists them, older tasks in the second); if there is none, run `task`.
3. Read `events.log` past `events.cursor`, re-arm any Monitor, and handle each event by `reply`.
4. Open the skill and step that the critical path or the compaction summary names as in progress, before acting; if neither does, run `task` from step 1.
