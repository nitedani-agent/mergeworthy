# Fresh-reader brief (the last check before ready, with the maintainer's eyes)

Standards: `~/.mergeworthy/current/skills/code/SKILL.md`, `~/.mergeworthy/current/skills/writing/SKILL.md` §Self-check. Include `delegate/agent.md`.

A new agent that hasn't seen the fixes (`converge` step 4); the loop agents judge their own suggestions, and a reader who reviews as the maintainer catches what that hides. The main session fills it only once the project file exists (`task §Repo study`). Paste after it: `delegate/verifier.md`'s brief, `delegate/reviewer.md`'s brief, `delegate/post-review.md`'s brief for the body draft, and, where `finality` ran, step 1 of `delegate/shape.md` (only DELETE-NOW, FIX, FILL or DELETE-CAREFULLY items worth their price count; OWNER-DECISION rows go in the body's decision blocks).

```
You read <PR> cold, at head <SHA> (origin/<base> merged in), in <worktree>.
The project file: <project file path>. The repo study: <its path, from the project file's ## Who decides>.
The PR body draft: <abs>/drafts/<pr>/pr-body.md.
<Docs in the diff: also the rendered page and two sibling pages alone; answer docs' two questions: can I do the task from this, and which sentences read unlike the siblings.>

Before reading the diff, become the maintainer:
1. Find who decides: who merges PRs here and who wrote most of the code this PR touches (`gh pr list --state merged --limit 100 --json mergedBy`, `git log --format=%an -- <changed files> | sort | uniq -c | sort -rn`, `git blame` on the changed lines, the project file's ## Who decides, the repo study). Name one person: the one who will merge this.
2. Load the project file and the repo study in full.
3. Read that person's last 30 review comments (`gh search prs --repo <owner/repo> --reviewed-by <login> --limit 30`, then each PR's review comments) and their commits on our PRs (`gh pr list --repo <owner/repo> --author <our login> --state all`, then the commits on each not authored by us).

Then answer: You are <maintainer>: which comments would you leave on this PR, and would you merge it as is?
Every finding cites something that maintainer said or did (a comment, a review, a commit), with its link; a finding you can't tie to them goes under "Not theirs", one line each.
Run each brief below on the head and the body draft, each into its own section.

Write <work folder>/drafts/fresh.report.md: a line `Maintainer: <login>`; `MERGE AS IS: yes`, or `no` with every comment you'd leave, each a finding; then each brief's section; end the file with CLEAN when nothing was found.
Final message: exactly CLEAN, or the findings.
```
