---
name: mechanisms
description: "Using or fixing the mechanisms that enforce the rules: the watcher, the hooks, gate-pass, post-lint, pr-steps."
---

# Mechanisms

These scripts enforce the rules that failed as text alone.

- **Where they live.** The scripts ship in the mergeworthy plugin: its `bin/` is on the Bash `PATH`, and its `hooks/hooks.json` is active while the plugin is enabled. They update with the plugin.
- **Changing them.** Edit and propagate from the source repo, leaving installed copies untouched (`delegating` 1.9).
- **Options.** The plugin's options are `badge`, `merge` and `watcher` (`/plugin` → mergeworthy → Configure options). They reach the scripts through `~/.mergeworthy/settings.env`, rewritten at every session start. An environment variable `MERGEWORTHY_<KEY>` wins over the option.

## Commands

### `gh-watch-start` (enforces 1.5)

`gh-watch-start [--main] <dir> [owner/repo [N]]…` is the one way to start watching; running it again is harmless.
- **What it adds.** It adds `owner/repo N` to `<dir>/threads.txt`; for GitLab, `gitlab.com/<path> N`, or `'!N'` for an MR. A bare repo goes to `repos.txt`, which covers it before an issue exists; a thread of that repo joining the dir drops that line.
- **`--main`:** this dir gets the user's `/ai` calls on threads no watcher watches. The default is the first live dir.
- **The supervisor.** It starts the daemon under a supervisor: the systemd user service `gh-watch@<dir>` on Linux, a launchd agent on macOS, else a detached daemon that cron revives.
- **Maintainers.** `GH_WATCH_EYES` names the maintainers whose commits and 👍/👎 are reported; without it, `<dir>/eyes`, else your own login.
- **One watcher per thread.** It refuses a thread another live watch dir already watches.
- **The Monitor.** Arm the printed Monitor so the session wakes and answers events (`github-threads` 1.5).

### `post-lint` (enforces 1.6 and writing 1.11)

`post-lint drafts/x.md --kind reply|pr|issue|inline|tracker|proposal [--repo o/r]` checks a draft before it is posted.
- **A reply** reads its parent comment from `drafts/x.parent.md`. Use `--parent none` when it answers nobody.
- **A draft PR's body** takes `--kind pr --draft`: its first line under the badge must be `**State: draft** (<why>)`; without `--draft` that line is a finding. The guard checks the same line on `gh pr create`.
- **`tracker`** checks the umbrella issue's format: a `Title: Tracking: …` line, `##` sections of checkboxes, no table, the Decisions comment linked (not in the issue's creation, which precedes it), a ticked item's end state, and the Decisions comment's sections. Leave tracker posts badge-free (`writing`).
- **The checks**, each where it applies to the kind:
  - **Writing:** banned phrases; sentences over 40 words or averaging over 25, and more than 30% bold (not for `pr`); internal labels like W2; a bold label followed by a fragment; em dashes.
  - **References:** "stacked on"; bare `#N`.
  - **Content:** budgets; unclassified notes; process in the thread; questions without a recommendation; a bare "Done" to a question (`reply`, `inline`); deferrals in the notes table; a ready PR body without `pull-request` step 7's `### What you should see`, its numbered items showing the evidence outside `<details>`.
  - **Safety and form:** secrets; a missing badge, unless the `badge` option says otherwise (not for `tracker`).
  - **Methodology changes asked for** (`reply`, `proposal`): when `~/.mergeworthy/harness-shown/<owner>` exists, every mergeworthy commit since the one it names must appear in the draft. `gate-pass` then records the installed commit there.

### `thread-context` (enforces 1.6 and writing step 0)

`thread-context <owner/repo#N> [--depth 2] [--max 30] [--out <file>]` writes the record a reply is drafted from (default `./thread-context.md`). Run it into the draft folder, and hand it to the drafter and the reviewer, never read it into the main session.
- It fetches the thread's body, issue comments, PR review comments and review bodies, each with author, time and permalink, and every thread they reference (`owner/repo#N`, bare `#N`, github.com URLs), breadth-first to `--depth`, at most `--max` threads, skipping bots.
- The file holds a header (root, `latest-human-comment`, threads included), a **Decisions and positions** ledger (one line per human comment with agreement, rejection, proposal or decision language: date, author, tags, quote, permalink), the root's full transcript, then the linked transcripts (first post and last 30 comments). The agent's posts (the `claude.png` badge) are marked `AGENT` and kept out of the ledger.
- `--latest <repo#N>` prints the latest human comment; `--verify <file> [--target <repo#N>] [--parent <file>]` is what the gate and the guard run.

