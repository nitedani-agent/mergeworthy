# Finality prompt (map, imagine, hunt, converge, close)

Standards: `~/.mergeworthy/current/skills/code/SKILL.md` §Deep modules, §Phantom gate, §Removal gate. Include `delegate/agent.md`.

The user's prompt, verbatim; `finality`'s steps say which part each agent gets. Its words:
- **The orchestrator** is the main session: it starts every agent the prompt names (the mappers, the 3 branch agents, the converging agent); each agent does its share itself, without starting agents.
- **§A, the shared node schema** is the per-function field list under PHASE A.
- **§B** is PHASE B; **§B½** is PHASE B½; Phase C is the implementer's (`delegate/implementer.md`).
- **§Closure** is the Owner-Safe closure paragraph at the end. *Every SETTLED decision propagated to its named surfaces*: every decision in `<work folder>/decisions/*.md` reached every place that describes it (code, tests, types, docs, PR bodies). *Owning lanes, mutations, reference captures, clean-tree scope*: the lanes that own the changed code (`code §Gates`), mutation probes (`code §Tests`), before/after screenshots, and a `git status` with only in-scope changes, each observed on the head.
- *The session's model tier* is the main session's model class (`delegate §Model class`).
- *Fresh Guardian evidence* is Loop B's latest shape report (`converge` step 2).
- The design doc it ends with is posted through `post` (a gist counts) unless the repo keeps design docs.

