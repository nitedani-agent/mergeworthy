---
name: verify
description: "Bug verification of a PR (reproduce-only, Loop A in converge): slicing, the verifier brief, the counting and done rules, and the final verification after refactors."
---

# Bug verification

**Split each PR's code into slices one verifier can hold** (e.g. core feature, backend and storage, runtime adapter, wire and client). Run this verifier brief on each assigned slice during the pipeline (`converge`, steps 1, 3 and 4). This skill defines counted bugs and dry slices.

**Counting rule:**
- **A candidate counts only with a reproduction:** a spec or script fails on the head and either passes on the base (main, or the bottom PR for the top) or demonstrates an incomplete fix of the scenario the change names.
- **Documented usage on both ends.** The candidate must trace to documented usage on both ends.
- **A deliberate behavior doesn't count.**
- **Not worth code.** A finding that fails 1.1.15 gets the disposition "accepted, not worth code" with its one-line reason. It never becomes code to make a pass come back with no bugs: Loop A converges on real bugs, not on every imaginable edge case.

**When a pass finds bugs:**
1. Fix the root cause with the smallest diff (`core` 1.1.6 and 1.1.15), with a failing repro first (show it failing on the parent; keep it as a test only under `core` 1.1.16), and pass the phantom gate (`converge`). Re-run the verifier's own repro on the fixed build, and compare its output with the base's.
2. If the area has already had two corrective edits, stop patching. Rethink it as one rule that covers every case found so far, then implement that rule.
3. Put fixes to base code in the bottom PR (when there is a stack, `converge`), then merge up.
4. Queue another pass on that slice, and record it in the ledger. A merge-up re-opens the top PR's slices that call the changed base code, and the top's base SHA for counting moves to the bottom's new head.

**When a slice is done** (a pass that finds no bug that counts):
- **Every slice needs a pass with no bugs after its last fix.**
- **A change re-opens a slice.** A fix, a refactor or a revert in a slice's code re-opens it.
- **Don't rerun a finished, unchanged slice.** A slice whose last pass found no bugs, and whose code hasn't changed since, isn't run again.
- **Never drop a queued pass.** The ledger lists every pass owed, and the PR isn't converged while one is outstanding.

Bugs outside the task's scope get a disposition (1.1.7).

### Final bug verification after the refactors

This is pipeline step 3 (`converge`, `pr-steps reverify`): continue the Loop A agent with Loop B's commits, since it knows the slices. It compares the pre-refactor tree with the head, reproduce-only:
- The old specs run on the new code, adapting only renames. Every failure must be an intended change.
- Side-by-side scripts run the same scenarios on both trees and diff the output.
- Randomized or fuzz comparisons are included where the logic is combinatorial.

A regression found here means the refactor wasn't behavior-preserving: revert it, then run a fresh pass on that slice.

## Verifier brief

```
You are a bug verifier for <PR and slice>. Count only what you reproduce. Don't start subagents, don't commit, push or comment anywhere.

Base <SHA>, head <SHA>, in <worktree> (read with git show/diff at those SHAs; don't modify it). Your slice: <paths>. <What changed since the last pass, with the previous reports' paths, if any.>

What counts:
- through documented usage (code/doc disagreements are judged against the documented contract (`converge`, Docs are the contract); the settled decisions are in <decision packet or PR body>), the head behaves wrongly where a user can see it:
  - a regression against the base, or
  - a fix that's incomplete for the scenario its commit names.
- A deliberate behavior (a usage error) doesn't count, nor a scenario no documented usage reaches on both ends.
- A candidate counts only with a spec or script that fails on the head and either passes on the base or demonstrates an incomplete fix of the scenario the change names.

How:
- read each change end to end with every caller;
- try the edges: <the slice's risky edges, each `## Recurring misses` line of `~/.mergeworthy/projects/<owner>/<repo>.md`, and for stream code core 1.1.11's stream probes>.
- when the change handles one case of a mechanism (one method, status, adapter or runtime), probe the same failure in its sibling cases: one the PR should have covered (`pull-request` step 3) is an incomplete fix; one that belongs in its own PR is listed under its own heading for that PR (1.1.7), never dropped.
- Make your own worktrees under <artifacts dir> (worktree add --detach, install, build) and remove them when done.
- Lanes you may run: <lanes>. Don't run <lanes owned by others>.

Write <artifacts dir>/<name>.md:
- each reproduced bug with its commit, the repro inline, observed vs expected;
- then every candidate you tried and dropped, one line each with why.
- If you found nothing, say so plainly and list what you tried, and end the file with a line NO BUGS.

Final message: the count and one line each, or exactly NO BUGS when no bug counts.
```
