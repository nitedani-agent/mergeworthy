---
name: open-issue
description: "Opening an issue: already filed?, reproduced first, one finding a newcomer can find, How to reproduce, a screenshot or a video of the flow, decision issues, the gate."
---

# Opening an issue

Show one finding a newcomer can find, reproduce and judge (`writing`). When a defect becomes an issue is 1.1.7's call; a change to what a legitimate user sees or can do becomes a decision issue (1.1.9); an umbrella (`Tracking: <goal>`) follows 1.2, Tier L.

0. **Should this be a PR instead?** An obvious fix for a defect that blocks your work usually is (`core` 1.1.7).
1. **Already filed or fixed?** `gh issue list --state all --search "<keyword>"` and `git log --oneline origin/<base> -- <the files>`. An existing issue gets your finding as a comment, not a twin; a fix already on `<base>` gets no issue.
2. **Reproduce it on today's `<base>`** per `evidence`, from a clean start. Trace both ends: where it starts in the code, and where a user meets it. What you can't reproduce isn't filed.
3. **Write the body** by `mergeworthy:writing` (its issue form):

   ```markdown
   <What breaks and where, in a user's words, as plain fact.>

   ### How to reproduce

   1. <the role or login, the page's URL>
   2. <each action, as a person does it>
   3. <what you see, and what you expected>

   ![](/abs/path/flow.mp4)
   ```

   - Capture the evidence as a screenshot, a video of the flow, or the request and response, according to what shows the behavior (`evidence`, Capture it).
   - **A decision issue** adds `### Options`: what a user sees under each, then your recommendation and its reason. It keeps How to reproduce and the evidence, because the reader decides on a behavior they must see.
4. **Post it through the gate** (1.6, `post-lint --kind issue`), with a watcher covering the repo (1.5). Say it's filed only once the evidence shows in the posted body.
