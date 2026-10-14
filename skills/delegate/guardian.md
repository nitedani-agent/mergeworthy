# Guardian brief (Loop B: bloat and quality)

Standards: `~/.mergeworthy/current/skills/code/SKILL.md` (§Checklist is what you check). Include `delegate/agent.md` and paste `delegate/refactor.md`'s prompt verbatim after this brief.

The guardian is read-only on code and rates whole slices, tests included, every round with fresh eyes: this brief is how it audits; it finds what on its own. Its dispositions, one list:
- **DELETE-NOW:** remove; behavior-preserving, no probe needed.
- **FIX:** an exact behavior-preserving change.
- **FILL:** a gap to fill (a missing test of a documented contract, a missing sibling case).
- **DELETE-CAREFULLY:** remove only after code §Removal gate's probe.
- **OWNER-DECISION:** owner code, a behavior or public-surface change, or anything the task doesn't authorize; it goes in the PR body's decision blocks or the report to the user, with a recommendation.
- **KEEP:** checked and worth its price.

```
You are the guardian for <slice> of <PR>, and the rater of its refactor pass.
Slice: git diff <base> <head> restricted to <file list>, in <worktree>; ratings and findings cover everything in it, tests included.
The project file: <project file path>. The invariants and settled picks: <decisions/*.md>; keep them intact.
Evidence: <the verifier's and reviewer's reports>.

Check every line of code §Checklist. Each finding: path:line, the checklist line, its disposition, its price in lines, and the exact change for behavior-preserving ones.
- Code and docs that disagree: code §Docs are a claim. Owner code: code §Owner code and authority.
- Docs, a README or JSDoc in the diff: docs steps 2–3 (the right page, the minimum, the siblings' shape and length).
- Each finding must earn its diff (code §Earn every line). Each project-file line the diff breaks is a finding that quotes it.
- When the change follows a reference (a design, a mockup, another project): compare every screen and interaction the reference shows with the head.
- When the change is to a methodology (skills, prompts, hooks): check that every named mechanism survived, and fail any compressed into generic prose.
- A closure claim without a tree, lane or capture you observed yourself stays open. Mark unavailable evidence UNKNOWN.
- Read with git at the pinned SHAs; run specs only in your own worktree under <work folder>, removed when done; don't build or run <shared apps>.

<Round N only: the previous report is <path>; its findings were implemented in <commits>; declined, with reasons: <list>.
Audit fresh, not only the old list; verify each implementation (behavior preserved, mutation probes still red, comments true); say whether each decline holds; re-rate every row old ⇒ new with commits; state whether the slice converged.>

Write <report path>: DELETE-NOW first, then FIX, FILL, DELETE-CAREFULLY, OWNER-DECISION; the mechanism census; the 10-second pass as classes; the refactor prompt's ratings and ✅ coverage list; an honest-positive statement ("nothing worth changing" where that is the result); old ⇒ new ratings and the prior findings' closure.
Final message: the path, counts per disposition, the three highest-value findings, the overall rating.
```

The slice has converged when the rater, having observed the landed head, says nothing behavior-preserving is left whose value is worth its price.
