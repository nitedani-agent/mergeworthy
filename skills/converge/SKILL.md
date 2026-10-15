---
name: converge
description: "Converging a PR's head before it is ready, in every tier: the design agreed, Loop A, Loop B, Loop A again, the fresh reader, gates and the evidence blocks; batching, running the agents, stacked PRs."
---

# Converge

Working a PR's head to a final state: no reviewer, agent or verifier finds anything worth changing, and every claim in the PR is backed by evidence you observed. Called by `pull-request` step 9; when done, return there. Each step ends with its `pr-steps` record, and the five records (verify, shape, reverify, fresh, gates) must all be on the final head: pre-bash-guard refuses `gh pr create` without `--draft`, `gh pr ready` and a push to a ready PR until they are, and until the branch has its approach record (`pull-request` step 5). A head that changes afterwards re-runs the steps it re-opens. Subagents work read-only or in their own worktrees; only you write the PR branch's history.

## Steps

0. **The shape is agreed and the area is clean.** A new API, protocol or behavior is built only once the maintainer OK'd its shape (`design` step 9); in the user's own repos, once the walkthrough is posted. Code being reshaped, or a change that can't be made cleanly because of past patches: `finality`. Size the batch first (§Batching): a change of 80 lines or fewer that adds no behavior carries the pass.
   Open: §Batching; `finality` · Hook: pre-bash-guard
1. **Loop A: does it break anything?** One verifier per slice (§Running the agents), kept for the loop's whole life. You decide each reproduced bug's root-cause fix; an implementer lands it; the same verifier gets the commits. Under each line of the verifier's `## Dropped` whose reason says "not a regression", "no documented usage", "rare" or "same as main", you write `RULED: <candidate>: <ruling>`: a bug to fix, or why it isn't one. Done when every slice has a pass with no bugs after its last fix, and its file ends `NO BUGS`.
   Open: `delegate/verifier.md`; `delegate/implementer.md` · Run: `pr-steps verify <its file>` · Hook: pre-bash-guard
