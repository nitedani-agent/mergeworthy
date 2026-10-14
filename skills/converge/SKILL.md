---
name: converge
description: "Converging a PR before it is ready, in every tier: the pipeline (finality, Loop A, Loop B, the fresh reader, gates) and the agents that run it, authority, the phantom and removal gates, stacked PRs, gates and evidence, PR bodies."
---

# Converge

Converging a pull request means working it to a final state: no reviewer, agent or verifier finds anything worth changing, and every claim in the PR is backed by evidence you observed. The same holds for a stack of PRs.

- **When:** every PR, in every tier. The tier changes the records (`core` 1.2), not the loops: on a small fix each loop usually ends after its first pass.
- **New API or protocol:** the pipeline runs on it only once the maintainer has OK'd its shape (`design-loop`, 1.4 step 5). In the user's own repos, post the walkthrough and continue on your recommendation; a reply from the user re-opens the shape (1.1.3).
- **Your role:** you are the orchestrator, and the only writer of the PR branches' git history. Subagents work read-only or in their own worktrees; you review what they produce and land it.

### The pipeline

Converged means every step below is done **on the final head**. A step that leaves no record can't be told from a skipped one, so each ends with its `pr-steps` line; the hooks refuse `gh pr create` (unless `--draft`), `gh pr ready` and a push to a ready PR until the final head has all six and the branch has its `approach` record (`pull-request` step 3; recorded once per branch, not per head). A head that changes afterwards re-runs and re-records the steps it re-opens.

**Converge per push, not per commit.** Agent runs cost the user's subscription, so spend them where they can still find something.
- **Batch:** collect the commits a round of review or a maintainer's ask produces, and converge the batch once, right before its push. A maintainer's commits get one `github-threads` 1.5 review once they stop.
- **Small follow-ups carry the pass:** a change of 80 lines or fewer that adds no behavior (tests, docs, wording) gets the quick gates and the lanes it touches, and its loop records say `carries the pass of <sha>`; no new Loop A, Loop B or fresh reader. Behavior changes, and anything over 80 lines, get the loops again, then one fresh read for the batch.
- **One review per post, not per wording fix:** after a reviewer's findings, fix them and post; a second round only when the fix changed a claim. A sha bump, an effort label or a typo is checked by `post-lint`, not by a reviewer.
- **Side work waits:** porting, tracker polish and optional improvements wait while the critical path waits on someone else, unless they block it.
- **Fewer turns, smaller contexts:** cache reads (context size × turns) dominate the cost. The orchestrator keeps one background wait for all its agents and the watcher, not one per job; an agent works its brief in as few turns as it can, batching tool calls, and never polls with sleep loops; a brief points to files instead of pasting them.

#### 0. The design is agreed, and the area is clean

