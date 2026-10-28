---
name: steward
description: "\"steward\", \"run the steward\": one on-demand pass over what GitHub owes, this machine's sessions and the PR metrics, then rule changes from the evidence and a report; nothing left running."
---

# Steward

One pass, when the user asks; after it nothing of it runs (no Monitor, daemon, schedule or agent). Its folder `<S>` is the first word of `~/.mergeworthy/steward`, else `~/.mergeworthy/work/steward/`. Run every command from `<S>`: where that file names it, that makes you the steward (`rules` step 2). Read only this machine's files, and GitHub through `gh`. Mergeworthy changes, `<S>/inbox.md`'s lines included, ship as PRs, their worktrees inside `<S>` (`rules` steps 3–4, then `pull-request`, never `rules` step 5's push), at most 3 a pass; `<S>`'s next round watches them, so no `gh-watch-start`.

## Steps

1. **What GitHub owes:** one watcher round; refused because a daemon watches `<S>`: stop and tell the user. Handle each new event in `<S>/events.log` by `reply` steps 1–7 (no Monitor), and each `steward owed` line (folders whose session is idle) in that folder's files, by its kind: `reply` by `reply` steps 3–7, `sort` by `rules` step 6, `promise` by delivering it, then `DONE <link>` at its line's start.
   Run: `steward round <S>` (your open PRs, and nitedani/mergeworthy whole when `~/.mergeworthy/steward` names `<S>`); `steward owed` · Record: `<S>/events.cursor`; each owed line cleared, or, when only its folder's user or session can clear it, kept for the report
2. **The numbers:** first-pass acceptance is the goal; hours to merge and tokens per merged PR are the guardrails.
   Run: `steward metrics <S>` · Record: `<S>/metrics.jsonl`
3. **Why:** the items are each log `steward sessions <S>` lists and, from the table, a PR with its thread and sessions for the 3 slowest merges, the 3 with most commits after review, each closed one and the 3 last settled with `first_pass` true in `<S>/metrics.jsonl`. Research agents, 5 items each, at most 3 at once, write one line per cause (looped or redone work, a correction by the user or a maintainer, a rule broken that no hook caught): `<cause> <path:line or URL> <short quote>`.
   Open: `delegate` §Brief (role research: the items as Facts, this line format as Acceptance, a `Topic:` line, then `delegate/agent.md`) · Record: `<S>/causes-<date>-<agent number>.md`
4. **Change what the evidence shows.** A cause cited from two sessions or PRs, or a gap any repo would hit: a rule fix. One repo's taste: its project file, no PR. Text that repeats other text: merge it. Each PR names the metric it should move (a removal: the one that would worsen if the rule was needed) and quotes short excerpts only, no secret, email or path outside `~`.
   Record: `<date> <PR URL> <metric> <value now> → <expected>` in `<S>/changes.md`
5. **Report** (`writing §Reports to the user`): done, still open, needs the user; the metrics table; for each `changes.md` PR merged before the last pass, its metric now, proposing a revert when it didn't move or a guardrail worsened; hunches without evidence.
   Run: `agent-job done <key>` for each research agent of step 3 (its brief's ticket id, else its title); `steward done <S> "<summary>"` · Record: `<S>/passes.txt`
