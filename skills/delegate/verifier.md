# Verifier brief (Loop A: does it break anything?)

Standards: `~/.mergeworthy/current/skills/code/SKILL.md` (§Phantom gate, §Docs are a claim, §No regressions). Include `delegate/agent.md`.

## Slices

A slice is a part of the PR's code one verifier can hold (core feature, backend and storage, runtime adapter, wire and client). A diff over about 1500 lines is split into slices, each with its own verifier; in a stack, each PR has its own.

## Counting

- **A candidate counts only with a reproduction:** a spec or script fails on the head and either passes on the base (`main`, or the bottom PR for the top) or demonstrates an incomplete fix of the scenario the change names.
- It traces to realistic usage on both ends (the brief's What counts). A deliberate behavior doesn't count.
- A finding that fails code §Earn every line gets the disposition "accepted, not worth code" with its one-line reason; it never becomes code to make a pass come back clean.

**When a pass finds bugs** (the main session decides, an implementer lands): fix the root cause with the smallest diff, with a failing repro first, passing code §Phantom gate; re-run the verifier's repro on the fixed build. An area that already had two corrective edits gets rethought as one rule covering every case found, then that rule is implemented. Fixes to base code go in the bottom PR of a stack, then merge up; a merge-up re-opens the top PR's slices that call the changed base code.

**When a slice is done:** a pass with no bug that counts after its last fix. A fix, refactor or revert in a slice's code re-opens it; a finished, unchanged slice isn't run again; a queued pass is never dropped.

## After refactors

Continue the Loop A agent with Loop B's commits. It compares the tree before the refactors with the head, reproduce-only: the old specs run on the new code, adapting only renames, and every failure must be an intended change; side-by-side scripts run the same scenarios on both trees and diff the output; randomized comparisons where the logic is combinatorial. A regression here means the refactor wasn't behavior-preserving: revert it, then a fresh pass on that slice. With no Loop B commits, the file says `NO LOOP B COMMITS`.

## The brief

```
You are a bug verifier for <PR and slice>. Count only what you reproduce. Don't commit, push or comment anywhere.
First read ~/.mergeworthy/current/skills/code/SKILL.md §Phantom gate, §Docs are a claim and §No regressions in full; your file starts with `## Standards read`, the first sentence of each copied.

Base <SHA>, head <SHA>, in <worktree> (read with git show/diff at those SHAs; don't modify it). Your slice: <paths>.
<What changed since the last pass, with the previous reports' paths, if any.>
The project file: <project file path>. Settled decisions: <decisions/*.md or the PR body>.

What counts:
- through realistic usage (documented usage, each host the package ships to, a second copy of it, a caller that writes to what it got), the head behaves wrongly where a user can see it: a regression against the base, a fix that's incomplete for the scenario its commit names, or new code that behaves unlike the platform behavior it reproduces (a later reader sees an earlier reader's writes; `bodyUsed` lies). Silent wrong data where the base threw is a bug, never "not a regression"; so is costing more than the base for the same request (copies, reads, allocations, time), shown by a count or a `main`-vs-head run. Code and docs that disagree are judged per code §Docs are a claim.
- A deliberate behavior (a usage error) doesn't count, nor a scenario no realistic usage reaches on both ends.
- A candidate counts only with a spec or script that fails on the head and either passes on the base or demonstrates an incomplete fix.

How:
- read each change end to end with every caller; a change that makes a function cost more (a copy, a read, an allocation) gets each caller re-read for how often it calls and whether it discards the result;
- try the edges: <the slice's risky edges> (added to this list, never replacing it), each `## Recurring misses` line of the project file, and, for a diff that touches a body, a buffer, a stream, cancellation, a transport or a hot path (when unsure, it does), each of the nine bold items under code §No regressions' first bullet (Cancellation to Second copy), answered in that bullet's line form under a heading `## Bodies and streams`;
- every sentence the diff adds to docs, a README, JSDoc, a changeset or a code comment is a claim: reproduce it against the head on every runtime it covers (the runtimes the CI workflows run, else the package's `engines` and adapters), one line each under `## Claims`: `<claim> — <runtime> — <probe> — <result>`; one not run is UNKNOWN for that runtime, and "all" needs every line. A claim, or a new export, that no test or recorded probe shows false when it is broken is a finding; whether the probe becomes a test follows code §Tests;
- when the change handles one case of a mechanism (one method, status, adapter or runtime), probe the same failure in its sibling cases: one the PR should have covered is an incomplete fix; one that belongs in its own PR goes under its own heading, never dropped. When the diff serves a read through another method (every reader through `arrayBuffer()`), read both methods' code on each host adapter and probe what one does that the other doesn't;
- a probe re-run from an earlier pass compares with the right answer, never with the previous head's output;
- make your own worktrees under <work folder> (worktree add --detach, install, build) and remove them when done;
- lanes you may run: <lanes>. Don't run <lanes owned by others>.

Write <work folder>/<name>.md:
- each reproduced bug with its commit, the repro inline, observed vs expected;
- then every candidate you tried and dropped, one line each with why; one reproduced and dropped as "not a regression", "no documented usage", "rare" or "same as main" waits for the main session's `RULED: <candidate>: <ruling>` line under it;
- if no bug counts, say what you tried and end the file with a line NO BUGS.

Final message: the count and one line each, then each reproduced-and-dropped candidate, one line each; exactly NO BUGS only when both lists are empty.
```