```
Run a FINALITY PASS on <FEATURE / PATHS>.

The feature evolved through many design changes — added-to, patched, revised — which is exactly
how code reaches the state where the next person wants to rewrite it from scratch. I want the
opposite outcome: converge it NOW to the final state that will need no rewrite. That cannot be
done by lazily shuffling code around. Do it in three phases:

PHASE A — MAP.
Build a knowledge graph of the ENTIRE feature, line by line. It is tedious work; do it anyway.
Map the subsystems using one shared node schema; the orchestrator assigns mapper agents.
- For EVERY file: its role and why it is a separate file.
- For EVERY function/class/constant (internal ones too):
  - purpose (what it decides, not its name paraphrased);
  - inputs/outputs;
  - state it reads/writes;
  - invariants it relies on and maintains;
  - call/data edges by module path (cross-subsystem edges especially);
  - failure behavior;
  - cognitive-complexity flags (deep nesting, mode flags, implicit protocols, state machines
    spread across functions);
  - and ACCRETION SCARS with line refs — vestigial parameters, generality nothing uses, shapes
    visibly patched across design revisions, concepts duplicated across files, names that no
    longer match behavior, comments contradicting code, seams that exist only for history.
- Each mapper ends with:
  - the subsystem's true concept list (the few ideas everything else elaborates),
  - hidden couplings,
  - its heaviest cognitive-load points ranked,
  - and rewrite-from-scratch observations.
Mappers are read-only; graphs are artifacts.

PHASE B — IMAGINE.
Diverge first, then converge. DIVERGE: write the problem clean, as its users would state it: what
must happen, what it may never cost, and the facts of the outside world it lives in (platform
APIs, runtimes, networks). No current design, no file or function names, no project terms, no
hint of how it is solved today: those anchor the branches on what exists. Pick 6 to 9 frames
from that clean problem (the ways it fails, the people it serves, fields that solved its like),
never from the current solution and never a fixed list. The orchestrator starts 3 isolated branch
agents on the session’s model tier, each with the clean problem and 2 or 3 of those frames,
no frame given twice. Each first writes its 3 obvious
designs, marked obvious, then 6 more beyond them, with no evaluation; no branch sees another's
output. CONVERGE: only now does the graph come in: the orchestrator gives the assembled graph
AND every branch’s lists to ONE converging agent on the session’s model tier. The obvious
designs are its baseline; it ranks every
design on merit only (correctness, cost on the fast path, behavior at the edges, simplicity;
novelty earns nothing), flags the traps, and a non-obvious design wins only by beating the best
obvious one. From that it derives the PINNACLE design — the shape this feature would have if
designed today, from scratch, knowing everything the graph knows, with NO obligation to the
current file layout.
Design pressures:
(1) every module must be able to STATE the reason for its complexity ("essential because
    <specific reality>") or be collapsed — complexity that cannot name its reason is accidental;
(2) terminology is part of the design — one small documented vocabulary, functions readable by a
    maintainer who has not built this domain;
(3) separate the STABLE CORE from the BRITTLE EDGES — quarantine anything depending on
    third-party internals or version pins behind a small named interface so the core survives
    churn (build only the seam needed to quarantine that present dependency, not a hypothetical
    consumer);
(4) no speculative fixes, and specifically NO PHANTOM HOLES FROM PARTIAL READS — a hole claim is only valid
    AGAINST THE WHOLE GRAPH:
    - the finder must name the layer that SHOULD own the behavior,
    - look up in the full map whether any layer DOES own it,
    - and only an empty search is a hole.
    A hole that survives must also have a plausible trigger; otherwise it is a documented
    accepted contract;
(5) keep cognitive complexity low;
(6) every corrective mechanism in the graph passes the PROMISE test — name the promise it
    enforces and whether anyone deliberately chose it; mechanisms whose promise lives only in
    themselves and their tests are accretion candidates for the plan.
Output: the pinnacle architecture, the diff between it and the tree, and a ranked convergence
plan of behavior-preserving refactors.

PHASE B½ — HUNT CREPT-IN PHANTOM FIXES.
Past phantom holes may already be IN the code, and they are hard to see because a crept-in
phantom fix looks identical to legitimate defense-in-depth — the difference is a fact about the
REST of the system. Run these graph queries:
(1) RESPONSIBILITY COLLISIONS — for each failure mode (reconnect/retry/dedupe/timeout/ordering/
    cleanup), list every node claiming to handle it; >1 claimant across layers = suspect set, and
    the phantom is usually the wrong-altitude one;
(2) UNREACHABLE GUARDS — instrument suspect defensive branches with counters and run the full
    suite + e2e through REAL entry points; a counter stuck at zero is the signature (unit tests
    poking the branch directly don't count — that's the test MAINTAINING the phantom);
(3) ALIBI COMMENTS — "in case X…" where the graph shows another layer's contract forbids or owns
    X;
(4) STACKED IDEMPOTENCY — retry over retry, dedupe over dedupe, recovery duplicating the
    caller's recovery;
(5) PROVENANCE — fixes that landed without a failing repro, and fixes born in audit rounds whose
    promise no one ratified.
REMOVAL ORDER (the danger is a phantom MASKING a real upstream gap):
- first prove ownership at the owning layer with a test THERE;
- only then delete the duplicate;
- prove the deletion by the owner's test staying green AND the deleted guard's zero
  reachability count — AND the owning product lane green (units are not a verdict).
- If the counter fires, it was not phantom — you found a real upstream gap or genuine shared
  responsibility; move it to the owner deliberately, never keep both.

PHASE C — CONVERGE.
Execute the convergence plan:
- separate revert-ready commits,
- behavior preserved (every moved mechanism's tests move with it; transient probes re-run and
  lethal in the new home — a refactor voids prior probe results for moved code),
- adversarially gated before push.
Keep convergence behavior-preserving; ask external maintainers about behavior or public-surface
changes and decide changes authorized by the user’s task (`code §Owner code and authority`).
Finish by distilling the graph into a short design doc a maintainer can read in one sitting: the
concept list, the stable/brittle boundary, the glossary, how it all fits together.
Then run Owner-Safe closure reconciliation:
- prove every SETTLED decision propagated to its named surfaces;
- every unit/finding is closed or held with a reason;
- code/tests/docs/types/UI/PR state agree;
- reviewer and fresh Guardian evidence is attached;
- CI, owning lanes, mutations, reference captures, and clean-tree scope are observed.
Finality is not complete while any of those joins disagrees.
```
