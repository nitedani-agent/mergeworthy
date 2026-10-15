# Mechanisms

A reference for the scripts that enforce the skills' steps; the skills name each one at the step it checks. Not loaded into sessions.

- **Where they live.** The scripts ship in the mergeworthy plugin: its `bin/` is on the Bash `PATH`, and its `hooks/hooks.json` is active while the plugin is enabled. Hooks run their scripts from `~/.mergeworthy/current` (`hooks/run`); only a changed `hooks.json` needs a restart, which `stop-lint` says once.
- **Changing them.** Edit and propagate from the source repo, leaving installed copies untouched (`rules` step 5).
- **The steward.** `~/.mergeworthy/steward` (the user writes it) holds `<work folder> <T3 thread id>`. You are the steward if that is your T3 thread or your delegator's, your working directory is inside that work folder, or `<work folder>/session` names your session. While one is declared, only the steward and its agents commit or push to mergeworthy, and any other session writes a mergeworthy fix it owes as one line in `<work folder>/inbox.md`, read by the steward at every wakeup (`rules` step 2); with none declared, each session fixes mergeworthy itself. Every session whose `events.log` receives a `FOLLOW-UP` sorts it (`rules` step 6).
- **Options.** The plugin's options are `badge`, `merge` and `watcher` (`/plugin` → mergeworthy → Configure options). They reach the scripts through `~/.mergeworthy/settings.env`, rewritten at every session start. An environment variable `MERGEWORTHY_<KEY>` wins over the option.

## Commands

### `gh-watch-start` (`reply`, `task` step 5)

`gh-watch-start [--main] <dir> [owner/repo [N]]…` is the one way to start watching; running it again is harmless.
- **What it adds.** It adds `owner/repo N` to `<dir>/threads.txt` (the watcher rewrites a hand-written `owner/repo#N` so); for GitLab, `gitlab.com/<path> N`, or `'!N'` for an MR. A bare repo goes to `repos.txt`, covering it until a thread of it joins the dir. `owner/repo all` stays and watches the whole repo: new issues and PRs are reported (`### NEW ISSUE`, `### NEW PR`), and any thread that moves joins the dir, reporting each comment without the agent's badge. The steward's dir gets `nitedani/mergeworthy all`.
- **`--main`:** this dir gets the user's `/ai` calls on threads no watcher watches. The default is the first live dir.
- **The supervisor.** It starts the daemon under a supervisor: the systemd user service `gh-watch@<dir>` on Linux, a launchd agent on macOS, else a detached daemon that cron revives.
- **Maintainers.** `GH_WATCH_EYES` names the maintainers whose commits and 👍/👎 are reported; without it, `<dir>/eyes`, else your own login.
- **One watcher per thread.** It refuses a thread another live work folder already watches.
- **The Monitor.** Arm the printed Monitor so the session wakes and answers events (`reply`).

### `post-lint` (`post` step 2)

`post-lint drafts/x.md --kind reply|pr|issue|inline|tracker|proposal [--repo o/r]` checks a draft before it is posted.
- **A reply** reads its parent comment from `drafts/x.parent.md`. Use `--parent none` when it answers nobody.
- **A draft PR's body** takes `--kind pr --draft`: its first line under the badge must be `**State: draft** (<why>)`; without `--draft` that line is a finding. The guard checks the same line on `gh pr create`.
- **The repo's language.** A `Language: <code>` line in the project file (`Language: hu`) makes these checks and the guard's look for that language's words: the State line, the badge's effort words, the evidence-block titles, the notes table and its kinds, the decision block, `### What you should see` and the recommendation words. The words live in `hooks/post_words.py`; without the line, or with a code it doesn't list, they are English. Without `--repo`, the language's repo is the one in `repos.txt` of the first folder above the draft that holds one (when it lists several, the one `threads.txt` names; else a finding asks for `--repo`), else the cwd's git origin. The tracker's title and Decisions headings are in the table too.
- **`tracker`** checks the umbrella issue's format: a `Title: Tracking: …` line, `##` sections of checkboxes, no table, the Decisions comment linked (not at creation), a ticked item's end state, and the Decisions comment's sections. Leave tracker posts badge-free (`writing`).
- **The checks**, each where it applies to the kind:
  - **Writing:** banned phrases; sentences over 40 words or averaging over 25, and more than 30% bold (not for `pr`); internal labels like W2; a bold label followed by a fragment; em dashes.
  - **References:** "stacked on"; bare `#N`.
  - **Content:** budgets; unclassified notes; process in the thread (a post carrying an old ⇒ new rating table may use `N/10` and "rated every"; in a reply, that table counts toward no word cap and lifts the 80-word cap for a short comment); questions without a recommendation; a bare "Done" to a question (`reply`, `inline`); deferrals in the notes table; a ready PR body without `pull-request §Body`'s `### What you should see`, its numbered items showing the evidence outside `<details>`.
  - **Safety and form:** secrets; a missing badge, unless the `badge` option says otherwise (not for `tracker`).

