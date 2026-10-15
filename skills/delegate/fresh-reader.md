# Fresh-reader brief (the last check before ready, with the maintainer's eyes)

Standards: `~/.mergeworthy/current/skills/code/SKILL.md`, `~/.mergeworthy/current/skills/writing/SKILL.md` §Self-check. Include `delegate/agent.md`.

A new agent each round, blind to the fixes and earlier reports (`converge` step 4): the loop agents judge their own suggestions. The main session fills it only once the project file exists (`task §Repo study`). Paste after it: `delegate/verifier.md`'s brief, `delegate/reviewer.md`'s brief, `delegate/post-review.md`'s brief for the body draft, and, where `finality` ran, step 1 of `delegate/shape.md` (only DELETE-NOW, FIX, FILL or DELETE-CAREFULLY items worth their price count; OWNER-DECISION rows go in the body's decision blocks).

```
You read <PR> cold, at head <SHA> (origin/<base> merged in), in <worktree>.
The project file: <project file path>. The repo study: <its path, from the project file's ## Who decides>.
The PR body draft: <work folder>/drafts/<pr>/pr-body.md.
<Docs in the diff: also the rendered page and two sibling pages alone; answer docs' two questions: can I do the task from this, and which sentences read unlike the siblings.>

First read ~/.mergeworthy/current/skills/code/SKILL.md §Phantom gate, §Docs are a claim and §No regressions in full; your report starts with `## Standards read`, the first sentence of each copied.
Before reading the diff, become the maintainer:
1. Find who decides: who merges PRs here and who wrote most of the code this PR touches (`gh pr list --state merged --limit 100 --json mergedBy`, `git log --format=%an -- <changed files> | sort | uniq -c | sort -rn`, `git blame` on the changed lines, the project file's ## Who decides, the repo study). Name one person: the one who will merge this.
2. Load the project file and the repo study in full.
3. Refresh the study from its date: read that person's review comments since then (up to their last 30) (`gh search prs --repo <owner/repo> --reviewed-by <login> --limit 30`, then each PR's review comments) and their commits on our PRs (`gh pr list --repo <owner/repo> --author <our login> --state all`, then the commits on each not authored by us).

Then answer: You are <maintainer>: which comments would you leave, and would you merge this exactly as it is?
Every finding cites something that maintainer said or did (a comment, a review, a commit), with its link; a finding you can't tie to them goes under "Not theirs", one line each. Before judging a line, `git blame` it: a line from the maintainer's own commit is theirs, and where it contradicts the project file, list the project-file line under "Stale in the project file" with the blame link (the main session fixes it), never the code as a finding. Each finding that cites them and the study lacked goes under "New to the study", one line each with its link. A convention question (a bump, a changeset's package list, a file's form) is settled from the repo's last merged examples, quoted, never from a tool's config; matching the maintainer's suggested text proves only the part he wrote.
Run each brief below on the head and the body draft, each into its own section.

Write <work folder>/drafts/fresh.report.md: a line `Maintainer: <login>`; `MERGE AS IS: yes`, or `no` with every comment you'd leave, each a finding; then each brief's section; end the file with CLEAN when nothing was found.
Write the post-review brief's verdict alone to <work folder>/drafts/<pr>/pr-body.review.out: exactly CLEAN, or that brief's findings only.
Final message: exactly CLEAN, or the findings.
```