### `gate-pass` (enforces 1.6)

`gate-pass <abs>/drafts/x.md <review output> [post-lint flags]` records that a draft passed the gate.
- It re-runs `post-lint` with the flags the draft last passed with (stored in `<draft>.lint`).
- It checks that the review's final message is exactly `CLEAN`.
- It records the pass as the draft's sha256 in `<draft>.gate`.
- A `reply`, `inline` or `proposal` draft needs `thread-context.md` in its folder, newer than its `.parent.md`, recording a latest human comment (`thread-context --verify`).
- When `thread-context.md` sits beside the draft, it must be older than the draft's last edit, and its hash goes into the gate record; posting refuses one regenerated after the gate.
- A draft that promises work ("I'll", "follow-up PR") first needs a `PROMISED … (<draft name>)` line in `proposals-open.md`.

### `review-context`

`review-context <base-ref> [--max-refs N]` prints, for the symbols a diff changes, who calls them, what they call and which names the diff removes. Run it in the repo at the reviewed head and paste its output into the reviewer's prompt; it costs no model tokens.
- For each changed function, method, class, arrow function, exported const, interface or type it lists the callers grouped by file (test files tagged `[test]`, capped at `--max-refs`, default 15) and the in-repo functions it calls.
- For each top-level name the diff removes it lists the remaining `git grep` hits at HEAD (dangling callers) under `### removed: name`.
- It never blocks: on a failure or timeout (60 s, `--timeout SECONDS`) it prints `review-context: failed (<reason>); no context` and exits 0. Output is capped at about 400 lines.

### `loc-breakdown`

`loc-breakdown <base>..<head> <map file> [--repo-dir DIR]` prints a markdown table of the lines each feature changed (`pull-request`, the PR body). The map has lines `<feature>\t<path>[:<start>-<end>]`: a head range for added lines, `<path>:base:<start>-<end>` for removed lines, a bare path for the whole file.
- Docs (one row, one number), Tests, Lockfile and Generated are separate rows and not features; docs, tests and lockfiles are recognized by path, and the map can assign any path to those names.
- It exits 1 and lists the lines when a changed line is in no entry or in two, so the totals equal `git diff --numstat`. `post-lint` doesn't count the table in a PR's word budget.

### `memory-prep` (enforces 1.2)

`memory-prep init <root> <T3 thread id>`, run from the orchestrator's checkout, records it, its thread, its session and its session-log dir (`~/.claude/projects/<checkout path, non-alphanumerics as dashes>`). `memory-prep prep <root>` extracts the user's prompts (no skill bodies, hook feedback, notifications or compaction summary) and the last text of each orchestrator turn logged after `memory.md`'s `covered-until` position (the first time, the last 24 hours), from the orchestrator's own logs (init ran there, or a prompt names the thread), into `memory-new.txt`, and writes the brief sending one Haiku to `memory-refresh`. `covered-until` never counts past the last chunk noted in `memory-notes.txt`. `memory-prep digest <root>` prints the Standing part, one line per item, capped at 7,500 characters.

### The finality trigger (`pre-bash-guard`, `post-bash-register`)

`post-bash-register` counts each posted `--kind proposal` draft per thread in `~/.claude/proposal-rounds.txt`. Before the third proposal, refresh the thread map with its invariants (`finality`, When to run it) and update the thread's WIP comment from it (`github-threads`).

### `pr-steps` (enforces 1.7)

`pr-steps <step> <output>` checks a step's output and records it, one file per step:
- `preflight`, per repo and branch: `<app URL> [Chrome flags]` (screenshotted headlessly; an error or blank page fails), a fresh browser-MCP PNG, or `'none, because <why>'`. Edits in its work tree and `git commit` wait for it.
- `approach`, per repo and branch: a table `| Candidate | Rating | Why |` of at least two candidates rated 0–10 and a line `Chosen: <candidate>` rated 7 or more (`pull-request`, step 3).
- `verify`: trailing `NO BUGS`.
- `reverify`: trailing `NO BUGS`, or `NO LOOP B COMMITS` when none landed (`converge`, step 3).
- `loopb`: captured final message `CLEAN` (`review`).
- `fresh`: `MERGE AS IS: yes` and trailing `CLEAN`; keep the posting verdict in a separate file (`converge`, step 4).
- `refactor`: ✅ list and ratings, or `carries the pass of <sha>` with ≤ 80 changed lines.
- `gates`: `<command> -> exit 0` lines.
- `gh pr create`/`glab mr create` (unless `--draft`/`--wip`), `gh pr ready`/`glab mr update --ready` and a push to a ready PR are blocked until HEAD has all six and the branch has its `approach` record.