### `thread-context` (`post` step 1)

`thread-context <owner/repo#N> [--depth 2] [--max 30] [--out <file>]` writes the record a reply is drafted from (default `./thread-context.md`). Run it into the draft folder, and hand it to the drafter and the reviewer, never read it into the main session.
- The file holds a header, a **Decisions and positions** ledger (each human comment that agrees, rejects, proposes or decides, quoted with its permalink), the root's full transcript, then each linked thread's first post and last 30 comments. The agent's posts are marked `AGENT` and kept out of the ledger.
- `--latest <repo#N>` prints the latest human comment; `--verify <file> [--target <repo#N>] [--parent <file>]` is what the gate and the guard run.

### `gate-pass` (`post` step 4)

`gate-pass <abs>/drafts/x.md <review output> [post-lint flags]` records that a draft passed the gate.
- It re-runs `post-lint` with the draft's last flags, checks that the review's final message is exactly `CLEAN` and that the review output is newer than the draft (a draft trimmed after its review is linted and reviewed again; gate-pass's own harness line keeps the draft's time), and records the draft's sha256 in `<draft>.gate`.
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

### `memory-prep` (`task` step 8)

`memory-prep init <root> <T3 thread id>`, run from the main session's checkout, records it, its thread, its session and its session-log dir. `memory-prep prep <root>` extracts the user's prompts and the last text of each main session turn logged after `memory.md`'s `covered-until` position from the main session's own logs into `memory-new.txt`, and writes the brief sending one Haiku to `memory-refresh`. `memory-prep digest <root>` prints the Standing part, one line per item, capped at 7,500 characters.

### `agent-job` (`delegate` step 6)

`agent-job list` prints the open jobs `pre-agent-dedupe` registered; `agent-job done <key or ticket path>` releases one once its result is read. It then lists the processes whose cwd is in a linked worktree the job's brief names or in the folder holding its brief, with their PIDs, commands and the ports they listen on (`ss -ltnp`), and kills none.

### The finality trigger (`pre-bash-guard`, `post-bash-register`)

`post-bash-register` counts each posted `--kind proposal` draft per thread in `~/.claude/proposal-rounds.txt`. Before the third proposal, refresh the thread map with its invariants (`design` step 7) and update the thread's WIP comment from it (`design §WIP comment`).

### `pr-steps` (`converge`, `merging`)

