---
name: steward
description: "\"steward\", \"run the steward\": one on-demand pass over what GitHub owes, this machine's sessions and the PR metrics, then rule changes from the evidence and a report; nothing left running."
---

# Steward

One pass, when the user asks; after it nothing of it runs (no Monitor, daemon, schedule or agent). Its folder `<S>` is the first word of `~/.mergeworthy/steward`, else `~/.mergeworthy/work/steward/`. Run every command from `<S>`: where that file names it, that makes you the steward (`rules` step 2). Read only this machine's files, and GitHub through `gh`. Mergeworthy changes, `<S>/inbox.md`'s lines included, ship as PRs (`rules` steps 3–4, then `pull-request`, never step 5's push), at most 3 a pass.

## Steps

1. **What GitHub owes:** one watcher round; refused because a daemon watches `<S>`: stop and tell the user. Handle each new event in `<S>/events.log` by `reply` steps 1–7 (no Monitor), and each `steward owed` line (folders whose session is idle) as that session would, in that folder's files.
   Run: `steward round <S>` (its repo whole and your open PRs); `steward owed` · Record: `<S>/events.cursor`; each owed line cleared, or kept for the report
2. **The numbers:** first-pass acceptance is the goal; hours to merge and tokens per merged PR are the guardrails.
   Run: `steward metrics <S>` · Record: `<S>/metrics.jsonl`
3. **Why:** the items are each log `steward sessions <S>` lists and, from the table, a PR with its thread and sessions for the 3 slowest merges, the 3 most reworked, each closed one and 3 first-pass ones. Research agents, 5 items each, at most 3 at once, write one line per cause (looped or redone work, a correction by the user or a maintainer, a rule broken that no hook caught): `<cause> <path:line or URL> <short quote>`.
   Open: `delegate` step 3 (role research) · Record: `<S>/causes-<n>.md`
4. **Change what the evidence shows.** A cause cited from two sessions or PRs, or a gap any repo would hit: a rule fix. One repo's taste: its project file, no PR. A removal, at most 2 a pass: a hook or check `steward fired` names as a candidate, or text another skill already says (keep one, point to it). Each PR names the metric it should move (a removal: the one that would worsen if the rule was needed) and quotes short excerpts only, no secret, email or path outside `~`.
   Run: `steward fired` · Record: `<date> <PR URL> fix|removal <metric> <value now> → <expected>` in `<S>/changes.md`
5. **Report** (`writing §Reports to the user`): done, still open, needs the user; the metrics table; for each `changes.md` line whose PR merged before the last line of `<S>/passes.txt`, its metric now against the line's value, proposing a revert when a fix's is no better, a removal's is worse, or a guardrail is worse than in `<S>/metrics.jsonl` on the line's date; hunches without evidence.
   Run: `agent-job done <key>` for each job of the pass; `steward done <S> "<summary>"` · Record: `<S>/passes.txt`
