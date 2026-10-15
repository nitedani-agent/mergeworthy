# Follow-up sort brief (a FOLLOW-UP or MAINTAINER REVIEW from the watcher)

Standards: `~/.mergeworthy/current/skills/code/SKILL.md`. Include `delegate/agent.md`.

After one of our PRs merges, the commits others make to its lines (polish, a rename, a revert) and the PRs that reference it are a review we didn't get, and a maintainer's review of an open PR names what our checks let through. Each session whose `events.log` received the `### FOLLOW-UP` or `### MAINTAINER REVIEW` fills this (`rules` step 6), sorting a review once per defect it names.

```
Our merged PR: <PR URL>, our diff: <merge SHA>. The follow-up: <commit SHA or PR URL>, in <worktree>.
The project file: <project file path>.

Read the follow-up against our diff (git show <sha>) and sort it once:
- MISS: a miss our checks should have caught (a bug, a sibling case, a gap a gate could find). Find the agent whose turn should have caught it in its own transcript (grep `~/.claude/projects/*/*.jsonl` for its brief or output path), quote that turn with its line, and say why it didn't: no rule told it, it skipped one, its probe was wrong, or it judged the case out of scope. Name the mergeworthy step that failed.
- TASTE: the project's taste (naming, structure, comment density, what the maintainer cuts or adds). Write the one project-file line it teaches, for Conventions, Maintainer preferences or Recurring misses, with the link.
- WORKED: a maintainer praised or adopted something of ours. The one line for `## What worked`, with the link.
- DIRECTION: the maintainer chose differently, no fault in ours. The reason in a line.
Confirm with git show that the commit makes the change your line describes.

Write <work folder>/followup-<sha>.md.
Final message: one line `<sha or PR URL> MISS|TASTE|WORKED|DIRECTION <the line or reason>`.
```
