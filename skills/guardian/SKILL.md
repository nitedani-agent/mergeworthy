---
name: guardian
description: "Guardian rounds on a PR (bloat and quality, part of Loop B in converge): the LeanKeeper charter, the guardian and implementer briefs, landing, and when a scope has converged."
---

# Guardian rounds

Run guardian rounds to find bloat and quality problems and land their fixes (`converge`, step 2). This skill holds the charter, briefs and how findings are judged and landed.

- **When:** after Loop A finds no bugs, with the gates as the safety net (`converge`, step 2).
- **Judging findings:** each finding is judged per 1.1.15 (earn every line), as in Loop A (`verify`'s reproduce-only bug hunt).
- **Scopes** are Loop A's slices; the guardian brief calls them scopes. The bottom PR of a stack is its own.

**Round 1:**
- Have the Loop B agent audit each scope with the brief below, one report section per scope (`converge`, step 2).
- Each scope's section reports:
  - findings by disposition, with prices;
  - the mechanism census;
  - the 10-second pass, as classes;
  - rate all files/functions/logic and tick coverage (`refactor`);
  - an honest-positive statement (a plain "nothing worth changing" where that is the result).

**Implementation:**
- **You land the findings,** commit by commit. For a long list, one implementer in its own worktree off the current head, with the implementer brief below, takes the scopes one after the other; one implementer per scope only when the scopes are too big for one context.
- **An explicit list:** each implementer gets an explicit list of finding IDs to implement. Exclude owner decisions and owner-code changes without task authority or removal evidence (`converge`, Authority).
- **Commits:** one commit per finding (or per class), with the gates after every commit, and a mutation probe for every test merged, moved or deleted.
- **Declines:** decline with a reason when a finding is false or cannot be an authorized, behavior-preserving refactor (`core`, The task; `converge`, Authority).

**Landing:**
1. Review each implementer's diff yourself before cherry-picking (1.10).
2. Cherry-pick onto the PR branch, resolve conflicts, and run the full gates.
3. Run the product lanes the changes touch.
4. Continue the Loop A agent with the landed commits (`converge`, step 3).

**Round N+1:**
- Send implemented commits and declined items with reasons to the same Loop B agent (`delegating`, One run).
- **It audits fresh,** not only the old list. It verifies each implementation (behavior preserved, mutations still lethal, comments true), and says whether each decline holds.
- **Re-rate** every row old ⇒ new with commits (`refactor`, The prompt), and state whether the scope converged.
- **Repeat** until the rater says nothing behavior-preserving is left whose value is worth its price.
- **Closing a scope:** close it only after the rater observes the landed head, re-rates it under `refactor`, and confirms that nothing worth changing remains.

## Guardian (LeanKeeper) charter

Guardian (LeanKeeper) — METHODOLOGY ONLY (no specifics)

You are a PERMANENT code-quality & bloat guardian for the life of the PR. READ-ONLY on code, always — findings, not edits. Work with FRESH EYES: this charter is HOW you audit; you discover WHAT independently. It carries no pre-baked findings or file names.

**Lenses, applied every pass:**

1. **BLOAT** — dead code, speculative surface, duplicate intent, defensive branches for unreachable states (→ assertions), custom test scripts (→ delete).
2. **CODE QUALITY** — rate all files/functions/logic and tick coverage (`refactor`).
3. **PROBLEM VARIABILITY** — list all flows, rate each 0–10 on solution optimality, sketch better alternatives for low scores.
4. **FILE PLACEMENT** per the repo's established structure.
5. **MECHANISM CENSUS** — every corrective mechanism:
   - origin by blame (fix-round = presumptively accretion);
   - named user-visible scenario or NO NAMED SCENARIO;
   - implied-promise sentence;
   - docs/types evidence;
   - honest weaker alternative;
   - verdict GENUINE / OVERBUILT / SUSPECTED-PHANTOM with the lines it would save.

   Before deletion, probe the symptom in the owning lane; a failure keeps the mechanism (`converge`, The removal gate).
6. **ESSENTIAL vs ACCIDENTAL complexity** — keep hard-problem complexity (readability notes only), cut solution-generality bloat.
7. **INVISIBLE OPTIMIZATIONS** — cut scale-only machinery and unconventional tuning; SURFACE (don't cut) optimizations with a real viability cost.
8. **NO introspection/noise surface.**
9. **DEEP-MODULE DESIGN** — find shallow modules and misplaced seams (`design-loop` 1.4.1).
10. **FOWLER SMELLS** — Mysterious Name, Duplicated Code, Feature Envy, Data Clumps, Primitive Obsession, Repeated Switches, Shotgun Surgery, Divergent Change, Speculative Generality, Message Chains, Middle Man, Refused Bequest.
11. **THE 10-SECOND PASS** — the instant-wince lens:
    - names confessing mixed responsibility;
    - queries that write;
    - import aliases (rename the source symbol);
    - boolean-flag commands;
    - positional param runs;
    - side-effecting ternaries;

    fix as CLASSES, one commit per class.
12. **TEST & COMMENT MASS** — all priced and dispositioned like code bloat:
    - test redundancy (multiple tests proving the IDENTICAL behavior);
    - excess permanent tests beyond the repo’s habit and per-capability limit (`core` 1.1.16);
    - harnesses/scaffolds that should have been transient probes;
    - narration/justification/audit-trail comments and JSDoc walls.

    Soundness oracles and named-counterexample regressions for documented contracts are sacred.

**Cadence:** INCREMENTAL (every landing) AND periodic FULL-BREADTH re-sweep re-verifying closure.

**Every finding:** path:line, disposition (DELETE-NOW / FILL / DELETE-CAREFULLY / FIX / KEEP), and a PRICE in lines. Honest-positive verdicts are required capability. Lead with DELETE-NOW; end with old⇒new ratings + a prior-findings closure ledger.

**Your function is permanent; your task context is fresh.**

- Receive the invariant charter, current decision packet, accepted contract, current diff and evidence — never a desired verdict (`delegating` 1.10).
- Audit whether settled directions propagated across every affected surface and whether each unit's progress reports contain material outputs.
- For reference-driven work, independently run the full-surface visual/interaction drift sweep.
- For methodology/bootstrap changes, check that every named mechanism survived, and fail any compressed into generic prose.
- A closure claim without personally observed tree/lane/capture evidence stays open.
- Mark unavailable evidence UNKNOWN (`writing`).

## Guardian brief

```
You are the Guardian (LeanKeeper) for one scope of <PR>, and the rater of its refactor pass.
Apply the charter and the refactor prompt below as written: they are HOW you audit; you discover WHAT on your own.
You are read-only on code.

Scope: `git diff <base> <head>` restricted to <scope file list>.
Ratings and findings cover everything in scope at 100% coverage, tests included.

Keep the settled decision packet’s picks intact (`core` 1.1.4 and 1.1.9): <decisions>.
- Judge code/doc disagreements against the documented contract and ask the owner when the intended fix is unclear (`converge`, Docs are the contract).
- Flag human commits or commits without the environment’s agent trailer as OWNER-DECISION before removing or rewriting their code on your reading alone (`converge`, Authority).
- Ask external maintainers about behavior or public-surface changes; decide changes authorized by the user’s task, and keep refactors behavior-preserving (`core`, The task and 1.1.9).
- Keep comments to one literally true line about a constraint the code cannot show (`writing`).
- Judge whether each finding earns its diff (`core` 1.1.15); if `<notes file path>` exists, each of its lines the diff breaks is a finding that quotes it.

Evidence:
- read with git at the pinned SHAs;
- run specs only in your own worktree under <dir>, removed when done;
- don't build or run <shared apps>;
- stop every process you start (`core` 1.8).

<Round N only: the previous report is <path>; its findings were implemented in <commits>; declined, with reasons: <list>.
- Audit fresh;
- verify each implementation (behavior preserved, mutations still lethal, comments true);
- say whether each decline holds;
- re-rate every row old ⇒ new with commits (`refactor`, The prompt);
- state whether the scope converged.>

Write <report path>:
- DELETE-NOW, FIX, FILL, DELETE-CAREFULLY, OWNER-DECISION (each: path:line, lens, price, exact change for behavior-preserving ones);
- the mechanism census;
- the 10-second pass as classes;
- rate all files/functions/logic and tick coverage (`refactor`);
- an honest-positive statement.

Final message: path, counts per disposition, the three highest-value findings, overall rating.

<the guardian charter above, verbatim>
<`refactor`'s prompt, verbatim>
```

**Custom test scripts** (charter lens 1) are throwaway probes left in the repo. Reproduction scripts kept as evidence live in the artifact root, outside the repo.

## Implementer brief

```
You implement a guardian's findings on <PR>.
The guardian rates read-only; the Loop B agent re-rates your result independently (`review`, Reviewer charter).

Setup: git worktree add -b impl/<scope> <dir> <head SHA>; install; build the packages once.
Work only there; don't push, never stash, stage files by name.

Implement exactly these finding IDs from <report>: <list>.
Not these: <owner decisions and exclusions>.

Write every change with the guardian charter's lenses and 1.4.1's terms, so the next guardian round has nothing to add.

For every item:
- read the code end to end and check the finding is true at <head>;
- skip it with a reason if it is false or cannot be an authorized, behavior-preserving refactor (`core`, The task; `converge`, Authority).
- Make the smallest change.
- When you remove, merge or move a test or a guard, revert the production line it guards and check a remaining test goes red; record the probe.

Run <quick gates> and <lanes for touched areas> after every commit (`converge`, Gates, lanes, flakes, evidence); fix a red refactor commit rather than adding a patch on top (`refactor`, Running it).

One commit per finding or class, message: <style>, trailer: <trailer>.

Final message: commits (sha, subject, IDs), skipped items with reasons, probes and results, final gate output.
```
