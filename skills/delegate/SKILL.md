---
name: delegate
description: "Starting, continuing or checking a subagent, writing a brief, and integrating its result: one agent per job, model class and effort, the brief from a template, its result. Holds the brief templates in delegate/."
---

# Delegate

The main session decides and briefs; a subagent does the work in its brief. Each role's brief is a template in `~/.mergeworthy/current/skills/delegate/`, with `agent.md` included in every one.

## Steps

1. **One job, one agent.** An agent already on the job gets a message, not a twin (§Continue). At most 3 agents at a time without asking the user, except the agents a step's own text names to run together (`finality` steps 2–3: the mappers, the branch agents; `converge` §Running the agents: "each slice gets its own verifier"); implementers count toward the 3; only the main session starts agents. Start a browser-heavy agent only while the 1-minute load average (`uptime`) is below the core count (`nproc`). Stop an agent as soon as its question is settled.
   Hook: pre-agent-dedupe
2. **Model class and effort.**
   Open: §Model class; reviews: §Reviewers; the project file's `## Agents` section overrides · Hook: route.py
3. **The brief.** Paste the role's template from the installed copy each time (a copy saved earlier drifts) and fill every `<…>`: the pinned current head (never a moving branch), the project file's path, the standards by path, `agent.md`, the critical-path item it unblocks, and a time budget for a long job.
   Open: `delegate/<role>.md`; §Brief · Record: the brief file · Hook: pre-agent-dedupe (pins, the project file, `Topic:`)
4. **Launch in the background;** never wait in the foreground, and no sleep loop on an agent's files: its completion wakes you.
   Run: T3 Code: `delegate_task` with a unique `clientRequestId`; else the Agent tool · Record: the job pre-agent-dedupe registers · Hook: pre-bash-guard (wait loops), pre-agent-dedupe
5. **Liveness** at 2 minutes and at every wakeup (its output size or log time); five minutes without output: look now. A long job's first output is read within half an hour; confirm its numbers can be used (a benchmark alone on the machine, warmed up, comparing like with like) before it runs the rest; past its budget, stop it or extend it deliberately.
   Run: `task_status` · Hook: stop-lint
6. **Its result** (T3's notice, or the watcher's `### AGENT DONE <ticket>`; the ticket is the key pre-agent-dedupe registered: the brief's ticket id, else its title). Read the final message; open two or three cited `path:line`s or re-run one command, and diff the result against your plan. A diff: write down each structural decision in it and why it's right before landing it; hardcoded lists and duplicated classifications get fixed before pushing. Then release the job.
   Run: `agent-job done <ticket>` · Hook: stop-lint, the watcher
7. **Relay the result to the user and act on it;** an unchecked item or a deviation is yours to decide; never send the same brief again. If the result fails your check, or the agent is blocked, redo the work on your model class with what failed.
   Open: `writing §Reports to the user`

### Brief

- **Five parts:** `Goal` (one observable outcome); `Facts` (only what you verified, each with its source); `To check` (your guesses, as questions); `Scope` (the paths and commands it may use, and `agent.md §Machine`, in every brief and every follow-up round); `Acceptance` (the commands or observations that define done).
- **In T3 Code,** `delegate_task`'s `role` is `implementation`, `research`, `test` or `review`. A research brief adds `Topic: <key words>` and a `Checked: <file>` line per work-folder file already read: pre-agent-dedupe blocks one whose topic is already written up in an unchecked file.
- **Never put in** your opinion, the answer you expect, or earlier agents' conclusions: a guess goes under `To check`. The exception is a previous round's report, given to an agent that re-rates it.
- **Give paths and the question,** never pasted files or long histories.
- **What it returns:** the result with evidence (`path:line`, or the command and its exit code) and a `not_checked` list, in a final message of at most 15 lines; the rest goes in a file the brief names.
- **One run is one agent with one prompt.** Group roles reading one artifact in one loop, in order, each writing its own file. Split only for context limits or independence: authors never review themselves, and fresh readers haven't seen the fixes.

### Continue

Later work on the same thing (confirming fixes, re-rating) continues that agent; a new one re-reads everything with a cold cache. Except the fresh reader (`converge` step 4): always a new agent.
- **Claude Code:** `SendMessage` to its agent id.
- **T3 Code:** `t3_thread_send` to its `childThreadId` with mode `queue`, asking it to write its result to a file; a background wait on that file wakes you.
- **A review round in T3 Code** (a reviewer's, a post review's, the shape pass's re-rating): a new `delegate_task` whose prompt carries the earlier report and what changed, never `t3_thread_send` (T3 Code's own rule). That counts as continuing the same reviewer. Elsewhere a review round continues its agent like any other.
- **Codex in a shell:** `codex exec resume -c sandbox_mode=danger-full-access <session id> "<what changed>"` (the id `codex exec` printed, never `--last`).
- **An agent is alive until its transcript and processes are quiet,** whatever T3 shows: a turn that ended, `waiting_for_children`, or a cancel that finds "no interruptible run" mean it wakes when its background commands end, and `t3_queue_promote_to_steer` can revive a run T3 calls `interrupted` or `cancelled`. Continue a stuck agent with a message; a replacement goes in a fresh worktree. When two agents run one job, keep the one with the most progress.

### Model class

The classes are model families, never versions: the strongest class is the newest Opus your harness offers, and the smallest class that has an effort setting is the newest Haiku. The main session runs on the strongest class: it plans, briefs, decides, spot-checks results and approves every word to a maintainer. Never a model the user excluded, nor a model version in a prompt, skill or memory.
- **Root causes and choosing among approaches** (`pull-request` step 5): the main session's class at high effort.
- **Authors** (code, docs, PR bodies, replies, designs): the main session's class at high effort. **Judges** (verification, every `converge` loop agent, audits, exploration): at medium.
- **The smallest class with an effort setting, at high effort,** only for work where nothing it writes ships: running gates, tests and a reproduction from a recipe, log mining, data processing and bookkeeping.

### Reviewers

Every independent review (a post's, the Loop B review, the fresh reader, a standalone review) picks its reviewer in this order:
- **First, a model from another company than the main session's:** Codex for a Claude session, a Claude agent for a Codex session, the strongest model of that provider the user hasn't excluded, at the effort chosen per call (high for a full review, medium for a quick check of a short reply). Start it through the orchestration tools: in T3 Code one `delegate_task` per round, the model from `orchestrator_capabilities`:
   ```json
   {"task": "Follow <prompt file>; output to <out>", "target": {"providerInstanceId": "codex", "model": "<model>", "options": {"reasoningEffort": "<effort>"}}, "clientRequestId": "<review>-<round>"}
   ```
   Without them: `codex exec -m <model> --sandbox danger-full-access --skip-git-repo-check -o <out> "$(cat <prompt file>)" < /dev/null`.
- **Else, a fresh agent of the main session's class,** with the same prompt, when the first fails (out of credits, a rate limit, an error: a failure is not a review).

The prompt is a file with the template filled. The final message is exactly `CLEAN`, or the findings, at most 15 lines; the full list goes in the output file. When one run follows several briefs, each writes its own file, and the final message is `CLEAN` only when none has a finding. Never write `CLEAN` yourself. Send fixes to the same reviewer (§Continue); a fresh one only when the artifact changed beyond them or needs a final cold read. Record which reviewer ran and what it found (Tier M: in the ledger); on Tier M or L work, re-review on the other company's model once it's back.
