# mergeworthy v3 (prototype)

The planner's reply path: `mw take | next | done` over one append-only ledger per root, and a replay of the RSC
orchestrator's history through it. See /home/nitedani/steward-work/v3/prototype-report.md for the results.

- `bin/mw`: the three verbs. `MW_ROOT` names the root (its `ledger.jsonl`), `MW_NOW` fixes the clock.
- `lib/planner.mjs`: every item's next action in one priority order; `lib/reply.mjs`: the reply procedure's steps;
  `lib/classify.mjs`: what a comment asks; `briefs/*.md`: the templates the planner fills.
- `replay/`: `extract-log.mjs` (session log to timeline), `run.mjs` (the replay), `judge.mjs` (scoring), `table.mjs`.

Tests: `node --test`.