`pr-steps <step> <output>` checks a step's output and records it, one file per step:
- `preflight`, per repo and branch: `<app URL> [Chrome flags]` (screenshotted headlessly; an error or blank page fails), a fresh browser-MCP PNG, or `'none, because <why>'`. Edits in its work tree and `git commit` wait for it.
- `approach`, per repo and branch: a table `| Candidate | Rating | Why |` of at least two candidates rated 0–10 and a line `Chosen: <candidate>` rated 7 or more (`pull-request` step 5).
- `verify`: trailing `NO BUGS`.
- `verify` (not `reverify`), `shape` and `fresh`: a `## Standards read` section holding the first sentence of code §Phantom gate, §Docs are a claim and §No regressions, which `pr-steps standards` prints: in both rounds of magne4000/universal-middleware#453 no checker opened the code skill its brief named.
- `reverify`: trailing `NO BUGS`, or `NO LOOP B COMMITS` when none landed (`converge` step 3).
- `fresh`: a `Maintainer: <login>` line, `MERGE AS IS: yes` and trailing `CLEAN` (`converge` step 4).
- `verify` and `reverify`: a line under a `## Dropped` (or other "dropped") heading giving "not a regression", "no documented usage", "rare" or "same as main" as a reason needs a later `RULED: <candidate>: <ruling>` line, the main session's (delegate/verifier.md, the brief's Write list).
- `shape`: Loop B's shape report: the ✅ list and old ⇒ new ratings ending `CLEAN`, or `carries the pass of <sha>` with ≤ 80 changed lines. Old heads' `loopb` and `refactor` records together count as one.
- A new `approach` record ends with `contract: 2`. A branch whose latest approach record lacks it started before the shape pass and finishes under the old contract: `loopb` (trailing `CLEAN`) and `refactor` still record, a `fresh` report needs no `Maintainer:` line, and a `shape` record may carry an old head that has both a `loopb` ending `CLEAN` and a `refactor` pass.
- `gates`: `<command> -> exit 0` lines; a test run's line ends `(N tests)`, N > 0.
- `gates`, in a repo with `.changeset/`: each changeset the branch adds or changes has at most 60 words after its front matter, and together they name every package (the nearest `package.json` with a name, not the root's or a private one's) whose files the branch changed.
- `gh pr create`/`glab mr create` (unless `--draft`/`--wip`), `gh pr ready`/`glab mr update --ready` and a push to a ready PR are blocked until HEAD has all five and the branch has its `approach` record.
- `gh pr create`, `gh pr ready`, a PR body edit and a comment on a PR are blocked when the PR's head has a `shape` pass (its latest shape record; a carry record is followed to the pass it carries) and neither the post nor the live PR body (a comment's case) has a table whose every old ⇒ new row is one of that pass's own: the same numbers for an item its report names (a backticked name, a path matching by its tail), whatever the reason says. An older pass's table doesn't count. The maintainer is shown the pass (`delegate/shape.md`). A PR `gh api` can't read is not checked.

## The watcher daemon: `watcher/gh-watch.py` (`reply`, `task` step 5)

The daemon reports to `<dir>/events.log` and never starts an agent.
- **Comments.** Answer reported comments from the owed list; reactions follow the detection schedule (`reply`).
- **Thread events.** On watched threads it reports pushes, merges and closes (`### PR CHANGED`), CI results (`### CI`), and 👍/👎 on the agent's comments (`### THUMBS UP` / `### THUMBS DOWN`). GitLab threads get only comments, an MR's `### PR CHANGED` and `### CI`, and an issue's `### ISSUE CHANGED`.
- **Other events:**
    - `### ACK`: an acknowledgement that answers your last open proposal;
    - `### MAINTAINER COMMITS`: commits a maintainer pushed to your PR;
    - `### TRACKER STALE`: a PR merged or closed, and the umbrella issue named in `<dir>/umbrella.txt` doesn't show it ticked with that state;
    - `### SHAPE STALE`: a PR's code changed by more than ~80 lines since its last `pr-steps shape`. Not an event, but read alongside it: a maintainer's comment carrying a refactor prompt URL the repo's project file names (a file link on a line about the refactor pass or prompt) is recorded in `~/.claude/refactor-asks.txt` as `<time> <PR head then> <owner/repo#N> <comment URL>` for `pr-steps shape`;
    - `### DEPENDENT of merged …`: a PR listed in `waiting-on.txt` merged;
    - `### AGENT DONE <ticket>`: an agent the session launched finished (`agent_jobs.py`: its transcript went quiet), once per finish until `agent-job done`; the dir is the one whose `session` file names the launcher, or whose `events.log` the launcher's transcript tails;
    - `### FOLLOW-UP`: for 60 days after one of your watched PRs merges, a commit by someone else (not a merge) that changes lines the PR changed, or renames or removes its files, another person's PR that references it, and, on your PR open or merged, another account's rename (`#rename-<time>`, quoting both titles), each once, with its time. A commit touching several of your PRs is one line naming them all. While the steward's watcher runs, its dir gets these instead, plus a copy of each `MAINTAINER COMMITS`, which the PR's session still handles. A commit counts within 3 lines of the PR's lines at the merge. Bots' commits and hunks that only bump dependency versions don't count. Each session that receives one sorts it (`rules` step 6).
    - `### MAINTAINER REVIEW`: a maintainer's review of your PR, other than a bare approval, once per review; it goes where a `FOLLOW-UP` goes, and each defect it names is sorted the same way (`rules` step 6).
