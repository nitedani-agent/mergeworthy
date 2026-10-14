---
name: task
description: "Load first for any multi-step or GitHub task, and for an `/ai` or `/agent` command: triage, scope, the project file, the watcher, then the skill for the deliverable."
---

# Task

From a request to the skill that delivers it. Each step names what to open or run and what it leaves behind (its record); the hooks named check that record.

## Steps

1. **Read the task and every link in it,** recursively: issues, PRs, review comments, commits, CI. Pull the default branch. Look for open PRs and other sessions' work folders on the same thing.
   Run: `gh issue view`, `gh pr list --state all --search "<keyword>"`, `ls ~/*-work`
2. **Triage.** Write `Tier: <0|S|M|L>, because <signals>` as line 1 of `<work folder>/scope.md`, and in your first report. Count every PR, repo and decision maker the work has had so far, not only today's ask: two or more repos or decision makers make it Tier L. Re-triage when the deliverables or open decisions change, and say so.
   Open: §Tiers · Record: scope.md line 1 · Hook: pre-design-gate reads it
3. **Scope.** Copy every ask and link of the task into scope.md as checkboxes, at the start and whenever the user adds one; below them the critical path: the open items between now and the goal shipping, in order. Dropping or deferring any item needs the user's OK first, never after.
   Open: §Scope · Record: scope.md
4. **The project file.** Read `~/.mergeworthy/projects/<owner>/<repo>.md`. Missing: run the repo study now (§Repo study), and say so in your report.
   Open: §Project file; §Repo study · Record: the file · Hook: pre-agent-dedupe (a brief for that repo names it)
5. **The watcher.** Unless the plugin's `watcher` option is `off` (§Files): `gh-watch-start <work folder> <owner/repo>`, then arm the Monitor it prints with `timeout_ms` 1800000. Every thread you open or post in joins it (the hooks add it).
   Record: `threads.txt`, `repos.txt` · Hook: pre-bash-guard (no issue or PR in a repo no watcher covers), stop-lint (no live Monitor after a post)
6. **Prior art and precedent.** Tier M or L, or any new API: research into `<work folder>/prior-art.md` (at least 10 searches and 20 pages read, every project the user names in full, peers and upstream at pinned versions); use their approach where it fits. Before a release, a migration, or any repo task done at least 5 times before (a version bump, a changelog, a dependency update): `<work folder>/precedent.md` from its last 5 instances (commit messages, bump types, tags, commands, order), followed exactly; any difference is a question with a recommendation.
   Record: prior-art.md, precedent.md · Hook: pre-design-gate (Tier M/L: no code before prior-art.md)
7. **Tier L: the umbrella issue** and its Decisions comment, before the first PR, through `post` with `--kind tracker`; write `owner/repo N` to `<work folder>/umbrella.txt`.
   Open: §Umbrella · Record: umbrella.txt · Hook: post-lint `--kind tracker`; the watcher's `### TRACKER STALE`
8. **Memory.** Work that spans a compaction or a day: `memory-prep init <work folder> <T3 thread id>` once, from your checkout (the id from `t3_thread_list`; skip outside T3 Code). At each start and compaction the `session-memory` hook prints the Standing part of `memory.md` (rulings, ruled out, superseded, still intended), and an order to refresh it when it covers less of this session's log than exists.
   Record: memory.md · Hook: session-memory, stop-lint (repeats the order hourly)
9. **Go to the deliverable's skill:** a change → `pull-request`; a design question or proposal → `design`; a comment to answer → `reply`; a review of someone else's PR → `review`; an issue → `open-issue`; docs alone → `docs`; a plain answer or research (Tier 0) → answer it by `writing §Reports to the user`. Each agent and PR you start names the critical-path item it unblocks (`delegate §Brief`).
   Hook: pre-skill-gate
10. **Finish:** the final report walks scope.md's checkboxes.
   Open: `writing §Reports to the user`

### Tiers