2. **Loop B: is it good code?** After Loop A, one agent in one prompt, each into its own file: first the reviewer brief, then the shape pass (cut what shouldn't exist, reshape what stays, rate every file and function old ⇒ new). You decide which findings land (`code §Earn every line`); an implementer lands them commit by commit, gates after each, and the same agent re-rates (`delegate §Continue`: in T3 Code, a new task carrying its report). A bug its review finds is fixed, and Loop A re-checks that slice. OWNER-DECISION rows go in the PR body's decision blocks (`writing §Forms`) or your report. Done when its shape report lists every file, function and piece of logic old ⇒ new with the ✅ coverage list, high and justified, and ends `CLEAN`.
   Open: `delegate/reviewer.md`, `delegate/shape.md`, `delegate/implementer.md` · Run: `pr-steps shape <its shape report>` · Hook: pre-bash-guard
3. **Loop A again, on Loop B's commits.** Continue the Loop A verifier with them.
   Open: `delegate/verifier.md` §After refactors · Run: `pr-steps reverify <its file>` (`NO BUGS`, or `NO LOOP B COMMITS`) · Hook: pre-bash-guard
4. **The fresh reader, with the maintainer's eyes.** Merge `origin/<base>` into the branch, resolve, rerun the gates; write `drafts/<pr>/pr-body.md` by `pull-request §Body` (`pull-request` step 10 finishes it after this step) and pass `post-lint --kind pr`. No project file for the repo: the repo study first (`task §Repo study`). Then a new agent, in `delegate §Reviewers`' order: it reviews as the maintainer who decides, citing what they said or did. Its findings go back to step 1 or 2, and the main session puts each line under its "New to the study" into the project file and the study, and fixes each under "Stale in the project file", in the same step (`rules` step 6's TASTE, with its sweep of our open PRs); then a new reader, blind to the fixes and the earlier report, reads again. Done when its report names the maintainer, says `MERGE AS IS: yes`, and its final message is exactly `CLEAN`.
   Open: `delegate/fresh-reader.md` · Run: `git fetch origin && git merge origin/<base>`; `pr-steps fresh <work folder>/drafts/fresh.report.md`; the reader also writes its post-review section's verdict alone (exactly `CLEAN`, or that section's findings) to `<work folder>/drafts/<pr>/pr-body.review.out`, which counts as `post` step 3 for the body's gate · Hook: pre-bash-guard
5. **Gates and body.** A smallest-class agent runs every gate the CI workflows run, and the heavy lanes, on the final head into a log of `<command> -> exit <code>` lines, a test run's ending `(N tests)`. CI green, or only workflow approval pending (`merging §CI limits`). The body's evidence blocks (§Evidence blocks), then `post` step 3 again on the final body. Where `finality` ran, its closure (`finality` step 7) comes last. Optional owner recommendations don't block; approval the entry conditions require does.
   Open: `code §Gates`; §Evidence blocks; `post` step 3 · Run: `pr-steps gates <the log>` · Hook: pre-bash-guard

### Batching

Agent runs cost the user's subscription, so converge per push, not per commit.
- **Batch:** collect the commits a review round or a maintainer's ask produces, and converge the batch once, right before its push. A maintainer's commits get one review once they stop (`reply §Maintainer commits`).
- **Carry the pass:** a change of 80 lines or fewer that adds no behavior (tests, docs, wording) gets the quick gates and the lanes it touches, and its loop records say `carries the pass of <sha>`, unless a maintainer asked for a pass since: run and record one, on the unchanged head too; no new Loop A, Loop B or fresh reader. Behavior changes, and anything over 80 lines, get the loops again, then one fresh read for the batch.
- **Every edit to a post goes back to its reviewer** (`post` step 3), a typo or a sha bump too; the fast form keeps a one-word fix cheap.
- **The shape pass goes stale** past 80 changed lines since its last full pass (tests and lockfiles excluded; the watcher's `### SHAPE STALE`): a fresh agent runs it on the whole diff before the next "Done" reply.

### Running the agents

- **Continue, don't restart** (`delegate §Continue`): after every fix, the slice's Loop A verifier re-checks what changed and the PR's one Loop B agent re-audits the whole diff. Loop A and Loop B get separate agents, except a Tier S PR whose diff is under ~300 lines, where one agent runs both.
- **A long list of Loop B findings** goes to one implementer in its own worktree, taking the slices one after the other. Review its diff before cherry-picking; cherry-pick onto the PR branch, run the full gates and the lanes the changes touch, then continue the Loop A verifier with the commits.
- **Slices:** a diff over about 1500 lines is split (`delegate/verifier.md` §Slices); each slice gets its own verifier, and an implementer only when the slices don't fit one context; one Loop B agent covers the whole PR in one shape report (step 2).
- **What they read:** the head's code in full at the brief's pinned SHAs. A finality graph is only an index.
- **A new loop agent,** given the last report, once its context passes about 100k tokens. A changed decision in `decisions/*.md` goes to the running agent.
- **A maintainer's commits are owner code** (`code §Owner code and authority`).

### Stacked PRs

When a feature PR also fixes the base code it builds on:
- **Bugs the feature doesn't need fixed** become their own PRs.
- **Bugs the feature needs fixed** go into a stack, only when the bottom PR builds alone on `main` and `gh stack` can link the two; otherwise they stay in the feature PR, one commit per bug.
- **Finality's reshaping commits of base code** go in the bottom PR, before its fixes, when the fixes need the new shape; otherwise they're one refactoring PR of their own that the bottom PR depends on.
- **Bottom PR (base `main`):** the fixes, one bug per commit, each proven by a repro that fails on `main` (kept as a test only per `code §Tests`). Where the feature fixed a bug in several steps, the bottom PR carries only what they amount to. A fix belongs here if it's a bug on `main` by itself; it stays in the top PR if its failure needs the feature's code.
- **Top PR (base: the bottom PR's branch):** the feature, containing the bottom through merge commits, never a rebase. Link them: `gh stack link <bottom> <top>`.
- **After every merge of the bottom into the top:** feature code keeps the top's version, specs get the union of their tests; check every test name of the bottom's specs still exists in the top (merges silently drop tests); check the top's "Files changed" shows only feature lines. When the stack moves a fix, move its mention in the bodies too.

### Evidence blocks

Just enough to prove each step ran: one collapsed block per step above, plus an Approach block (the candidates and ratings, linking a gist of `approach.md`), its runs newest first, each naming its head. In a PR body, each `<summary>` starts with a title whose block post-lint neither counts nor lints: Approach, Loop A, Loop B, Refactor pass, Fresh read or Gates (in a repo with a `Language:` line, that language's, in `hooks/post_words.py`). Each says plainly what ran and what came of it, names a finding that changed the PR or says nothing was worth changing, and links the full output in a readable gist: how many passes ran and what each found, then the commits, what stays below the bar and why, then one line per item, grouped by area. Claim only what ran on that head.
