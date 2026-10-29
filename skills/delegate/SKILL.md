---
name: delegate
description: "Starting, continuing or checking a subagent, writing a brief, and integrating its result: one agent per job, model class and effort, the brief from a template, its result. Holds the brief templates in delegate/."
---

# Delegate

Each role's brief is a template in `~/.mergeworthy/current/skills/delegate/`, with `agent.md` included in every one.

## Steps

1. **One job, one agent.** An agent already on the job gets a message, not a twin (§Continue). At most 3 agents at a time without asking the user, except the agents a step names to run together, each brief holding its exact line `Fan-out: finality step 2` (the mappers), `Fan-out: finality step 3` (the branch agents) or `Fan-out: converge §Running the agents` (one verifier per slice); they still count against an agent without it; implementers count toward the 3; only the main session starts agents. Start a browser-heavy agent only while the 1-minute load average (`uptime`) is below the core count (`nproc`). Stop an agent as soon as its question is settled.
   Hook: pre-agent-dedupe
2. **Model class and effort.**
   Open: §Model class; reviews: §Reviewers; the project file's `## Agents` section overrides
3. **The brief.** Paste the role's template from the installed copy each time (a copy saved earlier drifts) and fill every `<…>`: the pinned current head (never a moving branch), the project file's path, the standards by path, `agent.md`, the critical-path item it unblocks, and a time budget for a long job.
   Open: `delegate/<role>.md`; §Brief · Record: the brief file · Hook: pre-agent-dedupe (pins, `Fan-out:`, the project file, its repo study within 30 days for authors and fresh readers, `Topic:`)
4. **Launch in the background;** its completion wakes you.
   Run: T3 Code: `delegate_task` with a unique `clientRequestId`; else the Agent tool · Record: the job pre-agent-dedupe registers · Hook: pre-bash-guard (wait loops), pre-agent-dedupe
5. **Liveness** at 2 minutes and at every wakeup (its output size or log time); five minutes without output: look now. A long job's first output is read within half an hour; confirm its numbers can be used (a benchmark alone on the machine, warmed up, comparing like with like) before it runs the rest; past its budget, stop it or extend it deliberately.
   Run: `task_status` · Hook: stop-lint
6. **Its result** (T3's notice, or the watcher's `### AGENT DONE <ticket>`). Read the final message; open two or three cited `path:line`s or re-run one command, and diff the result against your plan. A diff: write down each structural decision in it and why it's right before landing it; hardcoded lists and duplicated classifications get fixed before pushing. Then release the job.
   Run: `agent-job done <ticket>` · Hook: stop-lint, the watcher
7. **Relay the result to the user and act on it;** an unchecked item, a deviation and each finding (by `code §Earn every line`) are yours to decide; never send the same brief again. If the result fails your check, or the agent is blocked, redo the work on your model class with what failed.
   Open: `writing §Reports to the user`

### Brief