- **`/agent` commands.** Your comment, issue or PR starting with `/agent` on a thread no live dir lists is found in the watched repos' recent comments and issue lists, or by a search. It goes once to one dir's `events.log` as `### AGENT COMMAND`, and the thread joins that dir's `threads.txt`: the dir named by `/agent <folder name>`, else the one listing most threads linked to or from it, else one watching its repo whole, else the `--main` dir, as `### UNROUTED /agent`.
- **Retiring.** It retires itself (service, launchd agent, cron lines) once every thread is merged or closed and `repos.txt` is empty.
- **API budget.** All watchers share one account's 5,000 calls an hour through `~/.mergeworthy/shared-watch.json`. Below 1500 calls left, the jobs one daemon runs for all (finding `/agent` comments, `FOLLOW-UP`s) wait for the reset while each daemon reads its own threads; below 500, only GitHub's notifications feed and the threads it names are read; after a rate-limit answer every daemon waits and prints one `WATCH ERROR API budget: paused until <time>`.
- **Cadence and state.** An open thread changed in the last day is checked every 5 minutes, other open threads every 30, merged or closed ones every 6 hours; the rest is in `gh-watch.py`'s header. Restarts and updates lose nothing and cost no calls. A repeated `WATCH ERROR` prints once an hour.

## Hooks

### `pre-bash-guard.py` (`post`, `merging`, `delegate/agent.md`)

It blocks:
- a `gh` post or edit whose body isn't a gated draft, or changed since its gate (use absolute draft paths);
- opening an issue or PR (`gh` or `glab`) in a repo no running watcher covers;
- the same gated draft posted twice as new;
- a post or edit on a thread whose draft folder has no `thread-context.md` for that thread recording its current latest human comment, or older than the draft's parent. `--kind tracker` drafts and new issues and PRs are exempt;
- a third comment on a thread (`post §Thread rules`);
- `gh pr create` or `gh pr edit` with a `--title` typed inline, not `"$(cat <work folder>/drafts/title.md)"`;
- a shell write of a `.review.out` file (a redirection, `tee`, `cp`, `mv`, `sed -i`) by the main session: the reviewer writes its own (`codex exec -o`, the agent's output file, a `claude -p` reviewer's stdout);
- `gh pr merge` without `--squash --subject "<title> (#N)" --body ""`, and with `merge=reviewer`, every merge;
- `--delete-branch` while PRs are based on the branch;
- a `git commit` whose author isn't the pushing GitHub account (`merging` step 1);
- `docker compose up` (or `run --service-ports`) publishing a fixed host port or a `container_name`, unless prefixed `MERGEWORTHY_HOST_PORTS=user-asked`;
- `codex exec` when T3 Code started the session (`delegate §Reviewers`);
- `pkill -f` and `killall`;
- `kill` of a running agent's process: stop an agent through its task, after reading its status;
- a foreground wait loop (`until`/`while` with `sleep`);
- a bare `git stash`;
- a force-push without a pinned lease;
- with a steward declared, a `git commit` or `git push` in a mergeworthy checkout by any session but the steward and its agents.

### `post-bash-register.py` (`reply`, `task` step 5)

It adds a thread you just opened or posted in (its `gh` or `glab` URL) to your session's work folder, else one covering its repo.

### `stop-lint.py` (always-on, `reply`)

It blocks ending a turn when:
- it ends with "want me to / should I / your call…" and no `GENUINE-FORK:` line;
- you posted on GitHub and no live Monitor watches a watcher's `events.log` (a `claude -p` run's caller watches);
- a work folder it worked in owes a reply;
- a `PROMISED` line in its `proposals-open.md`, or a draft folder's there, is past the time it or its draft names (`by <ISO time>`, `by HH:MM UTC`) and doesn't yet open with `DONE <commit or link>`;
- in a session that started T3 tasks, its `Running:` list wasn't read with `task_status` since the user's last message, or names a terminal task.
- an agent it launched finished and its job is still open (`agent_jobs.py`);
- a `FOLLOW-UP` or `MAINTAINER REVIEW` in the `events.log` of a dir it works in, or the steward's, has no verdict after 30 minutes (`rules` step 6);
- at most once an hour, `memory.md` is behind the session log and covers nothing from the last 2 hours: it repeats the refresh order, to run beside the work (`task` step 8). Launching an agent on `memory-prep`'s brief holds it for an hour; running `prep` alone doesn't.

It skips its watcher checks and the refresh order while the user's last message says "pause". Each turn's first stop also gets a check-in: work to start, or anything waiting?

### `session-start` 

It puts the always-on rules into context and writes `settings.env`. A second SessionStart hook, `session-memory.py`, prints, in a main session's checkout, the order to refresh `memory.md` when it is behind, then its Standing digest. `session-start` also points `~/.mergeworthy/current` at the installed version.

