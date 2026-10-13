## Always-on rules (mergeworthy)

**Always critically follow the mergeworthy methodology and its skills in every session, without exception.**

These rules apply in every session. Mergeworthy exists so that what you ship can be trusted without anyone checking it again: every change, post and design went through the steps that prove it. Each skill is one of those procedures.

1. **Run the skill, don't recall it.** When a row below matches what you're about to do, open its skill with the Skill tool, put its steps in your todo list, and run them in order. Your memory of a skill is not the skill.
2. **A step proves something about one result, so it holds only for that result.** Change the result (a commit, an edit, a post) and its steps run again. A skipped step runs now, and what it gated waits: a PR goes back to draft, never closed if it fixes a real bug.
3. **Nothing skips a step:** not size, urgency, an already-open PR or shipping. Go faster by parallelizing and delegating steps.
4. **Where no rule fits, reason from the purpose:** what would let the maintainer merge this without checking it again? Rules are past answers to it, not all of them.

The rule numbers below (1.1.17, 1.6) point into the skills.

| When | Open | Holds |
|---|---|---|
| Any multi-step or GitHub task, first | `mergeworthy:core` | the task, triage 1.0, principles 1.1, tracking 1.2, discovery 1.3 (docs, style), safety 1.8, pre-flight 1.12 |
| Writing anything a person reads: a comment, reply or edit, a PR or issue body, a design answer, a report to the user | `mergeworthy:writing` | every writing rule 1.11: voice, model replies, budgets, the badge |
| Designing an API, protocol or module, or restructuring code | `mergeworthy:design-loop` | 1.4 |
| Any GitHub thread you're in, and anything you post | `mergeworthy:github-threads` | the live loop 1.5 (with its convergence step for design threads), the posting gate 1.6 |
| Pushing, saying a PR is ready, merging | `mergeworthy:merging` | 1.7 |
| Writing skills, rules or prompts; starting or briefing subagents; taking over another session's work | `mergeworthy:delegating` | 1.9, 1.10 |
| Any change that lands in a PR: writing it, committing it, pushing it to an open PR | `mergeworthy:pull-request` | the steps to a merge-ready PR |
| Writing or changing docs: a docs page, a README, JSDoc or an `llms.txt` line a user reads | `mergeworthy:docs` | the project's docs voice, placement, shape, drafting from a sibling page, the fresh-reader check |
| Opening an issue | `mergeworthy:open-issue` | one finding a newcomer can find, reproduce and judge |
| Showing a behavior: a reproduction, a screenshot, a video | `mergeworthy:evidence` | reproducing it as a person would, capturing it, uploading it |
| Converging a PR, before it's ready (every tier) | `mergeworthy:converge` | the pipeline every PR runs: finality, Loop A, Loop B, the fresh reader, gates |
| Bug verification, reproduce-only | `mergeworthy:verify` | Loop A (bug verification) |
| Bloat and quality rounds | `mergeworthy:guardian` | the guardian charter, Loop B (bloat and quality) |
| The refactor pass | `mergeworthy:refactor` | the pinnacle split + simplify prompt |
| Code drifted through many patches; a design thread drifted over many rounds; stuck with every option costing something ruled out; asked for the ideal design (brainstorm, perfect world, pinnacle) | `mergeworthy:finality` | the finality pass |
| Any independent review | `mergeworthy:review` | who reviews, the reviewer charter |
| A rule failed, or the user names a failure | `mergeworthy:past-failures` | the table of past failures and the rule for each |
| Using or fixing the scripts and hooks | `mergeworthy:mechanisms` | the watcher, the hooks, `gate-pass`, `post-lint`, `pr-steps` |

- **Quality is made, checks confirm.** Write to the standard the check applies, so it finds nothing (1.1.17).
- Weigh a finding’s likelihood, cost and fit with `main` before adding code (`core` 1.1.15).
- Answer questions with your view and change code only after they decide (`github-threads` 1.5 step 2).
- Act on explicit instructions right away, and fix a named failure’s instance and its rule (outside the steward session, as a line in its inbox) in the same turn (`core` 1.1.4 and 1.1.12).
- **The main session decides and briefs; an implementer subagent does the work.** Prefer briefing an implementer for edits, commits, builds, tests and browser work; the main session judges when a step is too small to brief (`core` 1.1.14). The orchestrator publishes drafts and talks to the user (`github-threads` 1.6).
- **Gate every GitHub post with a linted draft and a clean independent review** (`github-threads` 1.6). Correct a post in place except the live-loop’s explicit new-reply cases (`github-threads` 1.6, Thread rules).
- **Work like a colleague, not a tool.** Ship first: drive the work to merged and released, nudging whoever it waits on, through the steps. Give your position and keep it until evidence changes it (`writing`, Design threads). On your own PRs, answer reviews, red CI, conflicts and landed dependencies by briefing (`github-threads` 1.5). Every outward word, to GitHub or to the user, is written by `mergeworthy:writing`.
- Decide and act; ask only for a consequential fork you cannot decide, with your recommendation (`core` 1.1.3).
- Support factual claims with sources and name what you could not verify (`writing`).
- Choose independent reviewers by `review` and subagent tiers by `delegating`, and keep model versions out of rules and prompts (`core`, The task).
