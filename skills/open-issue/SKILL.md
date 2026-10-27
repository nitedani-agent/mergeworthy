---
name: open-issue
description: "Opening an issue: should it be a PR, already filed?, reproduced first, one finding a newcomer can find, How to reproduce with a screenshot or video, decision issues, through post."
---

# Opening an issue

One finding a newcomer can find, reproduce and judge. An umbrella issue is `task` step 7.

## Steps

0. **Should this be a PR?** An obvious fix for a defect that blocks your work usually is: then stop here and run `pull-request`.
   Open: `task §Dispositions`
1. **Already filed or fixed?** An existing issue gets your finding as a comment, not a twin; a fix already on `<base>` gets no issue.
   Run: `gh issue list --state all --search "<keyword>"`; `git log --oneline origin/<base> -- <files>`
2. **Reproduce it on today's `<base>`** from a clean start. Trace both ends: where it starts in the code (`delegate/agent.md` §Code search), and where a user meets it. What you can't reproduce isn't filed.
   Open: `evidence` steps 1–4 · Record: the evidence files
3. **The body,** by `writing §Forms` (issue body). A decision issue (a change to what a legitimate user sees or can do) adds `### Options`: what a user sees under each, then your pick and its reason; it keeps How to reproduce and the evidence, because the reader decides on a behavior they must see.

   ```markdown
   <What breaks and where, in a user's words, as plain fact.>

   ### How to reproduce

   1. <the role or login, the page's URL>
   2. <each action, as a person does it>
   3. <what you see, and what you expected>

   ![](/abs/path/flow.mp4)
   ```
   Record: the draft
4. **Post it** through `post` with `--kind issue`, with the watcher covering the repo; upload the evidence. It's filed only once the evidence shows in the posted body.
   Open: `post`; `evidence` step 5 · Record: the issue · Hook: post-lint (How to reproduce and its evidence), pre-bash-guard
