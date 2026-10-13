---
name: mechanisms
description: "Using or fixing the mechanisms that enforce the rules: the watcher, the hooks, gate-pass, post-lint, pr-steps."
---

# Mechanisms

These scripts enforce the rules that failed as text alone.

- **Where they live.** The scripts ship in the mergeworthy plugin: its `bin/` is on the Bash `PATH`, and its `hooks/hooks.json` is active while the plugin is enabled. Hooks run their scripts from `~/.mergeworthy/current` (`hooks/run`); only a changed `hooks.json` needs a restart, which `stop-lint` says once.
- **Changing them.** Edit and propagate from the source repo, leaving installed copies untouched (`delegating` 1.9).
- **The steward.** `~/.mergeworthy/steward` (the user writes it) holds `<watch dir> <T3 thread id>`. You are the steward if that is your T3 thread or your delegator's, or `<watch dir>/session` names your session; only the steward and its agents commit or push to mergeworthy and sort `FOLLOW-UP`s. Any other session writes a mergeworthy fix it owes as one line in `<watch dir>/inbox.md`, read by the steward at every wakeup.
- **Options.** The plugin's options are `badge`, `merge` and `watcher` (`/plugin` → mergeworthy → Configure options). They reach the scripts through `~/.mergeworthy/settings.env`, rewritten at every session start. An environment variable `MERGEWORTHY_<KEY>` wins over the option.

## Commands

### `gh-watch-start` (enforces 1.5)

`gh-watch-start [--main] <dir> [owner/repo [N]]…` is the one way to start watching; running it again is harmless.
- **What it adds.** It adds `owner/repo N` to `<dir>/threads.txt` (the watcher rewrites a hand-written `owner/repo#N` so); for GitLab, `gitlab.com/<path> N`, or `'!N'` for an MR. A bare repo goes to `repos.txt`, which covers it before an issue exists; a thread of that repo joining the dir drops that line.
- **`--main`:** this dir gets the user's `/ai` calls on threads no watcher watches. The default is the first live dir.
- **The supervisor.** It starts the daemon under a supervisor: the systemd user service `gh-watch@<dir>` on Linux, a launchd agent on macOS, else a detached daemon that cron revives.
- **Maintainers.** `GH_WATCH_EYES` names the maintainers whose commits and 👍/👎 are reported; without it, `<dir>/eyes`, else your own login.
- **One watcher per thread.** It refuses a thread another live watch dir already watches.
- **The Monitor.** Arm the printed Monitor so the session wakes and answers events (`github-threads` 1.5).

### `post-lint` (enforces 1.6 and writing 1.11)

`post-lint drafts/x.md --kind reply|pr|issue|inline|tracker|proposal [--repo o/r]` checks a draft before it is posted.
- **A reply** reads its parent comment from `drafts/x.parent.md`. Use `--parent none` when it answers nobody.
- **A draft PR's body** takes `--kind pr --draft`: its first line under the badge must be `**State: draft** (<why>)`; without `--draft` that line is a finding. The guard checks the same line on `gh pr create`.
- **`tracker`** checks the umbrella issue's format: a `Title: Tracking: …` line, `##` sections of checkboxes, no table, the Decisions comment linked (not at creation), a ticked item's end state, and the Decisions comment's sections. Leave tracker posts badge-free (`writing`).
- **The checks**, each where it applies to the kind:
  - **Writing:** banned phrases; sentences over 40 words or averaging over 25, and more than 30% bold (not for `pr`); internal labels like W2; a bold label followed by a fragment; em dashes.
  - **References:** "stacked on"; bare `#N`.
  - **Content:** budgets; unclassified notes; process in the thread; questions without a recommendation; a bare "Done" to a question (`reply`, `inline`); deferrals in the notes table; a ready PR body without `pull-request` step 7's `### What you should see`, its numbered items showing the evidence outside `<details>`.
  - **Safety and form:** secrets; a missing badge, unless the `badge` option says otherwise (not for `tracker`).

### `thread-context` (enforces 1.6 and writing step 0)

