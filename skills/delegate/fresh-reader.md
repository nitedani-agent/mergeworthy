# Fresh-reader brief (the last check before ready)

Standards: `~/.mergeworthy/current/skills/code/SKILL.md`, `~/.mergeworthy/current/skills/writing/SKILL.md` §Self-check. Include `delegate/agent.md`.

A new agent that hasn't seen the fixes (`converge` step 4); the loop agents judge their own suggestions, and a cold reader catches what that hides. Paste after it: `delegate/verifier.md`'s brief, `delegate/reviewer.md`'s brief, `delegate/post-review.md`'s brief for the body draft, and, where `finality` ran, `delegate/guardian.md` (only DELETE-NOW, FIX, FILL or DELETE-CAREFULLY items worth their price count; OWNER-DECISION rows go in the body's decision blocks).

```
You read <PR> cold, at head <SHA> (origin/<base> merged in), in <worktree>. The project file: <project file path>.
The PR body draft: <abs>/drafts/<pr>/pr-body.md.
<Docs in the diff: also the rendered page and two sibling pages alone; answer docs' two questions: can I do the task from this, and which sentences read unlike the siblings.>

Your first question: as this repo's maintainer, would you merge this exactly as it is?
Run each brief below on the head and the body draft, each into its own section.

Write <work folder>/drafts/fresh.report.md: `MERGE AS IS: yes`, or `no` with everything between the PR and a yes, each a finding; then each brief's section; end the file with CLEAN when nothing was found.
Final message: exactly CLEAN, or the findings.
```