- **Five parts:** `Goal` (one observable outcome); `Facts` (only what you verified, each with its source); `To check` (your guesses, as questions); `Scope` (the paths and commands it may use, the semantic code-search MCP's name when your session has one, and `agent.md §Machine`, in every brief and every follow-up round); `Acceptance` (the commands or observations that define done).
- **In T3 Code,** `delegate_task`'s `role` is `implementation`, `research`, `test` or `review`. A research brief adds `Topic: <key words>` and a `Checked: <file>` line per work-folder file already read: pre-agent-dedupe blocks one already written up in an unchecked file.
- **Never put in** your opinion, the answer you expect, or earlier agents' conclusions: a guess goes under `To check`. The exception is a previous round's report, given to an agent that re-rates it. A maintainer's ask goes in quoted whole: an either/or stays an either/or; the implementer reads the code each option touches and recommends one, saying why, and the main session decides before it lands.
- **Give paths and the question,** never pasted files or long histories.
- **One run is one agent with one prompt.** Group roles reading one artifact in one loop, in order, each writing its own file. Split only for context limits or independence: authors never review themselves, and fresh readers haven't seen the fixes.

### Continue

Later work on the same thing (confirming fixes, re-rating) continues that agent; a new one re-reads everything with a cold cache.
- **Claude Code:** `SendMessage` to its agent id.
- **T3 Code:** `t3_thread_send` to its `childThreadId` with mode `queue`, asking it to write its result to a file; a background wait on that file wakes you.
- **A review round in T3 Code:** a new `delegate_task` whose prompt carries the earlier report and what changed, never `t3_thread_send` (T3 Code's own rule). That counts as continuing the same reviewer.
- **Codex in a shell:** `codex exec resume -c sandbox_mode=danger-full-access <session id> "<what changed>"` (the id `codex exec` printed, never `--last`).
- **An agent is alive until its transcript and processes are quiet,** whatever T3 shows: a turn that ended, `waiting_for_children`, or a cancel that finds "no interruptible run" mean it wakes when its background commands end, and `t3_queue_promote_to_steer` can revive a run T3 calls `interrupted` or `cancelled`. Continue a stuck agent with a message; a replacement goes in a fresh worktree. When two agents run one job, keep the one with the most progress.

### Model class

The classes are model families, never versions: the strongest class is the newest Opus your harness offers, and the smallest class that has an effort setting is the newest Haiku. The main session runs on the strongest class: it plans, briefs, decides, spot-checks results and approves every word to a maintainer. Never a model the user excluded, nor a model version in a prompt, skill or memory.
- **Root causes and choosing among approaches** (`pull-request` step 5): the main session's class at high effort.
- **Authors** (code, docs, PR bodies, replies, designs): the main session's class at high effort. **Judges** (verification, every `converge` loop agent, audits, exploration): at medium.
- **The smallest class with an effort setting, at high effort,** only for work where nothing it writes ships: running gates, tests and a reproduction from a recipe, log mining, data processing and bookkeeping.

### Reviewers

Every independent review (a post's, the Loop B review, the fresh reader, a standalone review) picks its reviewer in this order, trying the first each time: an earlier "unavailable" note (memory, a post's badge) is no check:
- **First, a model from another company than the main session's:** on its default model, at the effort chosen per call (high; medium for a few-sentence reply). In T3 Code, one `delegate_task` per round, the reviewer's `providerInstanceId` from `orchestrator_capabilities`:
   ```json
   {"task": "Follow <prompt file>; output to <out>", "role": "review", "target": {"providerInstanceId": "<id>", "options": {"<its effort option>": "<effort>"}}, "clientRequestId": "<loop>-r<N>"}
   ```
   Elsewhere, a Codex reviewer: `codex exec -c model_reasoning_effort=<effort> --sandbox danger-full-access --skip-git-repo-check -o <out> "$(cat <prompt file>)" < /dev/null`; a Claude reviewer: `claude -p --effort <effort> --permission-mode bypassPermissions < <prompt file> > <out>`.
- **Else, a fresh agent of the main session's class,** with the same prompt, when the first fails (spent credits, rate limits, errors, timeouts, no reply). An incomplete review didn't fail: its reviewer finishes it (§Continue).

The prompt is a file with the template filled. When one run follows several briefs, each writes its own file. Never write `CLEAN` yourself. Send fixes to the same reviewer (§Continue); a fresh one only when the artifact changed beyond them or needs a final cold read. Record which reviewer ran (Tier M: a `ledger.md` row); on Tier M or L work, re-review on the other company's model once it's back.

### Review rounds

Every review loop:
- **Severity:** re-rate each label (`agent.md`) yourself; nits (findings nobody hits in practice) get no code.
- **Budget:** 3 rounds (re-checks included) per loop, never renewed or raised. Name each round `<loop>-r<N>` (T3's `clientRequestId`, the Agent tool's `description`, a shell reviewer's prompt file). Replacing the implementation with a different approach starts a new loop with a new name; fixes to the existing approach keep its round count.
- **Round 1's prompt** asks for every finding exhaustively; **from round 2,** it says outside the changes and open ids only a blocker or regression counts (not the fresh reader's). Before each round, cut what the fixes added beyond need.
- **Ledger:** `<work folder>/drafts/<review>.ledger.md`, one line per finding: `<id> <label> <outcome>` (fixed in <sha>, disputed: <evidence>, declined: <why>), the id `R<round>.<n>` from its first round.
- **Stuck:** a finding the reviewer holds after two disputing replies of yours, or open at the budget's end, goes to the user, both sides in 2–3 lines. Rule on evidence, never to end the loop.
- **While a round runs,** leave what it reads unchanged.
