---
name: finality
description: "The finality pass, for code that has drifted through many patches, a design thread that has drifted over many rounds, being stuck with every option costing something ruled out, or a request for the ideal design: map, imagine, hunt phantom fixes, converge, close."
---

# Finality

Converges code or a design to the final state that will need no rewrite. The prompt is `delegate/finality.md`, the user's text; each step gives one agent its part. Called by `converge` step 0, `design` step 7 and `pull-request` steps 5–6; when done, return there.

## Steps

1. **When:** run it on your own, without being asked, when the work reshapes existing code rather than changing what it does, or a change meant to be small can't be made cleanly because the area has taken too many patches; when you're stuck (every option costs something the user ruled out, or two fixes in the same area haven't held), before bringing options to the user; when someone asks for the ideal design (brainstorming, "in a perfect world", the pinnacle); when a design thread has drifted (three or more rounds of proposals, or each reply answers only the latest idea), before the next reply, which then asks only what is open.
2. **Phase A, map:** one mapper for all subsystems when they fit one context, else one per subsystem in parallel; fresh-context agents, never the author's.
   Open: `delegate/finality.md` (PHASE A) · Record: the graph files in the work folder
3. **Phase B, imagine.** You write the clean problem first, as its users would state it, with no current design, file names or project terms: those anchor the branches on what exists. Then 6–9 frames from it, 3 branch agents with 2 or 3 frames each, then one converging agent with the graph and every branch's lists; all on your model class. You rate the pinnacle and decide.
   Open: `delegate/finality.md` (PHASE B) · Record: the pinnacle design and the ranked plan
4. **Phase B½, hunt phantom fixes:** the graph queries by the Phase B agent; instrumenting guards, running the full suite and e2e, and the removals by the implementer.
   Open: `delegate/finality.md` (PHASE B½); `code §Removal gate` · Record: the counters
5. **Phase C, converge:** behavior-preserving, revert-ready commits through an implementer, gates after each.
   Open: `delegate/implementer.md` · Record: commits
6. **The deliverable is the short design doc** (the graph is working material), posted through `post` (a gist counts) unless the repo keeps design docs. In a design thread, update the WIP comment from the map (`design §WIP comment`).
   Open: `post` · Record: the doc's link
7. **Owner-Safe closure,** last in `converge` step 5: it needs the reviewer's and the guardian's evidence.
   Open: `delegate/finality.md` (the closure paragraph and its header's glossary) · Record: the closure report