`thread-context <owner/repo#N> [--depth 2] [--max 30] [--out <file>]` writes the record a reply is drafted from (default `./thread-context.md`). Run it into the draft folder, and hand it to the drafter and the reviewer, never read it into the main session.
- It fetches the thread's comments, reviews and review comments, and the threads they reference, breadth-first to `--depth`, at most `--max` threads, skipping bots.
- The file holds a header, a **Decisions and positions** ledger (each human comment that agrees, rejects, proposes or decides, quoted with its permalink), the root's full transcript, then each linked thread's first post and last 30 comments. The agent's posts are marked `AGENT` and kept out of the ledger.
- `--latest <repo#N>` prints the latest human comment; `--verify <file> [--target <repo#N>] [--parent <file>]` is what the gate and the guard run.

### `gate-pass` (enforces 1.6)

`gate-pass <abs>/drafts/x.md <review output> [post-lint flags]` records that a draft passed the gate.
- It re-runs `post-lint` with the draft's last flags, checks that the review's final message is exactly `CLEAN`, and records the draft's sha256 in `<draft>.gate`.
- A `reply`, `inline` or `proposal` draft needs `thread-context.md` in its folder, newer than its `.parent.md`, recording a latest human comment (`thread-context --verify`).
- A `thread-context.md` beside the draft must be older than its last edit; posting refuses one regenerated after the gate.
- When `~/.mergeworthy/harness-shown/<owner>` exists, it appends to a `reply` or `proposal`, after the review, a link comparing the mergeworthy commit it names with the installed one, and records the installed one there.
- A draft that promises work ("I'll", "follow-up PR") first needs a `PROMISED … (<draft name>)` line in `proposals-open.md`.

### `review-context`

`review-context <base-ref> [--max-refs N]` prints, for the symbols a diff changes, who calls them, what they call and which names the diff removes. Run it in the repo at the reviewed head and paste its output into the reviewer's prompt.
- For each changed symbol it lists its callers by file (at most `--max-refs`, default 15) and the in-repo functions it calls.
- For each top-level name the diff removes it lists the remaining `git grep` hits at HEAD (dangling callers) under `### removed: name`.
- It never blocks: a failure or timeout (60 s) prints `review-context: failed (<reason>); no context` and exits 0.

### `loc-breakdown`

`loc-breakdown <base>..<head> <map file> [--repo-dir DIR]` prints a markdown table of the lines each feature changed. The map has lines `<feature>\t<path>[:<start>-<end>]`: a head range for added lines, `<path>:base:<start>-<end>` for removed lines, a bare path for the whole file.
- Docs, Tests, Lockfile and Generated are rows of their own, recognized by path or assigned in the map.
- It exits 1, listing the lines, when a changed line is in no entry or in two.

### `memory-prep` (enforces 1.2)

`memory-prep init <root> <T3 thread id>`, run from the orchestrator's checkout, records it, its thread, its session and its session-log dir. `memory-prep prep <root>` extracts the user's prompts and the last text of each orchestrator turn logged after `memory.md`'s `covered-until` position from the orchestrator's own logs into `memory-new.txt`, and writes the brief sending one Haiku to `memory-refresh`. `memory-prep digest <root>` prints the Standing part, one line per item, capped at 7,500 characters.

### The finality trigger (`pre-bash-guard`, `post-bash-register`)

`post-bash-register` counts each posted `--kind proposal` draft per thread in `~/.claude/proposal-rounds.txt`. Before the third proposal, refresh the thread map with its invariants (`finality`, When to run it) and update the thread's WIP comment from it (`github-threads`).

### `pr-steps` (enforces 1.7)

`pr-steps <step> <output>` checks a step's output and records it, one file per step:
- `preflight`, per repo and branch: `<app URL> [Chrome flags]` (screenshotted headlessly; an error or blank page fails), a fresh browser-MCP PNG, or `'none, because <why>'`. Edits in its work tree and `git commit` wait for it.
- `approach`, per repo and branch: a table `| Candidate | Rating | Why |` of at least two candidates rated 0–10 and a line `Chosen: <candidate>` rated 7 or more (`pull-request`, step 3).
- `verify`: trailing `NO BUGS`.
- `reverify`: trailing `NO BUGS`, or `NO LOOP B COMMITS` when none landed (`converge`, step 3).
- `loopb`: captured final message `CLEAN` (`review`).
- `fresh`: `MERGE AS IS: yes` and trailing `CLEAN` (`converge`, step 4).
- `refactor`: ✅ list and ratings, or `carries the pass of <sha>` with ≤ 80 changed lines.
- `gates`: `<command> -> exit 0` lines.
- `gh pr create`/`glab mr create` (unless `--draft`/`--wip`), `gh pr ready`/`glab mr update --ready` and a push to a ready PR are blocked until HEAD has all six and the branch has its `approach` record.

