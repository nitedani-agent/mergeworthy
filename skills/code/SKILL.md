---
name: code
description: "The standard every diff meets: code, tests, comments, module shapes. Read it before writing or judging code; its Checklist is what the shape pass checks."
---

# Code

What is true of every diff. The implementer reads this before writing; whoever judges a diff (the main session, a verifier, a reviewer, the shape pass) checks it against the same sections. Write to it, so the check finds nothing.

### Before writing

- Read the repo's `AGENTS.md` / `CLAUDE.md` on the target branch, and three sibling files: note sentence length, comment density, naming and platform wording.
- **Find what already does it.** Grep the constants, literals and imports the new code will use; reuse the existing function, and when it needs a fix to be reused, that fix is part of this diff. Never claim something is missing without linking the code. In a program of PRs, also search the sibling PRs, open and merged: when one already enforces a rule (a validator, a guard), extend that layer, never add a second check for the same thing.
- **Behavior before removal.** Before removing or rewriting behavior, inventory what exists (triggers, paths, gates) and run `git log -S` on it. Keep all of it unless the task says otherwise. After a move or rename, grep the repo and sibling PRs for the old name.
- **Build the whole interaction, not the happy path.** Someone will finish the task, change their mind, go back, reload, mistype, use the keyboard, leave halfway. Anything that would make them wonder what happened is a defect.

### Root cause

