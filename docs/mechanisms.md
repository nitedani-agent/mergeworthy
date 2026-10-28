# Mechanisms

A reference for the scripts that enforce the skills' steps; the skills name each one at the step it checks. Not loaded into sessions.

- **Where they live.** The scripts ship in the mergeworthy plugin: its `bin/` is on the Bash `PATH`, and its `hooks/hooks.json` is active while the plugin is enabled. Hooks run their scripts from `~/.mergeworthy/current` (`hooks/run`); only a changed `hooks.json` or `hooks/run` needs a restart, which `stop-lint` says once. `hooks/failclosed.py`, which every hook that blocks imports first, logs each block a check makes (its `sys.exit(2)`; a crash is none) once a day per check, the source line that wrote its message, in `~/.mergeworthy/hooks-fired.log` (`hooks/blocklog.py`), which `steward fired` reads.
- **They fail closed.** Claude Code lets an action through on any hook exit code but 2, and when a hook outlives its timeout. So a hook that crashes blocks (`hooks/failclosed.py`), `hooks/run` turns any other exit code, and a run past 540 seconds, into a block, and a check that can't run (gh can't answer, a record or transcript can't be read, a command doesn't parse, the shell parser can't be installed) blocks what it guards, saying why; local work it doesn't guard (a commit while offline, a command after a `cd` it can't follow) passes. Where a check is skipped instead, a comment beside it says why nothing needs checking there.
- **Changing them.** Edit and propagate from the source repo, leaving installed copies untouched (`rules` step 5).
- **The steward.** `~/.mergeworthy/steward` (the user writes it) holds `<work folder> <T3 thread id>`. You are the steward if that is your T3 thread or your delegator's, your working directory is inside that work folder, or `<work folder>/session` names your session. While one is declared, only the steward and its agents commit or push to mergeworthy, and any other session writes a mergeworthy fix it owes as one line in `<work folder>/inbox.md`, read by the steward at every wakeup (`rules` step 2); with none declared, each session fixes mergeworthy itself. Every session whose `events.log` receives a `FOLLOW-UP` sorts it (`rules` step 6). A declared steward's session wakes only on its Monitor; the `steward` skill is the on-demand form: one pass when the user asks (`steward round`, which runs `gh-watch-start --round`), leaving nothing running.
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
- **`--round`:** no daemon and no Monitor: one round of the watcher appends to `events.log`, recording what it reported as a daemon's round does; it reads the issue lists itself, back to the dir's last complete pass (the first time, 7 days), whatever other daemons polled. A thread it lists for the first time is read back to that point too. It exits with the round's status, 1 when a call failed or a rate-limit pause cut it short (its shared jobs have no per-job call cap); only a complete round moves that point and writes its session to `<dir>/passed`. A thread a live dir watches is skipped with a note; a dir whose daemon runs is refused before anything changes. For a day after, pre-bash-guard and post-bash-register treat the dir as live for the session `passed` names, and stop-lint lets that session end its turn after posting without a Monitor, holding it to that dir's owed replies instead (the `steward` skill).

### `steward` (the `steward` skill)

`steward round <folder>` runs `gh-watch-start --round <folder> nitedani/mergeworthy` (a bare line: its rule PRs can open there) with every open PR of yours whose body starts with an agent's badge; the round watches nitedani/mergeworthy whole only when `~/.mergeworthy/steward` names the folder. `steward owed` lists the leftovers of every work folder whose session is idle (its log unwritten for 2 hours, or no log of its session): owed replies (not those a holding or drafting line with an ETA ahead holds), unsorted `FOLLOW-UP` and `MAINTAINER REVIEW` events, `PROMISED` lines. `steward fired [--days N]` lists each check that log holds with its last day and how many days it blocked, then each check of the hooks in `hooks.json` with no block in N days (default 60), the removal candidates. `steward done <folder> <summary>` appends `<UTC time> <summary>` to `<folder>/passes.txt`, where the next pass's windows start. `steward sessions [<folder>] [--since <ISO>]` lists this machine's Claude Code and Codex logs written since (default the folder's last pass, else 7 days): tokens, turns, hours, the PRs they name, and the user's messages (not text the harness injects) that correct the agent, with their line. `steward metrics <folder> [--since <ISO>] [--author <login>]` measures the PRs the author opened (default you, only those whose body starts with an agent's badge) that settled (merged or closed) since the last line of `<folder>/passes.txt` (else 60 days), those of the window as long before it, and those still open: outcome, hours to merge, review rounds, change requests, commits dated after the first maintainer review, first-pass acceptance (merged with neither; a merge of the base doesn't count), sorted `FOLLOW-UP` MISS and TASTE verdicts, and the tokens, cache reads left out, of the local sessions that name the PR more than any other (unknown when none does). It appends one record per PR to `<folder>/metrics.jsonl` and prints both windows side by side.

### `post-lint` (`post` step 2)

`post-lint drafts/x.md --kind reply|status|pr|issue|inline|tracker|proposal [--repo o/r]` checks a draft before it is posted.
- **A reply** reads its parent comment from `drafts/x.parent.md`. Use `--parent none` when it answers nobody.
- **A draft PR's body** takes `--kind pr --draft`: its first line under the badge must be `**State: draft** (<why>)`; without `--draft` that line is a finding. The guard checks the same line on `gh pr create`.
- **The repo's language.** A `Language: <code>` line in the project file (`Language: hu`) makes these checks and the guard's look for that language's words: the State line, the badge's effort words, the evidence-block titles, the notes table and its kinds, the decision block, `### What you should see` and the recommendation words. The words live in `hooks/post_words.py`; without the line, or with a code it doesn't list, they are English. Without `--repo`, the language's repo is the one in `repos.txt` of the first folder above the draft that holds one (when it lists several, the one `threads.txt` names; else a finding asks for `--repo`), else the cwd's git origin. The same word dictionary holds the tracker's title and Decisions headings. Without `--repo`, the inference gives only the language; the other repo checks need `--repo`.
- **`status`** is a reply checked in place of a review (`post` step 3): its deadline follows `by` or `before` as an ISO time in UTC (`2026-10-28T16:00Z`, the form stop-lint holds its `PROMISED` line to) and is still ahead, a clock time (`16:00 UTC`, which stop-lint reads as its next occurrence, whatever date stands beside it) and a relative time it lists (`tomorrow`, `in about an hour`) are findings, each sentence (a list item too) says what is being done (`I'm …ing`, `I'll …`, but not `I'm seeing` or `getting`, which report a result) or holds that time, and it holds no claim or result (a sha, a commit or file link, a table or code block, a rating, a count of tests, files or lines, words like fixed, passes, verified, because, ", since"), no question or decision, and at most 100 words; a badge naming a reviewer is a finding.
- **`tracker`** checks the umbrella issue's format: a `Title: Tracking: …` line, `##` sections of checkboxes, no table, the Decisions comment linked (not at creation), a ticked item's end state, and the Decisions comment's sections. Leave tracker posts badge-free (`writing`).
- **The checks**, each where it applies to the kind:
  - **Writing:** banned phrases; sentences over 40 words or averaging over 25, and more than 30% bold (not for `pr`); internal labels like W2; a bold label followed by a fragment; em dashes.
  - **References:** "stacked on"; bare `#N`.
  - **Content:** budgets; unclassified notes; process in the thread (a shown commit-review table, or a parent asking for a review, allows `N/10`; a shown old ⇒ new row, `N ⇒ M` or `N => M`, also allows "rated every/each"; a row in an HTML comment or fenced code allows nothing); for every kind, a table's rated rows (old ⇒ new, `new ⇒ N` included, or a commit-review row rated N/10) leave the word count up to 45 words a rendered cell (an escaped `\|` stays inside its cell), its header up to 45 words in all; its other rows count (in a PR body, under the prose-cell rule); rows in fenced code (CommonMark fences) or HTML comments are not rated rows; the rated rows each lift a short comment's 80-word cap by 20 words, whatever block holds them; questions without a recommendation; a bare "Done" to a question (`reply`, `inline`); deferrals in the notes table; a ready PR body without `pull-request §Body`'s `### What you should see`, its numbered items showing the evidence outside `<details>`.
  - **Safety and form:** secrets; a missing badge, unless the `badge` option says otherwise (not for `tracker`).

### `thread-context` (`post` step 1)

`thread-context <owner/repo#N> [--depth 2] [--max 30] [--out <file>]` writes the record a reply is drafted from (default `./thread-context.md`). Run it into the draft folder, and hand it to the drafter and the reviewer, never read it into the main session.
- The file holds a header, a **Decisions and positions** ledger (each human comment that agrees, rejects, proposes or decides, quoted with its permalink), the root's full transcript, then each linked thread's first post and last 30 comments. The agent's posts are marked `AGENT` and kept out of the ledger.
- `--latest <repo#N>` prints the latest human comment; `--verify <file> [--target <repo#N>] [--parent <file>]` is what the gate and the guard run.

### `gate-pass` (`post` step 4)

`gate-pass <abs>/drafts/x.md <review output> [post-lint flags]` records that a draft passed the gate. A `--kind status` draft takes `none` as its review output, and only it; it needs its `PROMISED` line.
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

### `disk-sweep`

`disk-sweep --delete` deletes build folders and `node_modules` that hold nothing a rebuild can't restore, and finished work folders that hold nothing to lose, and appends `<UTC time> <bytes> <path or docker:image/docker:builder> <rule> deleting` to `~/.mergeworthy/disk-sweep.log` before each deletion and the same line ending `deleted` or `failed` after it, so a sweep killed midway leaves its record. `<bytes>` is the allocated size of the entries whose every hard link is inside the path; a Docker prune writes one line, `deleted`, with the size Docker reports once it succeeded. Without `--delete` it prints the lines without the last word and deletes nothing. On Linux, the main watch dir's daemon starts `disk-sweep --delete` at most once an hour, under `nice -n 19` and `ionice -c3`, writing its output and errors to `disk-sweep.out` in that watch dir.
- **Who.** A deleting run under the account's home (from the password database, whatever `HOME` says) and every Docker prune happen only when the watcher daemon of the main watch dir started the sweep: `disk-sweep` is inside the installed copy (`~/.mergeworthy/current`), its parent runs that copy's `gh-watch.py` in the main watch dir, and that dir's `gh-watch.pid` names the parent's parent, the daemon's loop. A test or a probe, whatever its `HOME`, watch dir or entry point, has another parent or another copy: its `--delete` exits 2 under the account's home, and it deletes only in temp folders outside it.
- **Where.** The work folders (`~/.mergeworthy/work/*/`, and `~/*-work/` from before that layout), `~/.t3/worktrees/` and Docker. It never follows a symlink or leaves a root's filesystem, deletes nothing with a symlink anywhere on its path, and one runs at a time. Idle means no file outside the paths git ignores has an mtime within 24 hours of the sweep's start. Busy means a process works there or holds a file open there, or an unfinished job in `~/.claude/agent-jobs` names its absolute or `~/` path; `/proc` and the jobs are read each time it is checked. A candidate holding version-control data (`.git`, `.hg`, `.svn` or `.jj`, a folder or a file), a file with an mtime in the last 24 hours or a folder the sweep can't read is kept (for `w-done`, what its own checks find instead), and so is one whose repo, or a loose `node_modules`' parent, is busy right before it would be listed or deleted.
- **`c-ignored`:** in an idle repo or worktree that isn't busy, the folders git ignores named `node_modules`, `dist`, `build`, `.next`, `.vite`, `.turbo`, `.svelte-kit`, `coverage`, `test-results` or `playwright-report` (never `.cache`, where projects keep dumps and reports). **`c-node_modules`:** outside any repo in a work folder, a `node_modules` whose parent is idle (other `node_modules` and nested repos aside) and isn't busy.
- **`w-done`,** once a day: a folder directly under `~/.mergeworthy/work` whose watcher retired at least 14 days ago, deleted whole when nothing in it would be lost; `~/*-work/` folders never are, nor any folder off Linux. The watcher's `retire_if_done` writes the time to `retired` once every thread is merged or closed; `gh-watch-start` removes it. Until the 14 days pass, the folder's row says when it may go. The folder stays while `replies-owed.md`, `waiting-on.txt` or `questions-owed.md` has a line that isn't blank, a `#` comment or cleared by `done` (`done:` in `replies-owed.md`; after a `- ` or `* ` marker too), or `proposals-open.md` a `PROMISED` line; while a work tree under it has a modified or untracked file; and while a repo whose git data is inside it has a stash, a worktree outside it, or a branch tip, tag or worktree HEAD that no commit its remotes hold now (`git ls-remote`) reaches and GitHub doesn't confirm (a pull request's head stays after its branch is deleted). A detached worktree of a repo outside keeps it unless a branch, tag or remote-tracking ref there reaches its HEAD. A bare repo or a repo inside an ignored folder (no git runs there) keeps it too, its row saying to check it by hand, and so do another version-control system's data and a failed check. Git runs with `--no-optional-locks`, `core.fsmonitor=false` and `GIT_NO_LAZY_FETCH=1`, and `ls-remote` from `/`: a repo's own `core.fsmonitor`, `core.sshCommand`, `credential.helper` or `insteadOf` isn't used, but a clean filter its config names can still run in `status`. The deletion then takes every rule's checks, a refusal naming its check in the row, and `git worktree prune` runs in each repo outside that had a worktree in it. Each deleting run rewrites `~/.mergeworthy/work-kept.md` with every retired folder that stays and its reasons; a dry run prints them.
- **`h-ignored`,** once a day: the same build folders in any git repo up to 5 levels below the home folder (hidden folders and the work folders aside), each neither written nor read for 14 days.
- **`k-cache`,** once a day: `pnpm store prune`, `pip cache purge`, `npm cache clean --force` when `~/.npm/_cacache` is neither written nor read for 14 days, and each entry of the named tool caches (cargo's, and `~/.cache/yarn`, `node-gyp`, `go-build` and the like; never browser binaries or the rest of `~/.cache`) neither written nor read for 14 days that isn't busy. A missing tool is skipped.
- **`d-docker`:** `docker image prune -a` (every unused image) and `docker builder prune`, with `-f --filter until=336h`, each by its own age rule. Never containers or volumes: `until=24h` selects a container created over a day ago even if it stopped a minute ago. The bytes are what Docker reports, `?` in a dry run. A prune that fails prints Docker's error, logs nothing and makes the sweep exit 1.
- **The weekly report,** never a deletion: `~/.mergeworthy/disk-report.md` lists the 20 largest folders under the home folder neither written nor read for 14 days that no rule deletes, for the user to pick from.

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
- `shape`: Loop B's shape report: the ✅ list and old ⇒ new ratings ending `CLEAN`, or `carries the pass of <sha>` with ≤ 80 changed lines. A carry is refused when `~/.claude/refactor-asks.txt` holds an ask on this branch (its head then is in HEAD's history) newer than the carried pass: a pass runs instead. Old heads' `loopb` and `refactor` records together satisfy the pipeline and may be carried into a `shape` record; the posting guard reads `shape` records only.
- A new `approach` record ends with `contract: 2`. A branch whose latest approach record lacks it started before the shape pass and finishes under the old contract: `loopb` (trailing `CLEAN`) and `refactor` still record, a `fresh` report needs no `Maintainer:` line, and a `shape` record may carry an old head that has both a `loopb` ending `CLEAN` and a `refactor` pass.
- `gates` and `quick` (the quick gates on any head, `code §Gates`): `<command> -> exit 0` lines; a test run's line ends `(N tests)`, N > 0; no line says a gate didn't run ("not installed", "let CI verify").
- `gates`, in a repo with `.changeset/`: each changeset the branch adds or changes has at most 60 words after its front matter, and together they name every package (the nearest `package.json` with a name, not the root's or a private one's) whose files the branch changed.
- `gh pr create`/`glab mr create` (unless `--draft`/`--wip`), `gh pr ready`/`glab mr update --ready` and a push to a ready PR are blocked until HEAD has all five and the branch has its `approach` record.
- After a maintainer's refactor ask on a PR (the newest entry for it in `~/.claude/refactor-asks.txt`; an edited ask is a new entry), `gh pr ready`, a PR body edit and a comment on the PR are blocked, naming the ask, until a real pass (not a carry) is recorded after it on the PR's head or a commit on the first page of its commits. Until then a comment goes out (the line is what the guard reads, not proof the maintainer was told) when the session's watch dir, or the folder above the draft, has an open `PROMISED <repo>#<N>: … refactor …` line in `proposals-open.md`; `gh pr ready` and a body edit wait for the pass. The guard checks the record only; the post review checks that the post shows that pass's result (`delegate/post-review.md`). The target is resolved once for every check (`post_target`): `gh pr comment/edit/ready` by number, URL, branch or the current branch, with or without `-R`; `gh issue comment/edit` by number or URL, checked when it is a PR; `gh api` posts to `issues/<N>/comments`, edits of `issues/comments/<id>`, and PATCHes of `pulls/<N>` or `issues/<N>`. A PR `gh api` can't read is not checked.

## The watcher daemon: `watcher/gh-watch.py` (`reply`, `task` step 5)

The daemon reports to `<dir>/events.log` and never starts an agent.
- **Comments.** Answer reported comments from the owed list; reactions follow the detection schedule (`reply`).
- **Thread events.** On watched threads it reports pushes, merges and closes (`### PR CHANGED`), CI results (`### CI`), and 👍/👎 on the agent's comments (`### THUMBS UP` / `### THUMBS DOWN`). GitLab threads get only comments, an MR's `### PR CHANGED` and `### CI`, and an issue's `### ISSUE CHANGED`.
- **Other events:**
    - `### ACK`: an acknowledgement that answers your last open proposal;
    - `### MAINTAINER COMMITS`: commits a maintainer pushed to your PR;
    - `### TRACKER STALE`: a PR merged or closed, and the umbrella issue named in `<dir>/umbrella.txt` doesn't show it ticked with that state;
    - `### SHAPE STALE`: a PR's code changed by more than ~80 lines since its last `pr-steps shape`;
    - `### DEPENDENT of merged …`: a PR listed in `waiting-on.txt` merged;
    - `### AGENT DONE <ticket>`: an agent the session launched finished (`agent_jobs.py`: its transcript went quiet), once per finish until `agent-job done`; the dir is the one whose `session` file names the launcher, or whose `events.log` the launcher's transcript tails;
    - `### FOLLOW-UP`: for 60 days after one of your watched PRs merges, a commit by someone else (not a merge) that changes lines the PR changed, or renames or removes its files, another person's PR that references it, and, on your PR open or merged, another account's rename (`#rename-<time>`, quoting both titles), each once, with its time. A commit touching several of your PRs is one line naming them all. While the steward's watcher runs, its dir gets these instead, plus a copy of each `MAINTAINER COMMITS`, which the PR's session still handles. A commit counts within 3 lines of the PR's lines at the merge. Bots' commits and hunks that only bump dependency versions don't count. Each session that receives one sorts it (`rules` step 6).
    - `### MAINTAINER REVIEW`: a maintainer's review of your PR, other than a bare approval, once per review; it goes where a `FOLLOW-UP` goes, and each defect it names is sorted the same way (`rules` step 6).
- **Refactor asks.** The watcher also records a maintainer's comment carrying a refactor prompt URL the repo's project file names (a file link on a line about the refactor pass or prompt) in `~/.claude/refactor-asks.txt` as `<time> <PR head the scan saw> <owner/repo#N> <comment URL>`, for `pr-steps shape` and pre-bash-guard, and again with its newer time when the comment is edited; it writes no event.
- **`/agent` commands.** Your comment, issue or PR starting with `/agent` on a thread no live dir lists is found in the watched repos' recent comments and issue lists, or by a search. It goes once to one dir's `events.log` as `### AGENT COMMAND`, and the thread joins that dir's `threads.txt`: the dir named by `/agent <folder name>`, else the one listing most threads linked to or from it, else one watching its repo whole, else the `--main` dir, as `### UNROUTED /agent`.
- **Retiring.** It retires itself (service, launchd agent, cron lines) once every thread is merged or closed, each merged PR of yours is 60 days past its merge (`FOLLOW-UP`s end then), and no `owner/repo all` line in `repos.txt` watches a whole repo (a bare `owner/repo` line doesn't keep it), and writes the time to `retired` in its watch dir (`disk-sweep`'s `w-done`).
- **API budget.** All watchers share one account's 5,000 calls an hour through `~/.mergeworthy/shared-watch.json`. Below 1500 calls left, the jobs one daemon runs for all (finding `/agent` comments, `FOLLOW-UP`s) wait for the reset while each daemon reads its own threads; below 500, only GitHub's notifications feed and the threads it names are read; after a rate-limit answer every daemon waits and prints one `WATCH ERROR API budget: paused until <time>`.
- **Cadence and state.** An open thread changed in the last day is checked every 5 minutes, other open threads every 30, merged or closed ones every 6 hours; the rest is in `gh-watch.py`'s header. Restarts and updates lose nothing and cost no calls. A repeated `WATCH ERROR` prints once an hour.

## Hooks

### `pre-bash-guard.py` (`post`, `merging`, `delegate/agent.md`)

It parses the whole command with mvdan/sh, the parser of `shfmt` (`hooks/shellcmd.py`; `hooks/requirements.txt` pins it, installed with uv or pip into `~/.mergeworthy/pydeps` on first use): quotes and heredocs over several lines, `$( )`, chains, wrappers, `bash -c`, `eval`, git aliases. It blocks:
- every collaboration push (one that updates an open PR's or MR's head, or goes to a repo the pushing account doesn't own, or to a host that is neither GitHub nor GitLab; its push URLs as git resolves them; a push to the account's own repo that updates no open PR or MR is free), and every `gh pr create`, draft or not: from a checkout outside a task's work folder (`~/.mergeworthy/work/<task>/`, or an older `<name>-work/` above the checkout or beside it under its prefix); while its `scope.md` lacks line 1 `Tier: …` or a checkbox; without a `pr-steps quick` (or `gates`) record on the pushed head; while the head's log lacks a passing line naming each failing CI job of the PRs `scope.md`'s open boxes link and of the PRs it updates; a push also needs a running watcher on the checkout's GitHub or GitLab repos, or the one pushed to;
- a shell write into `~/.claude/pr-steps` (pre-design-gate blocks a Write or Edit there), and a GitHub write through `curl`, `wget`, `http`, `https` or `xh`;
- a command that doesn't parse, or any command while the parser can't be installed, that holds `git push`, `git commit`, `gh pr|issue|api|release`, `glab issue|mr` or an HTTP client to `api.github.com`;
- whatever it can't check: a thread, PR or its CI gh can't read, whether a push updates a PR or MR (except a push to the account's own repo from a checkout of no one else's), a thread or repo it can't tell, a compose config that doesn't load, a push after a `cd` it can't follow or to a remote computed when it runs, a command named by an expansion (`"${a[@]}"`) that holds a guarded verb;
- a `gh` post or edit whose body isn't a gated draft, or changed since its gate (use absolute draft paths);
- opening an issue or PR (`gh` or `glab`) in a repo no running watcher covers;
- the same gated draft posted twice as new;
- a post or edit on a thread whose draft folder has no `thread-context.md` for that thread recording its current latest human comment, or older than the draft's parent. `--kind tracker` drafts and new issues and PRs are exempt;
- a third comment on a thread (`post §Thread rules`);
- `gh pr create` or `gh pr edit` with a `--title` typed inline, not `"$(cat <work folder>/drafts/title.md)"`;
- a shell write (a redirection, `tee`, `sed -i`, `cp`, `mv`, `install`) into a git repo whose root `AGENTS.md` or `CLAUDE.md` this session hasn't read (a Read, `cat` or `sed` with no error) since its last compaction, naming the files; `pre-design-gate.py` blocks Edit, Write, MultiEdit and NotebookEdit the same way;
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

It reads the final message from its input (`last_assistant_message`), not the transcript, which may not hold it yet. `stop_hook_active` skips only the check-in: every other check holds until met (Claude Code ends a turn after 8 blocks in a row). It blocks ending a turn when:
- in a session doing mergeworthy work (a task, a work folder, a push or post, a watcher, an agent it started), the message offers or hands the next step back ("want me to / should I / your call / tell me when / ask me to / nothing will notify me…") and has no `GENUINE-FORK:` line;
- a session that opened `task`, pushed or posted has no `scope.md` starting with its Tier line in a work folder it used, or one of those `scope.md` files has an open box while nothing this session started will wake it (a live Monitor or background command, an agent it launched) and the message has no `GENUINE-FORK:` line;
- a sentence whose subject is a PR (`#N is still a draft`, `CI on #N is green`; not `my reply to #N`, a quote or code) states its state (a draft, ready, merged, CI green or red) that GitHub contradicts now or gh can't read; a condition or plan (`once`, `until`, `will`) states none (`#N` is looked up in the repos the message links, then the checkout's `upstream` and `origin`);
- you posted on GitHub and no live Monitor watches a watcher's `events.log` (a `claude -p` run's caller watches);
- a work folder it worked in owes a reply; with its watcher dead and not retired, every line not `done:` counts;
- a `PROMISED` line in its `proposals-open.md`, or a draft folder's there, is past the time it or its draft names (`by <ISO time>`, `by HH:MM UTC`) and doesn't yet open with `DONE <commit or link>`;
- in a session that started T3 tasks, its `Running:` list names a task (by its link, or the latest task of a title) neither launched nor read with `task_status` since the user's last message, or a terminal task.
- an agent it launched finished and its job is still open (`agent_jobs.py`);
- a `FOLLOW-UP` or `MAINTAINER REVIEW` in the `events.log` of a dir it works in, or the steward's, has no verdict after 30 minutes (`rules` step 6);
- at most once an hour, `memory.md` is behind the session log and covers nothing from the last 2 hours: it repeats the refresh order, to run beside the work (`task` step 8). Launching an agent on `memory-prep`'s brief holds it for an hour; running `prep` alone doesn't.

