---
name: rules
description: "A rule failed or the user names a failure; a 👎; editing a skill, prompt or rules file; the steward's tick and its FOLLOW-UPs: fix the instance, then the rule, or the steward's inbox."
---

# Rules

## Steps

1. **A named failure** ("why didn't you…?" or "why are you not…?" about something already required, or a 👎): give one line of why, stop, re-read, and fix the instance now (the PR, the comment, the code).
   Record: the fixed artifact
2. **Whose rule is it?** A rule of another repo (its `AGENTS.md`, `CLAUDE.md` or rules files): fix it there, through that repo's own workflow (`task`), and stop here. A mergeworthy rule, when `~/.mergeworthy/steward` (`<work folder> <T3 thread id>`) names another session: only the steward and its agents commit to mergeworthy, so write the fix as one line in `<the steward's work folder>/inbox.md`, and stop here. You are the steward if that is your T3 thread or your delegator's, or `<work folder>/session` names your session. No steward declared: you own the fix; go on.
   Record: the inbox line · Hook: pre-bash-guard (a commit or push to mergeworthy by any other session while a steward is declared)
3. **Fix the mergeworthy rule where it bites.** Find the step (always-on row → skill → step). Grep first and change the text that already covers it, never add beside it; merge any overlap you find. Make exactly the requested operation on exactly the named text; text the user supplied verbatim stays verbatim.
   Open: §Editing · Record: the diff · Hook: pre-skill-gate (an edit to a skill or rules file waits for `rules`)
4. **Cold read:** a fresh agent reads each changed file cold and lists every sentence it can't act on; fix those sentences.
   Open: `delegate/reviewer.md` (cold-read variant) · Record: its report
5. **Ship it.** `tests/all.sh .` exits 0, then commit and push in the same step (`git config core.hooksPath .githooks` makes the pre-push hook enforce it), and confirm CI is green. Update every installed copy of mergeworthy (one per agent program: Claude Code, Codex) through its install command (README, Install), check its version, and probe the failure again there. Never edit an installed or running copy.
   Run: `tests/all.sh .` · Record: the commit, the CI run · Hook: the pre-push hook
6. **Steward tick** (with no steward declared, every session sorts its own `### FOLLOW-UP`s this way): read `inbox.md`. Sort each `### FOLLOW-UP` within 30 minutes of its time in `events.log`: brief the sort, then write one line `<sha or PR URL> MISS|TASTE|WORKED|DIRECTION <link or reason>` in `followups-sorted.txt` ("nothing to act on" is no verdict). TASTE and WORKED: the line goes into the project file once `git show <sha>` confirms the commit makes that change. MISS: steps 3–5. DIRECTION: the line alone; nothing else changes.
   Open: `delegate/followup-sort.md`; `task §Project file` · Record: followups-sorted.txt · Hook: stop-lint (30 minutes)

### Editing

- **The minimal delta,** placed at the step where it bites. No rationale, no incident stories, nothing an agent of the main session's model class at medium effort (`delegate §Model class`) does unprompted. Repo facts go only in the project file; method goes only in the skills.
- **Keep the word count flat or lower:** `tests/word-budget` fails when the skills grow past `tests/word-budget.txt`; raising it needs the reason nothing existing could carry the change, in the commit message.
- **Prefer a mechanism to a sentence** when the failure has a detectable trigger or came back after its rule existed: a sentence alone fixes nothing that recurred. A mechanism ships whole, the first time: it starts, restarts after a crash and a reboot, retires when its job is done, and runs one instance per job. Before calling it done, test it by killing it and finishing its job.
- **State the behavior you want** ("write one-line comments"), not only the one you don't. Keep a "never" for hard guardrails, paired with what to do instead.
- **No self-assessed opt-outs** ("skip on small fixes"). A missing precondition is a hard stop.