## The watcher daemon: `watcher/gh-watch.py` (enforces 1.5)

The daemon reports to `<dir>/events.log` and never starts an agent.
- **Comments.** Answer reported comments from the owed list; reactions follow the detection schedule (`github-threads` 1.5).
- **Thread events.** On watched threads it reports pushes, merges and closes (`### PR CHANGED`), CI results (`### CI`), and 👍/👎 on the agent's comments (`### THUMBS UP` / `### THUMBS DOWN`). GitLab threads (`glab`, each minute while open and changed today) get only comments, an MR's `### PR CHANGED` and `### CI`, and an issue's `### ISSUE CHANGED` (closed or reopened).
- **Other events:**
    - `### ACK`: an acknowledgement that answers your last open proposal;
    - `### MAINTAINER COMMITS`: commits a maintainer pushed to your PR;
    - `### TRACKER STALE`: a PR merged or closed, and the umbrella issue named in `<dir>/umbrella.txt` doesn't show it ticked with that state;
    - `### REFACTOR STALE`: a PR's code changed by more than ~80 lines since its last `pr-steps refactor`;
    - `### DEPENDENT of merged …`: a PR listed in `waiting-on.txt` merged;
    - `### AGENT DONE <ticket>`: an agent the session launched finished (`agent_jobs.py`: its transcript went quiet), once per finish until `agent-job done`; the dir is the one whose `session` file names the launcher, or whose `events.log` the launcher's transcript tails;
    - `### FOLLOW-UP`: for 60 days after one of your watched PRs merges, a commit by someone else (not a merge) that changes lines the PR changed, or renames or removes its files (one line naming every PR it touches), and another person's PR that references it, each once, with its time; a declared steward's dir gets them instead, and a copy of `MAINTAINER COMMITS`. A commit counts within 3 lines of the PR's lines at the merge. Bots' commits, and hunks that only change dependency versions in `package.json` or a lockfile, don't count. Read each as `core` 1.3 says (Learning from follow-ups).
- **`/agent` commands.** Your comment starting with `/agent` on a thread no live watch dir lists is found in the recent issue and review comments of every repo a live watch dir lists (a search of your comments backs it up, though the search index lags), since you and the agent post as one account. It goes once to one dir's `events.log` as `### AGENT COMMAND`, and the thread joins that dir's `threads.txt`: to the dir named by `/agent <folder name>`, else to the dir listing a thread this one links to or is linked from (most matches; a tie goes to the `--main` dir), else to the `--main` dir as `### UNROUTED /agent`.
- **Retiring.** It retires itself, service, launchd agent and cron lines included, once every thread is merged or closed and `repos.txt` is empty.
- **API budget.** All watchers share one account's 5,000 calls an hour (a 304 counts too) through `~/.mergeworthy/shared-watch.json`. Below 1500 calls left, shared work and follow-ups wait for the reset; below 500, only the notifications and the threads they report are read; after a rate-limit answer every daemon waits and prints one `WATCH ERROR API budget: paused until <time>`. `gh-watch.py --stats` prints the requests a minute.
- **Cadence and state.** How often each thread, feed and repo is read, the shared lease and the state files are in `gh-watch.py`'s header and docstrings. Restarts and plugin updates lose nothing and cost no calls.

## Hooks

### `pre-bash-guard.py` (enforces 1.6, 1.7, 1.8)

