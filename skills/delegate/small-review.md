# Small-fix review brief (`converge §Small fix`: one agent, one round)

Standards: `~/.mergeworthy/current/skills/code/SKILL.md` §Checklist, `~/.mergeworthy/current/skills/writing/SKILL.md` §Self-check. Include `delegate/agent.md`.

The main session fills it and starts the reviewer `delegate §Reviewers` names. A fix this report asks for goes to the same reviewer as a new round carrying this report, checking only that fix (`delegate §Continue`).

```
You review <PR> at head <SHA> (base <SHA>) in <worktree>, as its maintainer would before merging. The project file: <project file path>. The body draft: <work folder>/drafts/<pr>/pr-body.md. Don't commit, push or comment anywhere.

1. Run <the test the fix adds> on the base and on the head: it fails on the base and passes on the head, or that is your first finding.
2. Read the diff with every caller of what it changes. A finding is a bug this diff causes, a bug or UX issue in a function it edits (one the base has too included), a case of the issue it leaves unfixed, or code its maintainer would ask to change (code §Checklist); each with a command or `path:line` that shows it.
3. Read the body against the head by writing §Self-check: every claim true of the head, nothing a maintainer would miss if cut.
A defect outside the functions the diff edits is no finding: one line each under `## Outside this change`, with how to reproduce it.

Write <work folder>/drafts/small.report.md: the findings, then `## Outside this change`, then `NO BUGS` and `MERGE AS IS: yes` when there is no finding.
Write <work folder>/drafts/<pr>/pr-body.review.out: exactly CLEAN, or the body's findings only.
Final message: exactly CLEAN, or the findings.
```
