# Shape brief (Loop B: cut, reshape, rate)

Standards: `~/.mergeworthy/current/skills/code/SKILL.md`. Include `delegate/agent.md`.

One read-only agent, after the reviewer brief in the same run (`converge` step 2), rating whole slices with fresh eyes every round. This brief says how to audit; the agent decides what to flag. Three steps, in order. An implementer (`delegate/implementer.md`) lands what you decide commit by commit; the same agent then re-rates (`delegate §Continue`: in T3 Code, a new task carrying this report). Step 2's prompt is the user's text and applies unchanged in every repo, whatever the project file says.

Dispositions, one list:
- **DELETE-NOW:** remove; behavior-preserving, no probe needed.
- **FIX:** an exact behavior-preserving change.
- **FILL:** a gap to fill (a missing test of a documented contract, a missing sibling case).
- **DELETE-CAREFULLY:** remove only after code §Removal gate's probe.
- **OWNER-DECISION:** owner code, a behavior or public-surface change, or anything the task doesn't authorize; it goes in the PR body's decision blocks or the report to the user, with a recommendation.
- **KEEP:** checked and worth its price.

```
You shape <PR>: `git diff <base> <head>`, in <worktree>; everything in it, tests included. Reading order, slice by slice: <the slices' file lists, or none>.
The project file: <project file path>. The invariants and settled picks: <decisions/*.md>; keep them intact.
Evidence: <the verifier's and reviewer's reports>.
First read ~/.mergeworthy/current/skills/code/SKILL.md §Phantom gate, §Docs are a claim and §No regressions in full; your shape report starts with `## Standards read`, the first sentence of each copied.
Read with git at the pinned SHAs; run specs only in your own worktree under <work folder>, removed when done; don't build or run <shared apps>.

Step 1, cut what shouldn't exist. Check every line of code §Checklist. Each finding: path:line, the checklist line, its disposition, its price in lines, and the exact change for behavior-preserving ones.
- Code and docs that disagree: code §Docs are a claim. Owner code: code §Owner code and authority.
- Docs, a README or JSDoc in the diff: docs steps 2–3 (the right page, the minimum, the siblings' shape and length).
- Each finding must earn its diff (code §Earn every line). Each project-file line the diff breaks is a finding that quotes it.
- When the change follows a reference (a design, a mockup, another project): compare every screen and interaction the reference shows with the head.
- When the change is to a methodology (skills, prompts, hooks): check that every named mechanism survived, and fail any compressed into generic prose.
- A closure claim without a tree, lane or capture you observed yourself stays open. Mark unavailable evidence UNKNOWN.

Step 2, reshape what stays: the prompt below, as written, on what step 1 keeps, with its ✅ coverage list.

Step 3, rate every file and function old ⇒ new: after each landing, re-rate every row with its commits, verify each implementation (behavior preserved, mutation probes still red, comments true), and say whether each decline holds.

<Round N only: the previous report is <path>; its findings were implemented in <commits>; declined, with reasons: <list>. Run all three steps fresh, not only the old list.>

Write <report path>: step 1's findings, DELETE-NOW first, then FIX, FILL, DELETE-CAREFULLY, OWNER-DECISION; the mechanism census; the 10-second pass as classes; step 2's ratings and ✅ coverage list; step 3's old ⇒ new ratings and the prior findings' closure; an honest-positive statement ("nothing worth changing" where that is the result). End the file with a line CLEAN only when your review in this run and all three steps leave nothing behavior-preserving whose value is worth its price.
Final message: the path, counts per disposition, the three highest-value findings, the overall rating.

<the prompt below, verbatim>
```

The PR body shows the summary (old ⇒ new, each linked to its commits, and a link to the whole diff of the pass); the full lists go in a gist.

## The prompt

The user's text, word for word. Its words: *pinnacle* is the ideal split into files and functions, the shape the code would have if designed today, from scratch; the *✅ coverage list* is the separate tick list of every file, function and piece of logic, proving none was skipped.


Refactor this PR:

- Pinnacle architectural split
  - Does each file and each function represent a sensible abstraction that is easy to understand?
  - Rate the SEAMS, not just the boxes: for each call site, ask whether the responsibility sits
    on the right side of the boundary — should a caller's wrapper move down into the callee (or
    vice versa)? A function can be clean, DRY and well-tested in isolation yet still be in the
    wrong place. "Well-factored" is not "well-located".
  - Before starting to work: list ALL files and ALL functions in this chat, rate them all
    (0: convoluted abstraction, hard to understand, not DRY — 10: perfect), and give a reason for
    your rating.
    - DON'T skip any file nor any function — write an extra separated ✅ tick list of all files
      and functions to double-check nothing was forgotten. Two lists: ratings & explanations,
      then the ✅ coverage list.

- Simplify
  - Review ALL logic. Can implemented logic be simplified?
  - Do you see logic implemented twice, in the diff or anywhere in the codebase? For each constant,
    literal or import the new code uses, grep the repo for its other uses: an existing function that
    already does this work is a reuse finding.
  - Can boilerplate be removed? Frivolous indirections? Frivolous tiny functions? Can we merge
    functions to make reading code easier (jumping between functions is costly when reading code
    linearly, which is what humans do)?
  - Put yourself in the shoes of a human reader who reads everything in a linear fashion.
  - Altitude pass: for each entry-point / orchestration function, read it top-to-bottom as prose.
    Flag any line that drops the reader into lower-level mechanism (a flag, a thunk, a log verb,
    error plumbing) in the middle of what should be a high-level narrative. For each, ask: can
    that mechanism move down into the callee so the caller reads at one consistent altitude?
    Prioritize the reading path of the functions a reader hits first.
  - Before starting to work: list ALL logic in this chat, rate each (0: bad — 10: perfect) with
    reasons — 100% coverage, plus the separated ✅ tick list.

- How to scrutinize (don't rubber-stamp what's already there)
  - Code comments that justify a design ("X lives here rather than Y so that…") are claims to
    audit, not constraints to respect. For each, construct the alternative it argues against and
    compare — don't assume the documented choice is optimal.
  - For anything you rate 8 or above, do one more pass asking only: is it at the right altitude
    and on the right side of its boundary?

- Work until it's exceptionally good. We as an expert team will check against every little detail.
  - If we see mostly 10/10 ratings, that's a sign you've been lazy — scrutinize everything and
    spend a substantial amount of time. We don't want to prompt you again and again to achieve
    quality — autonomously strive for quality on your own without us pushing you.

- End with a summary of what you worked on: print the lists again with old rating ⇒ new
  rating with link to commit(s).