| Tier | Signals | Records |
|---|---|---|
| **0: Answer** | An answer, research or a review; nothing to change. | scope.md |
| **S: Single fix** | One bounded fix in one repo, expected behavior already clear. | scope.md; the PR body is the record of what the loops found, true of the final head |
| **M: Feature or set** | A new capability, a changed public contract, several change units, or open behavior questions. | scope.md, ledger.md, prior-art.md, decisions/*.md |
| **L: Program** | Changes across two or more independently maintained repos, or two or more decision makers. | Tier M, plus the umbrella issue |

The tier changes the records, never the steps: every PR runs `converge`.

### Scope

- **User decisions stay decided.** Mark a setting or design the user decided where it lives (`# user decision <date>: <what, why>`); a session that never saw the decision reads the marker, not the chat. If you find a problem with it, keep it and report the problem with evidence. If a recorded decision turns out not to work, ask with the blocker's evidence and your recommendation before building the alternative.
- **A broken premise** (e.g. "one PR per item" when the items depend on each other): say so with a recommendation before acting.
- **Read an instruction for its purpose, not its letter:** restate in your next reply what it covers and the nearest thing it leaves out ("reference" is not "import"), and ask only when that edge isn't clear.

### Files

The work folder (`<task>-work/` next to the worktree) holds, each with the step that writes it:
- `scope.md` (steps 2–3); `ledger.md`, Tier M: one row per event (time | unit | event | head SHA | result): each pass, round, fix with its commits, gate run with its exit code, push and CI result; answer every status question from it, skipped steps included.
- `drafts/<thread>/` (`post` step 1); `maps/`, `decisions/` (`design`); `prior-art.md`, `precedent.md` (step 6); `memory.md` (step 8).
- The watcher's files: `events.log` and your `events.cursor` (`reply` step 1), `threads.txt`, `repos.txt`, `umbrella.txt`, and `waiting-on.txt`: each thing a PR of yours waits on, as `<owner/repo#N> -> <dependent>: <what to do>`, also in that PR's notes table.
- **The owed lists,** each cleared only by the thing named:
  - `replies-owed.md`: every comment you answer (the watcher writes it). Cleared by `done: <reply URL> <what changed>`; a holding reply makes it `holding: <reply URL> <ETA as an ISO time>`; while a drafter works, `drafting: <comment URL> <ETA>`.
  - `proposals-open.md`: every "OK?" you ask, and every promise you post as `PROMISED <thread>: <what> (<draft file name>)`. Each new maintainer comment is checked against it first. Cleared by the commit or link that delivers it.
  - `questions-owed.md`: each user question that needs work, with an ETA.
- Log and artifact names include a unique pass ID; never overwrite another pass's file.

The plugin's options (`/plugin` → mergeworthy → Configure options; an environment variable `MERGEWORTHY_<KEY>` wins): `badge` (`on`, `off`, or `auto`: only when the posting account is not a bot), `merge` (`reviewer`: never merge yourself), `watcher` (`off`: no watcher).

### Project file

`~/.mergeworthy/projects/<owner>/<repo>.md`, the one per-repo file: how the repo works and what its maintainers taught you, beyond its `AGENTS.md` / `CLAUDE.md`. Default branch: `<base>`. Keep each section to what an agent would otherwise get wrong; delete a section with nothing to say; update an entry instead of adding a near-duplicate, and delete one a later change contradicts.
- **Gates:** the commands that must exit 0 before a PR, where to run them and how long they take. Locales, if any.
- **What already guarantees things:** validation layers, generated type shields, authorizers, schema constraints, each with its file and function.
- **Security surfaces:** what is publicly reachable, how auth is checked per call, rate limiting, where admin actions and secrets live, which changes are a team decision.
- **Issue tracker:** anything that makes `git log --grep <issue>` miss (a migrated tracker, different numbering in commits).
- **PR conventions:** labels, title format, required reviewers, changeset or changelog expectations.
- **Feature-scale precedent:** how bigger changes have landed before, with an example.
- **Running the app:** *Preflight*: one command that checks everything the app needs and prints every failure together, plus install commands for what doesn't need root. *Start*: an isolated copy that disturbs nobody (a compose override with Docker-assigned ports, derived into the work folder when the repo has none), and how to tell it is ready (the HTTP status). *Drive it*: URLs, test accounts, seed data, how to reach the screen an issue is about. *Stop*: how to tear it all down, including after an abort.
- **Who decides:** who merges PRs and who wrote most of each area, with the link to the repo study.
- **Docs voice** (`docs` step 1), **Agents** (a model class every agent for this repo uses), **Conventions**, **Maintainer preferences**, **Recurring misses**, **What worked**: each line with the link that shows it (`rules` step 6).

### Repo study

Writes a missing project file from the repo's own record, every line quoted or linked:
- **The base and the gates:** the base branch from `gh repo view --json defaultBranchRef`; the gates from the CI workflows and package scripts; running the app from the README and the contributing guide.
- **Who decides:** who merged the last 100 PRs and who wrote most of the code each area holds (`gh pr list --state merged --limit 100 --json number,author,mergedBy`; `git shortlog -sn origin/<base> -- <area>`).
- **What they ask for:** every review and comment those people left on the last 30 merged or closed outside PRs (`gh api repos/<owner>/<repo>/pulls/<N>/comments`, `gh pr view <N> --comments`), sorted into what they ask for, cut and rewrite, each with its link, into the project file's sections.
- The full study (the data and every quote) goes to `<work folder>/repo-study.md`, linked from `## Who decides`.

### Umbrella

An issue titled `Tracking: <goal>`, plus one live **Decisions comment** on it, both edited in place through `post` (`--kind tracker`). Every line has a source link. Use the issue the user names, or turn the program's own issue (an audit, a plan) into the umbrella; open a new one only when neither exists. Every PR opened after it goes on it in the same step.
- **Body.** One sentence on what it tracks and what has to land, then `All decisions made so far: <Decisions comment link> (kept up to date).` Then sections by theme, each a checkbox list, one line per PR or issue: `- [x] owner/repo#N (merged, released in X): <what a user hit on main>. <why it's needed here>`. States: merged, not yet released, ready for review, in review, closed (struck through, with why). Work with no PR yet gets its own line saying what it waits on. Problems found later join the section their kind belongs to; never a section per round. No tables; long content goes in its own comment, linked.
- **Decisions comment.** `## Decisions`, then `Every decision so far, with its source. Kept up to date by editing this comment; the newest statement wins.`, then `### Process and requirements`, `### Agreed` and `### Open` (each open item with your recommendation). Each line ends with who said it and the link. No PR states.
- **Update both in the same step as every event.** A new decision strikes through, with its link, every older entry it replaces. A forward-looking line ("waiting on Y") names the event that removes it; remove it when that fires. Program-wide status lives only here; a PR body keeps only its own notes table. When a decision replaces a design, update every surface that still describes the old one (code, tests, types, docs, open PR bodies) in the same step.

### Dispositions

Exactly one disposition per defect you find, in or out of scope: fixed in this change, a PR opened now (on the umbrella if there is one), or an issue (`open-issue`) only when there's no umbrella and the defect is unrelated. A maintainer's product decision (`code §Owner code and authority`) always gets its own decision issue, linked from the umbrella if there is one. "Mentioned" is never a disposition.
- **"A separate PR" means started now,** alongside. A PR that replaces another closes the old one, with a link, in the same step.
- **Upstream:** find the fix, decide where it belongs, and open the PR; file an issue only when you can't find a fix, and nudge nobody about one that blocks nothing.
- **The same defect in a sibling** (another adapter, another call site) is fixed in this change, a public API change included, and the PR states that change.
- **A quick win** (small, no breaking change, even upstream, even when it blocks nothing) is started the same turn, as its own commit or PR. A reply that says you'll do it "later" defers it; wait only on a dependency or decision you name.
- **Count lines before deferring anything.** An item under ~20 lines that is neither a user-visible fix nor a defect on `main` goes in this PR; otherwise it gets its own PR, now. "It can be added later" is never a reason.

### Drive

Each time you are woken (a Monitor event, an agent's notice, or the scheduled check), the first critical-path item of scope.md (Tier L: the umbrella) moves before any side work: the code, the PR, or the reply that converges its thread. Side work (a quick win, an upstream fix) is welcome, then back to the critical path; porting, tracker polish and optional improvements wait while the path waits on someone else.
- **Never stall.** While any wait exceeds 10 minutes, at least one independent item is in flight; if none exists, say why. A long job gets a Monitor on its failure signals (its process exiting, errors, no progress), not only a completion notice.
- **A hold names the signal that lifts it** (a usage limit's reset time, a release) and a Monitor on it; when it fires, resume without asking. Re-arming the watcher's Monitor doesn't count as resuming the held work. After a usage limit, resume each agent it stopped through its own thread.
- **A tool result saying the user doesn't want the action,** with no message from the user after it (only a notification), is the harness cancelling the call: re-run it.
- A pending task whose condition is met is done now.