Fix at the root; never document around a defect. A sentence telling users to work around the product ("order by seq when order matters", "may miss for 60 s") is a bug to fix, upstream included, unless the user explicitly accepts it.
- A workaround for another project's bug ships only once that bug is filed there (an issue, or the PR that fixes it), with a one-line `TODO: remove once <issue or PR link> is released` at the workaround.
- These workarounds need the user's OK, with a written reason the root fix is impossible: parsing twice, encoding to dodge a transport, retry or reload loops, a second code path for old runtimes, silent fallbacks.
- Unreleased, experimental or pre-1.0 code gets no compatibility code or shims (check `npm view <pkg> versions`). Losing something users can do on `main` is still a regression.
- Before an upstream PR, find which side relies on behavior the other side doesn't promise (hook order, file layout). Fix that side first, ours included.
- Before changing a mechanism (a hook, a scheduler, an agent's lifecycle), state how it starts and what running and finished look like, checked against one real observation of it.
- Before removing, moving or rewriting, list what depends on it and what its owner wrote: change what depends on it, keep the owner's words unless they asked for new ones.

### Earn every line

A reviewer's, verifier's or shape pass's finding is a candidate, not a mandate. Before it becomes code, a test, a doc or an option, ask:
- **How likely does a real user hit it, and what happens then?** A rare case whose failure is mild, or arguably what the user asked for, gets no code. Wrong data returned silently (a misattribution, a lenient parse that hides the cause) is never mild: fix it at the root.
- **What does `main` do for the analogous case?** Add guards, asserts and caches only where `main` has an analogous one.
- **What does it cost** in lines, new state (maps, globals, build tracking) and tests? More than a few lines for a rare case is overkill.
- **Would the maintainer write it?** Lean code, no special-casing. Performance work stops at the plainest conventional code winning the order of magnitude; more shaving (planner hints, caches, odd query shapes) waits for the user's ask.

It judges findings and patches, never the shape of a design (`design`). Record the judgment in one line ("accepted, not worth code: rare, and the page winning is what the user asked for"); that line is the finding's disposition. When unsure, don't add; ask with a recommendation. A converged PR is the smallest clean diff that does the job and reads as obviously right to its maintainers.

### Shape that gets merged

Before opening a PR, look at the maintainer's recent merged PRs (and ours in that repo): what they keep and what they cut.
- **One purpose, small:** under ~50 lines of code when possible. Each user-visible fix is its own PR; the same failure in a sibling case of the same mechanism is the same fix (`pull-request §Rating`). Internal cleanups go together in one refactor PR, titled per the repo's convention. Separate items are separate commits.
- **Features:** before opening the PR or calling it ready, list each feature with non-trivial code in `scope.md`, next to the link that needs it today. Remove the rest.
- **Docs:** main usage and one example, plus `llms.txt`; no edge cases, nothing obvious.
- **Deletions:** every comment, guard or workaround the diff deletes gets one line in the body with the evidence that it's obsolete; otherwise it stays.
- **A test app imports the package by its name,** never by a source path.
- A new dependency never joins an open PR the maintainer hasn't agreed to.

### Tests

- **Tests follow the repo's habit.** Where the maintainer removes PR-proving tests ("remove the test right before merging"), remove them unasked, in a final commit once the PR is approved. Where the maintainer keeps regression tests, keep them; a probe or a repro becomes a test only there. Write no tests for message text, comments or dead code. Add at most one permanent e2e assertion per new capability, in an existing test app, and unit specs only for tricky pure algorithms.
- **Expected values come from outside the implementation:** a literal, the issue, or a worked example; never recompute them with the same algorithm or snapshot the code's own output.
- **A mutation probe:** when you remove, merge or move a test or a guard, revert the production line it guards and check a remaining test goes red; record the probe.

### Names

Every new public name gets a one-line "name → what it does in every case" check, and reflects one responsibility. A new option needs a named user scenario that can't be served without it.

### No regressions

Anything that works on `main` and fails on the head is a regression, experimental features included: fix it, never list it as a limitation. So is a cap our own design creates (a retry budget, one lock every writer shares) that makes realistic use fail: redesign so it succeeds. A real limit is imposed from outside, and its note names the source. So is every row of your own comparison where the head is worse than the run-to-run spread.
- **Streams, transports and hot paths** are checked for health, not only output:
  - cancellation travels both ways: a cancelling consumer or aborting client stops the source; a failing source fails the consumer, never hangs it;
  - backpressure holds: read on demand;
  - every buffer has a cap, including an unread `tee()` or `clone()` branch;
  - listeners, timers and readers are released on every exit path, and what the code still needs is held by more than a listener;
  - a stream is read once, or copied before its first read.
- Probe each on every runtime the code ships to: cancel mid-stream from each end, a body past runtime caps (Node: 1 GiB) into a slow consumer, listener counts after many requests. Deterministic probes (memory bound, listener or request count) become tests per §Tests; timing goes to the benchmark: `main` against the head before the PR opens, all scenarios, alternating runs, N ≥ 3, throughput, p50/p99, peak memory, request count and reconnects. A cell worse than `main` beyond the spread is fixed or reverted, never called a trade-off without the user's OK.
- **UI and runtime fixes** are shown working in the real app (`evidence`); unit scripts alone don't count. New UI ships after a fresh reviewer, never the main session, passes its screenshot's hierarchy and noise: the whole page at the user's real viewport, with real data. For a product that changes how pages load, record a screencast from navigation to settled and count every visible pop-in and shift, the host page's own included. Never judge by how fast your own pieces are ready.

### Deep modules

Aim for deep modules wherever code is written, designed or restructured: a lot of behaviour behind a small interface, at a clean seam, testable through that interface. Use these terms in design analysis; outward prose uses the reader's words.
- **Module**: anything with an interface and an implementation, at any scale (a function, a class, a package, a slice across tiers).
- **Interface**: everything a caller must know to use the module correctly: the types, and also invariants, ordering, error modes, required configuration and performance characteristics.
- **Implementation**: the code inside a module.
- **Depth**: the behaviour a caller or test can exercise per unit of interface it has to learn. Deep: a lot behind a small interface. Shallow: an interface nearly as complex as what it hides (a pass-through). Not a ratio of lines.
- **Seam**: where behaviour can change without editing in that place; where a module's interface lives. Where to put a seam is a decision of its own.
- **Adapter**: a concrete thing that satisfies an interface at a seam; a role, not a size.
- **Leverage** (what callers get) and **locality** (what maintainers get: a change, a bug, a fix in one place).

Principles:
- **Depth belongs to the interface.** A deep module may be built from small parts with internal seams that its own tests use; those seams are not part of its interface.
- **The deletion test:** imagine deleting the module. If complexity vanishes, it was a pass-through; if complexity reappears across its callers, it earns its keep.
- **The interface is the test surface:** callers and tests cross the same seam. Needing to test past the interface means the module has the wrong shape.
- **One adapter alone does not justify extensibility.** Add a seam only for present variation or a named unstable dependency that needs quarantine; never for a hypothetical second consumer.
- **Shaping an interface,** ask: fewer methods? simpler parameters? more hidden inside?
- **For testability:** accept dependencies rather than create them (`processOrder(order, gateway)`, not a `new StripeGateway()` inside); return results rather than produce side effects (`calculateDiscount(cart): Discount`, not `applyDiscount(cart): void`).

**Deepening a cluster of shallow modules:** classify each dependency first, since its category decides how the deep module is tested at its seam.
- **In-process** (pure computation, in-memory state): merge the modules and test through the new interface; no adapter.
- **Local-substitutable** (a local stand-in exists, e.g. PGLite for Postgres): test with the stand-in; the seam stays internal.
- **Remote but owned** (your own services over a network): a port at the seam; the transport is an injected adapter (in-memory in tests, HTTP or a queue in production).
- **True external** (a third party you don't control): an injected port, a mock adapter in tests.

**Tests after deepening:** internal seams stay internal; once tests at the deepened interface exist, delete the old tests on the shallow parts; assert outcomes through the interface, so the tests survive internal refactors.

### Comments

At most one line, literally true, stating a constraint the code can't show. No links to source (a workaround's TODO links its upstream issue or PR), and no comparison with the old code ("instead of", "now", "no longer"). Names follow their siblings.

### Phantom gate

Every fix passes it. A fix is phantom, and must not ship, if any of these holds:
- **No real, documented usage reaches it.** Name the documented scenario, and trace it on both ends: client and server, caller and callee, sender and receiver. A bug that one layer "has" is not a bug if another layer already owns that behavior.
- **It changes a deliberate behavior,** such as a usage error the code raises on purpose, a documented limit, or an owner's design.
- **It is a mechanism for an unreachable state:** assert the invariant or add nothing.

Every fix also keeps usage errors visible (a silent fallback only per §Root cause), fixes the root cause with the smallest diff without new protocol concepts, handshakes or probes unless asked, and goes at the call site, not into a changed default that other callers depend on.

### Removal gate

"No test fails without it" doesn't prove a mechanism is phantom. Before removing a guard, a dedup, a retry or a memo:
- **Probe the symptom** the mechanism prevents, through documented usage against the real threshold: listener counts and MaxListeners warnings, timers, memory, ordering, duplicate delivery.
- **In the owning lane** (§Gates), not only in unit tests.
- **A product-shaped failure keeps it,** recorded as GENUINE-CONFIRMED (a mechanism a probe proved necessary) with the failure text; count confirmed-kept mechanisms alongside deleted ones.
- **Repaired twice is suspect.** Re-probe whether a mechanism repaired twice needs to exist at all.

### Owner code and authority

- **Owner code is deliberate,** in the user's repos too. It is never removed or rewritten on an agent's reading alone: trimming it, "simplifying" it, or deleting a mechanism in it as phantom or overbuilt. Such findings are OWNER-DECISION rows with a recommendation. An agent's own earlier code can be changed freely; if an agent removed an owner line, restore it.
- **The user's own repos:** changing the user's code as the task needs is yours to decide. A rewrite the user asked for replaces all of their code: nothing of the old code is carried over or protected. A removal that passed §Removal gate is not a reading alone: make it, and report it with the probe.
- **External maintainers:** their requests are settled decisions; record each with its link and date, and do it as asked or ask back with a recommendation, never decide otherwise and inform. Ask them before changing their code's behavior or public surface; refactors preserve behavior. The newest statement on a subject wins: re-read the thread before citing anyone.
- **A security or bug fix closes only the hole.** A change to what a legitimate user sees or can do (a field made read-only, a value now rejected that the UI sends) is the owner's product decision: a decision block in the PR body (`writing §Forms`), or its own decision issue (`open-issue`) when no PR carries it; never part of the fix.

### Docs are a claim

Every sentence about behavior in docs, a README or JSDoc is a claim, checked against the head like code. When they disagree, fix whichever is wrong: the code when the docs' promise is clearly intended and the fix is straightforward, the docs when the code is what the owner chose. Otherwise ask the owner on the open PR: the doc line, the observed behavior, the question. The project file overrides this per repo.

### Gates

- **A lane** is one CI job's way of running the product: a runtime, an adapter, a transport or a build mode. The owning lane of a mechanism is the one that runs the code it lives in.
- **Quick gates, after every commit:** format, type-check and units.
- **Full gates, before every push:** the quick gates; spellcheck and docs lint; the released-API or public-surface check; the runtime-specific lanes. Build the list from the repo's CI workflows, every check they run, never by hand.
- **Heavy lanes, before every push,** on each PR's head: build, then the heavy lanes the project file lists (production-mode e2e, every adapter or transport, the examples).
- **Gates fail closed:** a gate that errors or can't run is red. A failure that doesn't repeat is still a finding: find its cause, or file it with the logs, before calling anything green. "N passed" with a non-zero exit code is red; record `EXIT=$?` and quote it, never a log tail.
- **Name the head:** every claim names the head it ran on. A known base bug that a lane shows is recorded as the base's, with the evidence that the base fails it too.

### Git

- Stage files by name; never `git add -A` on a tree you share.
- Rewrite only local, unpushed commits, and only to fix that same commit (a red gate on it, a comment that isn't true) or to replay them onto commits others pushed. Never propose mutative git operations to the user.
- Write prompt and text files with a quoted heredoc (`<<'EOF'`): an unquoted one runs the backticked commands inside the text.
- Refactor commits are separate from behavior commits; a red gate on a commit means fix that commit, never a patch on top.

### Checklist

The implementer runs it on its own diff before handing it back; the shape pass checks every line of it (`delegate/shape.md`, step 1).
1. **Bloat:** dead code, speculative surface, duplicate intent, defensive branches for unreachable states (→ assertions), custom test scripts left in the repo (→ delete).
2. **Quality:** every file, function and piece of logic rated with its reason (`delegate/shape.md`, steps 2–3).
3. **Problem variability:** every flow rated 0–10 on solution optimality, with a better alternative sketched for low scores.
4. **File placement** per the repo's established structure.
5. **Mechanism census:** every corrective mechanism with its origin by blame (fix-round = presumptively accretion), its named user-visible scenario or NO NAMED SCENARIO, the promise it implies, docs or types evidence, an honest weaker alternative, and a verdict GENUINE / OVERBUILT / SUSPECTED-PHANTOM with the lines it would save. Removal per §Removal gate.
6. **Essential vs accidental complexity:** keep hard-problem complexity, cut solution-generality bloat.
7. **Invisible optimizations:** cut scale-only machinery and unconventional tuning; surface (don't cut) optimizations with a real viability cost.
8. **No introspection or noise surface.**
9. **Deep modules:** shallow modules and misplaced seams (§Deep modules).
10. **Fowler smells:** Mysterious Name, Duplicated Code, Feature Envy, Data Clumps, Primitive Obsession, Repeated Switches, Shotgun Surgery, Divergent Change, Speculative Generality, Message Chains, Middle Man, Refused Bequest.
11. **The 10-second pass:** names confessing mixed responsibility, queries that write, import aliases (rename the source symbol), boolean-flag commands, positional parameter runs, side-effecting ternaries; fixed as classes, one commit per class.
12. **Test and comment mass,** priced like code: tests proving the identical behavior, permanent tests beyond §Tests, harnesses that should have been transient probes, narration and justification comments, JSDoc walls. Soundness oracles and named-counterexample regressions for documented contracts stay.
13. **Comments** per §Comments; **names** per §Names; reuse per §Before writing.