## The watcher daemon: `watcher/gh-watch.py` (enforces 1.5)

The daemon reports to `<dir>/events.log` and never starts an agent.
- **Comments.** Answer reported comments from the owed list; reactions follow the detection schedule (`github-threads` 1.5).
- **Thread events.** On watched threads it reports pushes, merges and closes (`### PR CHANGED`), CI results (`### CI`), and 👍/👎 on the agent's comments (`### THUMBS UP` / `### THUMBS DOWN`). GitLab threads get only comments, an MR's `### PR CHANGED` and `### CI`, and an issue's `### ISSUE CHANGED`.
- **Other events:**
    - `### ACK`: an acknowledgement that answers your last open proposal;
    - `### MAINTAINER COMMITS`: commits a maintainer pushed to your PR;
    - `### TRACKER STALE`: a PR merged or closed, and the umbrella issue named in `<dir>/umbrella.txt` doesn't show it ticked with that state;
    - `### REFACTOR STALE`: a PR's code changed by more than ~80 lines since its last `pr-steps refactor`;
    - `### DEPENDENT of merged …`: a PR listed in `waiting-on.txt` merged;
    - `### AGENT DONE <ticket>`: an agent the session launched finished (`agent_jobs.py`: its transcript went quiet), once per finish until `agent-job done`; the dir is the one whose `session` file names the launcher, or whose `events.log` the launcher's transcript tails;
    - `### FOLLOW-UP`: for 60 days after one of your watched PRs merges, a commit by someone else (not a merge) that changes lines the PR changed, or renames or removes its files, and another person's PR that references it, each once, with its time. A commit touching several of your PRs is one line naming them all. While the steward's watcher runs, its dir gets these instead, plus a copy of each `MAINTAINER COMMITS`, which the PR's session still handles. A commit counts within 3 lines of the PR's lines at the merge. Bots' commits and hunks that only bump dependency versions don't count. Read each as `core` 1.3 says (Learning from follow-ups).
- **`/agent` commands.** Your comment starting with `/agent` on a thread no live watch dir lists is found in the recent comments of every repo a live watch dir lists, or by a search of your comments. It goes once to one dir's `events.log` as `### AGENT COMMAND`, and the thread joins that dir's `threads.txt`: to the dir named by `/agent <folder name>`, else to the dir listing a thread this one links to or is linked from (most matches), else to the `--main` dir as `### UNROUTED /agent`.
- **Retiring.** It retires itself, service, launchd agent and cron lines included, once every thread is merged or closed and `repos.txt` is empty.
- **API budget.** All watchers share one account's 5,000 calls an hour through `~/.mergeworthy/shared-watch.json`. Below 1500 calls left, the jobs one daemon runs for all (finding `/agent` comments, `FOLLOW-UP`s) wait for the reset while each daemon reads its own threads; below 500, only GitHub's notifications feed and the threads it names are read; after a rate-limit answer every daemon waits and prints one `WATCH ERROR API budget: paused until <time>`.
- **Cadence and state.** An open thread changed in the last day is checked every 5 minutes, other open threads every 30, merged or closed ones every 6 hours; the rest is in `gh-watch.py`'s header. Restarts and plugin updates lose nothing and cost no calls. The same `WATCH ERROR` is printed once an hour.

## Hooks

### `pre-bash-guard.py` (enforces 1.6, 1.7, 1.8)

