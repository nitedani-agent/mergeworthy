---
name: review
description: "Reviewing a PR you didn't write, or any standalone review: an independent reviewer with the charter filled, findings settled by runs, posted through post."
---

# Review

## Steps

1. **Read the PR, its issue and its thread;** pin the head SHA.
   Run: `gh pr view <N>`, `gh pr diff <N>`
2. **Start an independent reviewer** with the brief filled: the diff against the merge base, the issue, the one-sentence claim, the defect and its sibling sites, the project file's path, `review-context` output run at the head, and the gates' outputs where it can't run them. No independent reviewer available: record the block, tell the user, and post nothing.
   Open: `delegate §Reviewers`; `delegate/reviewer.md` · Run: `review-context <base>` · Record: the review file · Hook: pre-agent-dedupe
3. **Settle each behavior finding by a run on the head, never by reading:** a finding from a reviewer, a bot or a maintainer is a candidate, and so is a "this case is correct". If it doesn't reproduce, answer with the output; if an earlier verdict says the opposite, argue both ways first. Judge the rest by `code §Earn every line`, and write the real fixes in your own words.
4. **Post the findings** through `post` (never approve unless the user asked), or report to the user. Outside a PR's pipeline, one round.
   Open: `post`; `writing §Reports to the user` · Record: the gate file · Hook: gate-pass
