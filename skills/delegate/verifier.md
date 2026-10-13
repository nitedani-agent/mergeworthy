# Verifier brief (Loop A: does it break anything?)

Standards: `~/.mergeworthy/current/skills/code/SKILL.md` (§Phantom gate, §Docs are a claim, §No regressions). Include `delegate/agent.md`.

## Slices

A slice is a part of the PR's code one verifier can hold (core feature, backend and storage, runtime adapter, wire and client). A diff over about 1500 lines is split into slices, each with its own verifier; in a stack, each PR has its own.

## Counting

- **A candidate counts only with a reproduction:** a spec or script fails on the head and either passes on the base (`main`, or the bottom PR for the top) or demonstrates an incomplete fix of the scenario the change names.
- It traces to documented usage on both ends. A deliberate behavior doesn't count.
- A finding that fails code §Earn every line gets the disposition "accepted, not worth code" with its one-line reason; it never becomes code to make a pass come back clean.

**When a pass finds bugs** (the main session decides, an implementer lands): fix the root cause with the smallest diff, with a failing repro first, passing code §Phantom gate; re-run the verifier's repro on the fixed build. An area that already had two corrective edits gets rethought as one rule covering every case found, then that rule is implemented. Fixes to base code go in the bottom PR of a stack, then merge up; a merge-up re-opens the top PR's slices that call the changed base code.

**When a slice is done:** a pass with no bug that counts after its last fix. A fix, refactor or revert in a slice's code re-opens it; a finished, unchanged slice isn't run again; a queued pass is never dropped.

## After refactors

Continue the Loop A agent with Loop B's commits. It compares the tree before the refactors with the head, reproduce-only: the old specs run on the new code, adapting only renames, and every failure must be an intended change; side-by-side scripts run the same scenarios on both trees and diff the output; randomized comparisons where the logic is combinatorial. A regression here means the refactor wasn't behavior-preserving: revert it, then a fresh pass on that slice. With no Loop B commits, the file says `NO LOOP B COMMITS`.

## The brief

```
You are a bug verifier for <PR and slice>. Count only what you reproduce. Don't commit, push or comment anywhere.

Base <SHA>, head <SHA>, in <worktree> (read with git show/diff at those SHAs; don't modify it). Your slice: <paths>.
<What changed since the last pass, with the previous reports' paths, if any.>
The project file: <project file path>. Settled decisions: <decisions/*.md or the PR body>.

What counts:
- through documented usage, the head behaves wrongly where a user can see it: a regression against the base, or a fix that's incomplete for the scenario its commit names. Code and docs that disagree are judged per code §Docs are a claim.
- A deliberate behavior (a usage error) doesn't count, nor a scenario no documented usage reaches on both ends.
- A candidate counts only with a spec or script that fails on the head and either passes on the base or demonstrates an incomplete fix.

How:
- read each change end to end with every caller;
- try the edges: <the slice's risky edges>, each `## Recurring misses` line of the project file, and for stream code code §No regressions' stream probes;
- every sentence the diff adds to docs, a README or JSDoc is a claim: reproduce it against the head;
- when the change handles one case of a mechanism (one method, status, adapter or runtime), probe the same failure in its sibling cases: one the PR should have covered is an incomplete fix; one that belongs in its own PR goes under its own heading, never dropped;
- make your own worktrees under <work folder> (worktree add --detach, install, build) and remove them when done;
- lanes you may run: <lanes>. Don't run <lanes owned by others>.

Write <work folder>/<name>.md:
- each reproduced bug with its commit, the repro inline, observed vs expected;
- then every candidate you tried and dropped, one line each with why;
- if no bug counts, say what you tried and end the file with a line NO BUGS.

Final message: the count and one line each, or exactly NO BUGS.
```