It blocks:
- a `gh` post or edit whose body isn't a gated draft, or changed since its gate (use absolute draft paths);
- opening an issue or PR (`gh` or `glab`) in a repo no running watcher covers;
- the same gated draft posted twice as new;
- a post or edit on a thread (comment, review, PR or issue body edit, comment PATCH) whose draft folder has no `thread-context.md` for that thread recording its current latest human comment, or older than the draft's parent; the message gives the `thread-context` command. `--kind tracker` drafts and new issues and PRs are exempt;
- a third comment on a thread (1.6 states the condition);
- `gh pr merge` without `--squash --subject "<title> (#N)" --body ""`, and with `merge=reviewer`, every merge;
- `--delete-branch` while PRs are based on the branch;
- a `git commit` whose author isn't the pushing GitHub account (1.7);
- `docker compose up` (or `run --service-ports`) publishing a fixed host port or a `container_name`, unless prefixed `MERGEWORTHY_HOST_PORTS=user-asked`;
- `codex exec` when T3 Code started the session (`review`: `delegate_task`);
- `pkill -f` and `killall`;
- `kill` of a running agent's process (a `claude … stream-json` session): stop an agent through its task, after reading its status;
- a foreground wait loop (`until`/`while` with `sleep`); run it with `run_in_background` or rely on the completion notification;
- a bare `git stash`;
- a force-push without a pinned lease;
- with a steward declared, another session's `git commit` or `git push` in a mergeworthy checkout.

### `post-bash-register.py` (enforces 1.5)

It adds a thread you just opened or posted in (its `gh` or `glab` URL) to your session's watch dir, else one covering its repo. A read that only prints URLs adds nothing.

### `stop-lint.py` (enforces 1.1.3, 1.5)

It blocks ending a turn when:
- it ends with "want me to / should I / your call…" and no `GENUINE-FORK:` line;
- you posted on GitHub and no live Monitor watches a watcher's `events.log` (a `claude -p` run's caller watches);
- a watch dir it worked in owes a reply;
- in a session that started T3 tasks, its `Running:` list wasn't read with `task_status` since the user's last message, or names a terminal task.
- an agent it launched finished and its job is still open (`agent_jobs.py`);
- a `FOLLOW-UP` it receives has no verdict after 30 minutes (`github-threads`);
- hourly at most, `memory.md` is behind and over 2 hours old: it repeats the refresh order.

It skips its watcher checks while the user's last message says "pause". Each turn's first stop also gets a check-in: work to start, or anything waiting?

### `session-start` (enforces the always-on rules)

It puts the always-on rules into context and writes `settings.env`. A second command, `session-memory.py`, prints in an orchestrator's checkout the order to refresh `memory.md` when it is behind, then its Standing digest: Claude Code previews only 2 KB of a hook output over 10,000 characters. It also points `~/.mergeworthy/current` at the installed version, the stable path watchers use.

### `pre-skill-gate.py` (enforces always-on rule 1)

It blocks an action until every skill its always-on row names was opened with the Skill tool, or typed as `/mergeworthy:<name>`, since the session's last compaction; a subagent counts only its own. The block names each skill and its row.
- `gh pr create` and `gh pr edit`: `pull-request`, `writing`; `gh pr ready` adds `merging`.
- `gh pr merge` and `git push`: `merging`.
- A comment, reply, review or body edit (`gh api` writes included, reactions not): `github-threads`, `writing`. `gh issue create`: `open-issue`, `writing`.
- `post-lint` and `gate-pass`: `writing`. `pr-steps <step>`: `converge` and the step's own skill (`approach`: `pull-request`).
- Starting an agent (`Agent`, `delegate_task`, `codex exec`, `claude -p`), or editing a skill, a prompt, a brief or a rules file: `delegating`.

Read-only commands pass. A row added to `always-on.md` fails `tests/hooks.sh` until the hook's table gates it or lists it as ungated.

**`pre-agent-dedupe`** registers launches that ran (its PostToolUse half) by ticket and blocks duplicate jobs (`delegating` 1.10). A `clientRequestId` may retry within ten minutes; later reuse is blocked. It blocks a brief naming a repo (or its checkout) but not its existing `~/.mergeworthy/projects/<owner>/<repo>.md`, and a brief naming a linked worktree (not the launcher's own) that a process has as its cwd or an agent transcript written in the last five minutes names, and one pinning an older commit of a linked worktree it names, printing `memory.md`'s Ruled out list, and, in an orchestrator's checkout, a research brief (`role: research`, or research in its title) without a `Topic:` line, or whose topic words all appear in a file under the artifact root not named in a `Checked:` line.

### `netns-run`

`netns-run <command...>` runs the command in a private network namespace (`unshare -rn`) with internet access through slirp4netns: ports inside are its own, DNS and HTTPS work, and the command's exit status comes back. It needs `slirp4netns` installed (`sudo apt install slirp4netns`).