### `pre-skill-gate.py` (always-on rule 1)

It blocks an action until every skill its always-on row names was opened with the Skill tool, or typed as `/mergeworthy:<name>`, since the session's last compaction; a subagent counts only its own. The block names each skill and its row.
- The table is `ACTIONS` in `hooks/pre-skill-gate.py`; `post` and `writing` gate every post (`gh pr create`, `gh pr edit`, `gh issue create`, `gh pr review`, comments and `gh api` writes, `post-lint`, `gate-pass`).
- `post-lint --kind` adds the kind's skill: `reply` (and `inline`), `proposal` → `design`, `pr` → `pull-request`, `issue` → `open-issue`, `tracker` → `task`.
- `gh-watch-start`: `task`. `thread-context` (building a record): `post`. Any `gh` command with `--attach`: `evidence`.
- `gh pr ready`: `pull-request`, `merging`; `gh pr merge` and `git push`: `merging`. `pr-steps approach`: `pull-request`; the other `pr-steps` records: `converge`.
- Starting an agent (`Agent`, `delegate_task`, `codex exec`, `claude -p`) or editing a brief or prompt file: `delegate`. Editing a skill, `always-on.md`, `AGENTS.md` or `CLAUDE.md`: `rules`.
- `code`, `finality` and `docs` are ungated: `code` reaches agents by path in their briefs, `finality` has pre-bash-guard's third-proposal block, and no tool call tells docs apart.

- `session-start` records, in `~/.mergeworthy/sessions/<session id>`, the skill catalog of the plugin folder the session loaded (`graph` or `v1`), at start, resume and compaction. A session recorded on `v1`, or with no record (it started before this install), has the old skills loaded: an old name it opened satisfies its successor (`core` → `task`; `github-threads` → `post`, `reply`; `design-loop` → `design`; `delegating` → `delegate`, `rules`).

Read-only commands pass.

**`pre-agent-dedupe`** registers launches that ran by ticket and title and blocks duplicate jobs (`delegate` step 1). A `clientRequestId` may retry within ten minutes; later reuse is blocked. It also blocks:
- a brief with any role but `research` or `test` that names a repo (`owner/repo`, its URL or a path in its checkout) but not its existing `~/.mergeworthy/projects/<owner>/<repo>.md`;
- an `implementation` brief for such a repo that doesn't name `skills/code/SKILL.md`, and a brief that reads a `thread-context.md` but doesn't name `skills/writing/SKILL.md`;
- a brief naming a linked worktree (not the launcher's own), in its launch text or the brief file it follows, that a process has as its cwd or an agent transcript written in the last five minutes names, unless T3's state shows that transcript's task completed, with no run of it queued or running and no task it started still running;
- a fourth agent open at once for the same session (`delegate` step 1): a job is open until `agent-job done` releases it or its agent finished (`agent_jobs.py`); memory-refresh jobs and a brief with a `Fan-out: <finality step 2 or 3, or converge §Running the agents>` line don't count;
- an implementation, drafter (`thread-context.md`) or fresh-reader (`MERGE AS IS`) brief for a repo whose project file's `## Who decides` links no `<repo>.study.md` with a first line `Studied: <date>` within 30 days (`task` step 4);
- a brief pinning an older commit of a linked worktree it names, printing `memory.md`'s Ruled out list;
- a brief still holding a placeholder of a fenced template in `skills/delegate/` (`<the slice's risky edges>`), naming each and its template; one in backticks there (the agent's output form), the pasted `agent.md`'s and an HTML tag don't count;
- in a main session's checkout, a research brief (`role: research`, or research in its title) without a `Topic:` line, or whose topic words (all of them in one paragraph) all appear in a file under the work folder not named in a `Checked:` line.

### `.githooks/pre-push` (this repo)

Before `tests/all.sh`, it refuses a push in which a commit changing `skills/` or `always-on.md` has no `Cold-read: <path>` trailer naming an existing file (the cold read's record, `rules` step 4), in it or in a later commit of the push, naming each such commit.

### `netns-run`

`netns-run <command...>` runs the command in a private network namespace (`unshare -rn`) with internet access through slirp4netns: ports inside are its own, DNS and HTTPS work, and the command's exit status comes back. It needs `slirp4netns` installed (`sudo apt install slirp4netns`).