A new API, protocol or behavior is built only once the thread has agreed its shape (`design-loop`; in the user's own repos, the walkthrough is posted). Building first ships a PR the design will reshape.

When the work reshapes existing code, or a small change can't be made cleanly because of past patches, open `finality`. Its Phases A and B are the analysis while planning (`pull-request` step 3), and Phase C is the build. Skip it otherwise.

#### 1. Loop A: does it break anything?

- **Who:** one agent, kept for the loop's whole life. It runs `verify`'s verifier brief on the diff, one report section per slice.
- **You:** decide each reproduced bug's root-cause fix; an implementer (`delegating`) lands it, and the same agent gets the commits.
- **Done when** every slice has a pass with no bugs after its last fix, and its output file ends with a line `NO BUGS`.
- **Record:** `pr-steps verify <its output file>`

#### 2. Loop B: is it good code?

- **Who:** one agent, after Loop A finds no bugs. In one prompt, each into its own output file: first `review`'s reviewer charter, then `guardian`'s brief with `refactor`'s prompt. Reviewing first fills the context it rates with.
- **You:** decide which findings land; an implementer (`delegating`) lands them commit by commit, gates after each, and the same agent gets the commits. A bug its review finds is fixed, and Loop A re-verifies that slice.
- **Done when** its review ends `CLEAN` ("nothing worth changing" is an honest result) and its last re-rating lists every file, function and piece of logic with old ⇒ new ratings and the ✅ lists, high and justified.
- **Record:** `pr-steps loopb <its captured final-message file>` and `pr-steps refactor <its last re-rating>`; keep the reviewer charter’s full report separately.

#### 3. Loop A again, on Loop B's commits

- **Who:** the Loop A agent, sent Loop B's commits. It compares the tree before the refactors with the head (`verify`, after the refactors).
- **Done when** the slices those commits touch find no bugs again (`NO BUGS`), or Loop B landed no commits (the file says `NO LOOP B COMMITS`).
- **Record:** `pr-steps reverify <its output file>`

#### 4. The fresh reader

- **Who:** a new agent that hasn't seen the fixes, in `review`'s order (another company's model first), after `git fetch origin` and `git merge origin/<base>` on the PR branch, with conflicts resolved and gates rerun. The loop agents judge their own suggestions; a cold reader catches what that hides.
- **Before it:** write the PR body draft (`pull-request` step 7, `drafts/pr-body.md`) and pass `post-lint --kind pr`.
- **What it runs:** the verifier brief, the reviewer charter, and the posting gate's review (`github-threads` 1.6 step 3) of that draft, checked against the head. Where finality ran, also the guardian brief: only DELETE-NOW, FIX, FILL or DELETE-CAREFULLY items worth their price count, and OWNER-DECISION rows go on the owner's list.
- **You:** its findings go back to step 1 or 2. If the head then changed only by those fixes, continue the same reader; otherwise start a new one.
- **It reads as the maintainer who merges.** Its brief names that person (from the notes file's "Who decides", else `gh pr list --state merged` mergers and `git log --format=%an` on the touched files), the notes file `~/.mergeworthy/projects/<owner>/<repo>.md`, the repo study, and their last review comments and commits on our PRs. It answers "You are <maintainer>: which comments would you leave, and would you merge this exactly as it is?", each finding citing something they said or did, with its link. Output: `MERGE AS IS: yes`, or `no` with each finding.
- **Done when** its output has `MERGE AS IS: yes` and its final message is exactly `CLEAN`. That reviews the body draft as it stands; step 5 reviews it again after the evidence is added.
- **Record:** have the reader write its merge-as-is report ending `CLEAN` to `drafts/fresh.report.md`, and capture only its final message in `drafts/pr-body.review.out`. Run `pr-steps fresh <abs>/drafts/fresh.report.md`; the posting gate uses `<abs>/drafts/pr-body.review.out`.

#### 5. Gates, body and closure

- **You:** have a smallest-tier agent (`delegating`) run every gate and product lane on the final head; CI is green, or only workflow approval is pending (ready for review, never merge, per `merging`’s CI-limits exception); the PR bodies are true to that head (`mergeworthy:writing`). Where finality ran, its Owner-Safe closure comes last, with the review and guardian evidence attached.
- **The evidence goes in the PR body,** just enough to prove each step ran: one collapsed block per step above, plus an "Approach" block (the candidates and ratings, linking the gist of `pull-request` step 3), its runs newest first, each with the head it ran on. It says in plain sentences what ran and what came of it ("I rated every file and function with its reason and re-rated until nothing worth changing was left"), names a finding that changed the PR, and links the full output in a gist a person can read: first how many passes ran and what each found, then the commits, what stays below the bar and why, then one line per item, grouped by area. Claim only what ran on that head.
- **After adding the completed runs’ evidence, run `github-threads` 1.6 on the final body draft again.** This posting-only review is separate from the recorded fresh-reader step; capture its verdict for the updated draft.
- **Done when** every gate exits 0. Write each as `<command> -> exit <code>`, one per line, into a gates log.
- **Record:** `pr-steps gates <the gates log>`

Optional owner recommendations do not block convergence; approval required by the pipeline’s entry conditions does. Present unresolved recommendations as decision blocks with your pick, in the PR or your report (`writing`).

### Docs go through with the code

Docs, READMEs and JSDoc a user reads are part of the diff, so each step above covers them in the same pass, never in a separate one afterwards:
- **Loop A:** every sentence about behavior is a claim; reproduce it against the head like any other ("only the most specific `path` runs" gets a spec or script). A sentence the code contradicts is a bug in the docs or the code (Docs are the contract, below).
- **Loop B:** the `docs` skill's placement and shape: the right page, the minimum, no internals, history or hedges a user can't act on, the length of the siblings.
- **The fresh reader:** also gets the rendered page and two sibling pages alone, and answers the `docs` skill's two questions: can I do the task from this, and which sentences read unlike the siblings.
- **Gates:** the project's docs lint, spellcheck and docs build.

### Running the agents

- **Continue, don't restart.** After every fix, continue the loop's agent (`delegating`, one run), so it re-checks changed slices in Loop A and audits the whole scope in Loop B (`verify`, `guardian`). Loop A runs repros and Loop B rates code, so they get separate agents, except on a small diff (Tier S, under about 300 lines), where one agent runs both.
- **A long list of Loop B findings** goes to one implementer agent in its own worktree (`guardian`'s implementer brief); you review its diff before landing (1.10).
- **Slices.** A diff over about 1500 lines is split into slices that each fit (`verify`), with their own loop agents; in a stack, each PR has its own.
- **What they read.** Read the head’s code in full at the brief’s pinned SHAs (`delegating` 1.10). A finality graph (Phase A) is only a navigation index.
- **A new loop agent** starts, given the last report, once its context passes about 100k tokens: every continued turn re-reads the whole history from cache, which is most of the cost. A changed decision packet goes to the running agent.
- **A maintainer's commits** are owner code (Authority), reviewed per `github-threads` 1.5.
- **Execution:** gates, tests and log mining run on the smallest tier (`delegating`); verifiers, reviewers and guardians still run the checks their charters require them to observe personally.

### Git and files

- **Staging:** stage files by name; never `git add -A` on a tree you share.
- **Stash:** never a bare `git stash`, because the stash stack is shared across worktrees and sessions. Stash with a unique message and apply by SHA.
- **Rewriting history:** rewrite only local, unpushed commits, and only to fix that same commit (a red gate on it, a comment that isn't true) or to replay them onto commits others pushed. Pushing follows 1.7 (`merging`). Never propose mutative git operations to the user.
- **Prompt and text files:** write them with a quoted heredoc (`<<'EOF'`). An unquoted heredoc runs the backticked commands inside the text.
- **Trailers:** every commit ends with the attribution trailer the environment gives you. PR bodies end with the generated-by line and stay under 65,536 characters.

### Authority: what's settled, what's the owner's

Keep the decision packet current and give it to each subagent; preserve settled picks and propagate the newest owner decision (`core` 1.1.4, 1.1.9 and 1.2).

**The owner's code is deliberate,** in the user's repos too:
- **Owner code:** a commit authored by a human account, or without the agent trailer the environment gave you.
- **Never on an agent's reading alone:** owner code is never removed or rewritten on an agent's reading alone. That includes trimming it, "simplifying" it, or deleting a mechanism in it as phantom or overbuilt. Such findings go on the owner's list with a recommendation.
- **Agent code:** an agent's own earlier code can be changed freely. If an agent removed an owner line, restore that line.
- **The user's own repos:** changing the user's code as the task needs is yours to decide (`core`, the task). A rewrite the user asked for replaces all of their code: nothing of the old code is carried over or protected, and none of it goes on their list. Removing or rewriting it on an agent's reading alone (a finding, a cleanup on your own initiative) goes on the user's list with a recommendation. A removal that passed the removal gate (a probe that could fail, run in the owning lane, stayed green) is not a reading alone: make it, and report it with the probe.

**Behavior and public surfaces.** Ask external maintainers before changing their behavior or public surface, and decide changes authorized by the user’s task (`core`, The task and 1.1.9); refactors preserve behavior.

**Docs are the contract.** When code and docs disagree, the code is the suspect; never change docs to match code.
- If the fix is straightforward and the docs' promise is clearly intended, fix the code.
- Otherwise ask the owner on the open PR, or in an issue where 1.1.7 allows one: the doc line, the observed behavior, the question.

**Ask the owner little.** Ask only for decisions you cannot make, with your recommendation (`core` 1.1.3). Decide the rest, and say in the PR body what you decided and why.

### The phantom gate (every fix must pass it)

A phantom fix must not ship. A fix is phantom if any of these holds:
- **No real, documented usage reaches it.** Name the documented scenario, and trace it on both ends: client and server, caller and callee, sender and receiver. A bug that one layer "has" is not a bug if another layer already owns that behavior.
- **It changes a deliberate behavior,** such as a usage error the code raises on purpose, a documented limit, or an owner's design.
- **Reject comments that are not literally true** (`writing`).
- **Reject a mechanism for an unreachable state;** assert the invariant or add nothing (`guardian`, BLOAT).

Every fix also follows these:
- Keep usage errors visible; use a silent fallback only with explicit approval and a written reason the root fix is impossible (`core` 1.1.6).
- **Fix the root cause with the smallest diff** (`core` 1.1.6 and 1.1.15). Don't bundle new protocol concepts, handshakes or probes unless asked.
- **Call site, not default.** The fix goes at the call site, not into a changed default that other callers depend on.

### The removal gate (every deletion of a mechanism must pass it)

"No test fails without it" doesn't prove a mechanism is phantom. Before removing a guard, a dedup, a retry or a memo:
- **Probe the symptom.** Name the symptom the mechanism prevents. Probe that symptom through documented usage against the real threshold: listener counts and MaxListeners warnings, timers, memory, ordering, duplicate delivery.
- **In the owning lane.** Run the probe in the product lane that owns the mechanism (the real transport, backend and runtime), not only in unit tests.
- **A product-shaped failure keeps it.** The mechanism stays, recorded as GENUINE-CONFIRMED (the guardian charter's mark for a mechanism a probe proved necessary) with the failure text; count confirmed-kept mechanisms alongside deleted ones in status.
- **Repaired twice is suspect.** Re-probe whether a mechanism repaired twice needs to exist at all.
- **The backstop:** the final bug verification after the refactors (`verify`) compares the pre-refactor tree with the head.

### Stacked PRs (when a feature PR also fixes the base code)

Verifying a feature can turn up bugs in the code the feature builds on.
- **Bugs the feature doesn't need fixed** become their own PRs (1.1.16).
- **Bugs the feature needs fixed** go into a stack, but only when the bottom PR builds alone on `main` and `gh stack` can link the two (`pull-request` step 4).
- **Otherwise** they stay in the feature PR, one commit per bug.
- **Finality's refactor commits of base code** go in the bottom PR, before its fixes, when the fixes need the new shape; otherwise they're one refactor PR of their own (1.1.16) that the bottom PR depends on.

A stack has two PRs:
- **Bottom PR (base main):** those fixes, one bug per commit, each proven by a repro that fails on main (kept as a test per 1.1.16). Where the feature PR fixed a bug in several steps, the bottom PR carries only what those steps amount to.
- **Top PR (base = the bottom PR's branch):** the feature. The top PR contains the bottom PR through merge commits, never a rebase, so it never needs a force-push.
- **Link them:** `gh stack link <bottom> <top>`.

After every merge of the bottom into the top:
- **Conflicts:** feature code keeps the top's version; specs get the union of their tests.
- **Tests:** check that every test name of the bottom's specs still exists in the top, or was replaced on purpose. Merges silently drop tests.
- **Diff:** check that the top's "Files changed" view shows only feature lines.

**Placement.** A fix belongs in the bottom PR if it's a bug on main by itself. It stays in the top PR if its failure needs the feature's code. Trace the named failure to decide.

### Gates, lanes, flakes, evidence

- **Quick gates, after every commit:** format, type-check and units.
- **Full gates, before every push:** the quick gates; spellcheck and docs lint; the released-API or public-surface check; the runtime-specific lanes. Build the list from the repo's CI workflows, every check they run, not from memory.
- **Heavy lanes, before every push,** on each PR's head: build, then the heavy lanes the project file lists (e.g. production-mode e2e, every adapter or transport, the examples).

Failures:
- **Gates fail closed:** a gate that errors or can't run is red.
- **A failure that doesn't repeat is still a finding.** Find its cause, or file it with the logs, before calling anything green.
- **Exit codes:** "N passed" with a non-zero exit code is red.

Evidence:
- **Name the head.** Every claim names the head it ran on, and which gates ran on which head.
- **Base bugs:** a known base bug that a lane shows is recorded as the base's, with the evidence that the base fails it too.
- Mark unobserved claims UNKNOWN (`writing`).

### PR bodies

Each PR body is part of the deliverable. It is true of the final head, within 1.1.16, and written by `mergeworthy:writing`.

Keep process reports outside outward prose, except the requested PR evidence (`writing`); save working reports in the artifact root.

**Keeping it current.** Condense history; never drop current facts. When the stack moves a fix from one PR to another, move the fix's mention too.