It skips its watcher checks, the open-box check and the refresh order while the user's last message says "pause". A turn's first stop also gets a check-in, at most once per 30 minutes per session, in a session with work that can still be waiting (a work folder it worked in, an agent it started, a Monitor) and a message not ending with a `GENUINE-FORK:` line: work to start, or anything waiting? With nothing, the session ends the turn without writing anything.

### `session-start` 

It puts the always-on rules into context and writes `settings.env`. A second SessionStart hook, `session-memory.py`, prints, in a main session's checkout, the order to refresh `memory.md` when it is behind, then its Standing digest. `session-start` also points `~/.mergeworthy/current` at the installed version.

### `pre-skill-gate.py` (always-on rule 1)

It blocks an action until every skill its always-on row names was opened with the Skill tool, or typed as `/mergeworthy:<name>`, since the session's last compaction; a subagent counts only its own. The block names each skill and its row.
- The table is `ACTIONS` in `hooks/pre-skill-gate.py`; `post` and `writing` gate every post (`gh pr create`, `gh pr edit`, `gh issue create`, `gh pr review`, comments and `gh api` writes, `post-lint`, `gate-pass`).
- `post-lint --kind` adds the kind's skill: `reply` (and `inline`), `proposal` → `design`, `pr` → `pull-request`, `issue` → `open-issue`, `tracker` → `task`.
- `gh-watch-start`: `task`. `thread-context` (building a record): `post`. Any `gh` command with `--attach`: `evidence`.
- `gh pr ready`: `pull-request`, `merging`; `gh pr merge` and `git push`: `merging`; `gh pr create` and `gh issue create` also `task`. `pr-steps approach`: `pull-request`; the other `pr-steps` records: `converge`.
- A gated action whose transcript can't be read is blocked.
- Starting an agent (`Agent`, `delegate_task`, `codex exec`, `claude -p`) or editing a brief or prompt file: `delegate`. Editing a skill, `always-on.md`, `AGENTS.md` or `CLAUDE.md`: `rules`.
- `code`, `finality` and `docs` are ungated: `code` reaches agents by path in their briefs, `finality` has pre-bash-guard's third-proposal block, and no tool call tells docs apart.