It blocks:
- a `gh` post or edit whose body isn't a gated draft, or changed since its gate (use absolute draft paths);
- opening an issue or PR (`gh` or `glab`) in a repo no running watcher covers;
- the same gated draft posted twice as new;
- a post or edit on a thread whose draft folder has no `thread-context.md` for that thread recording its current latest human comment, or older than the draft's parent. `--kind tracker` drafts and new issues and PRs are exempt;
- a third comment on a thread (1.6 states the condition);
- `gh pr merge` without `--squash --subject "<title> (#N)" --body ""`, and with `merge=reviewer`, every merge;
- `--delete-branch` while PRs are based on the branch;
- a `git commit` whose author isn't the pushing GitHub account (1.7);
- `docker compose up` (or `run --service-ports`) publishing a fixed host port or a `container_name`, unless prefixed `MERGEWORTHY_HOST_PORTS=user-asked`;
- `codex exec` when T3 Code started the session (`review`: `delegate_task`);
- `pkill -f` and `killall`;
- `kill` of a running agent's process: stop an agent through its task, after reading its status;
- a foreground wait loop (`until`/`while` with `sleep`);
- a bare `git stash`;
- a force-push without a pinned lease;
- with a steward declared, a `git commit` or `git push` in a mergeworthy checkout by any session but the steward and its agents.

### `post-bash-register.py` (enforces 1.5)

It adds a thread you just opened or posted in (its `gh` or `glab` URL) to your session's watch dir, else one covering its repo.

### `stop-lint.py` (enforces 1.1.3, 1.5)

It blocks ending a turn when:
- it ends with "want me to / should I / your call…" and no `GENUINE-FORK:` line;
- you posted on GitHub and no live Monitor watches a watcher's `events.log` (a `claude -p` run's caller watches);
- a watch dir it worked in owes a reply;
- in a session that started T3 tasks, its `Running:` list wasn't read with `task_status` since the user's last message, or names a terminal task.
- an agent it launched finished and its job is still open (`agent_jobs.py`);
- a `FOLLOW-UP` in the `events.log` of a dir it works in, or the steward's, has no verdict after 30 minutes (`github-threads`);
- at most once an hour, `memory.md` is behind the session log and covers nothing from the last 2 hours: it repeats the refresh order (`core` 1.2).

It skips its watcher checks and the refresh order while the user's last message says "pause". Each turn's first stop also gets a check-in: work to start, or anything waiting?

### `session-start` (enforces the always-on rules)

It puts the always-on rules into context and writes `settings.env`. A second SessionStart hook, `session-memory.py`, prints, in an orchestrator's checkout, the order to refresh `memory.md` when it is behind, then its Standing digest. `session-start` also points `~/.mergeworthy/current` at the installed version.

### `pre-skill-gate.py` (enforces always-on rule 1)

It blocks an action until every skill its always-on row names was opened with the Skill tool, or typed as `/mergeworthy:<name>`, since the session's last compaction; a subagent counts only its own. The block names each skill and its row.
- `gh pr create` and `gh pr edit`: `pull-request`, `writing`; `gh pr ready` adds `merging`.
- `gh pr merge` and `git push`: `merging`.
- A comment, reply, review or body edit (`gh api` writes included, reactions not): `github-threads`, `writing`. `gh issue create`: `open-issue`, `writing`.
- `post-lint` and `gate-pass`: `writing`. `pr-steps <step>`: `converge` and the step's own skill (`approach`: `pull-request`).
- Starting an agent (`Agent`, `delegate_task`, `codex exec`, `claude -p`), or editing a skill, a prompt, a brief or a rules file: `delegating`.

Read-only commands pass.

**`pre-agent-dedupe`** registers launches that ran by ticket and blocks duplicate jobs (`delegating` 1.10). A `clientRequestId` may retry within ten minutes; later reuse is blocked. It also blocks:
- a brief with any role but `research` or `test` that names a repo (`owner/repo`, its URL or a path in its checkout) but not its existing `~/.mergeworthy/projects/<owner>/<repo>.md`;
- a brief naming a linked worktree (not the launcher's own) that a process has as its cwd or an agent transcript written in the last five minutes names;
- a brief pinning an older commit of a linked worktree it names, printing `memory.md`'s Ruled out list;
- in an orchestrator's checkout, a research brief (`role: research`, or research in its title) without a `Topic:` line, or whose topic words all appear in a file under the artifact root not named in a `Checked:` line.

### `netns-run`

`netns-run <command...>` runs the command in a private network namespace (`unshare -rn`) with internet access through slirp4netns: ports inside are its own, DNS and HTTPS work, and the command's exit status comes back. It needs `slirp4netns` installed (`sudo apt install slirp4netns`).