- `session-start` records, in `~/.mergeworthy/sessions/<session id>`, the skill catalog of the plugin folder the session loaded (`graph` or `v1`), at start, resume and compaction. A session recorded on `v1`, or with no record (it started before this install), has the old skills loaded: an old name it opened satisfies its successor (`core` → `task`; `github-threads` → `post`, `reply`; `design-loop` → `design`; `delegating` → `delegate`, `rules`).

Read-only commands pass.

**`pre-agent-dedupe`** registers launches that ran by ticket and title and blocks duplicate jobs (`delegate` step 1). A `clientRequestId` may retry within ten minutes; later reuse is blocked. It also blocks:
- a brief with any role but `research` or `test` that names a repo (`owner/repo`, its URL or a path in its checkout) but not its existing `~/.mergeworthy/projects/<owner>/<repo>.md`;
- an `implementation` brief for such a repo that doesn't name `skills/code/SKILL.md`, and a brief that reads a `thread-context.md` but doesn't name `skills/writing/SKILL.md`;
- a brief naming a linked worktree (not the launcher's own), in its launch text or the brief file it follows, that a process has as its cwd or an agent transcript written in the last five minutes names, unless T3's state shows that transcript's task completed, with no run of it queued or running and no task it started still running;
- a `review` launch whose `clientRequestId` ends in round 4 or later (`<review>-<round>`, a trailing date aside), unless the task names security, permissions, auth, data loss or concurrency and the round is at most 5 (`delegate §Review rounds`);
- a fourth agent open at once for the same session (`delegate` step 1): a job is open until `agent-job done` releases it or its agent finished (`agent_jobs.py`); memory-refresh jobs and a brief with a `Fan-out: <finality step 2 or 3, or converge §Running the agents>` line don't count;
- an implementation, drafter (`thread-context.md`) or fresh-reader (`MERGE AS IS`) brief for a repo whose project file's `## Who decides` links no `<repo>.study.md` with a first line `Studied: <date>` within 30 days (`task` step 4);
- a brief pinning an older commit of a linked worktree it names, printing `memory.md`'s Ruled out list;
- a brief still holding a placeholder of a fenced template in `skills/delegate/` (`<the slice's risky edges>`), naming each and its template; one in backticks there (the agent's output form), the pasted `agent.md`'s and an HTML tag don't count;
- in a main session's checkout, a research brief (`role: research`, or research in its title) without a `Topic:` line, or whose topic words (all of them in one paragraph) all appear in a file under the work folder not named in a `Checked:` line.

### `.githooks/pre-push` (this repo)

Before `tests/all.sh`, it refuses a push in which a commit changing `skills/` or `always-on.md` has no `Cold-read: <path>` trailer naming an existing file (the cold read's record, `rules` step 4), in it or in a later commit of the push, naming each such commit.

### `netns-run`

`netns-run <command...>` runs the command in a private network namespace (`unshare -rnm`) with internet access through slirp4netns: ports inside are its own, DNS and HTTPS work (its `/etc/resolv.conf` names slirp4netns's forwarder, keeping the host's search domains), and the command's exit status comes back. It needs `slirp4netns` installed (`sudo apt install slirp4netns`).
