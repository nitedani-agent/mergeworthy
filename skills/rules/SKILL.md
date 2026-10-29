---
name: rules
description: "A rule failed or the user names a failure; a 👎; editing a skill, prompt or rules file; the steward's tick, its FOLLOW-UPs and MAINTAINER REVIEWs: fix the instance, then the rule, or an issue for the steward."
---

# Rules

## Steps

1. **A named failure** ("why didn't you…?" or "why are you not…?" about something already required, or a 👎): stop, re-read, and fix the instance now (the PR, the comment, the code). Then find why in the faulty session's own transcript (a Claude Code `.jsonl` under `~/.claude/projects/`, a T3 thread, a Codex log): the brief it got, what it loaded, and the turn where it decided wrong, quoted with its line. A cause read off its report or the rule text is a guess, and steps 2–5 fix the rule that turn shows failed.
   Record: the fixed artifact
2. **Whose rule is it?** A rule of another repo (its `AGENTS.md`, `CLAUDE.md` or rules files): fix it there, through that repo's own workflow (`task`), and stop here. A mergeworthy rule is the steward's to fix. You are the steward if `~/.mergeworthy/steward` (`<work folder> <T3 thread id>`) names your T3 thread or your delegator's, your working directory is inside that work folder (none declared: `~/.mergeworthy/work/steward`), or `<work folder>/session` names your session: go on. Otherwise open an issue on nitedani/mergeworthy (`open-issue`) with the fault, its evidence and the fix you'd make, which wakes the steward; meanwhile work around it. Its closing wakes you.
   Record: the issue · Hook: pre-bash-guard (a commit or push to mergeworthy by any other session while a steward is declared)
3. **Fix the mergeworthy rule where it bites.** Find the step (always-on row → skill → step). Search first (`rg`, and semantic search for other wording: `delegate/agent.md` §Code search) and change the text that already covers it, never add beside it; merge any overlap you find. Make exactly the requested operation on exactly the named text; text the user supplied verbatim stays verbatim.
   Open: §Editing · Record: the diff · Hook: pre-skill-gate (an edit to a skill or rules file waits for `rules`)
4. **Cold read:** a fresh agent reads each changed file cold and lists every sentence it can't act on; fix those sentences.
   Open: `delegate/reviewer.md` (cold-read variant) · Record: its report
5. **Ship it.** `tests/all.sh .` exits 0, then commit and push in the same step (`git config core.hooksPath .githooks` makes the pre-push hook enforce it), and confirm CI is green. Update every installed copy of mergeworthy (one per agent program: Claude Code, Codex) through its install command (README, Install), check its version, and probe the failure again there. Never edit an installed or running copy.
   Run: `tests/all.sh .` · Record: the commit, the CI run · Hook: the pre-push hook
6. **Follow-ups.** Every session whose `events.log` receives a `### FOLLOW-UP` or a `### MAINTAINER REVIEW` (each defect the review names) sorts it: the watcher sends it to the steward's while its watcher runs, else to each session watching the PR. Within 30 minutes of its time (the steward: its next pass), brief the sort, then write one line `<sha, PR or review URL> MISS|TASTE|WORKED|DIRECTION <link or reason>` in your own work folder's `followups-sorted.txt` ("nothing to act on" is no verdict). TASTE and WORKED: the line goes into the project file once `git show <sha>` confirms the commit makes that change (for a review, once its quoted words say it); then, in the same step, find each of our open PRs that breaks the line (`gh search prs --author <our login> --state open --repo <repo>` for every repo that maintainer merges or publishes), fix each through `reply`'s instruction row, and list the PRs checked under the line in `followups-sorted.txt`. MISS: steps 2–5 (step 2 decides whether you fix the rule or open an issue). DIRECTION: the line alone; nothing else changes.
   Open: `delegate/followup-sort.md`; `task §Project file` · Record: followups-sorted.txt · Hook: stop-lint (30 minutes)

### Editing

- **The minimal delta,** placed at the step where it bites. No rationale, no incident stories, nothing an agent of the main session's model class at medium effort (`delegate §Model class`) does unprompted. Repo facts go only in the project file; method goes only in the skills.
- **Keep the word count flat or lower:** `tests/word-budget` fails when the skills grow past `tests/word-budget.txt`; raising it needs the reason nothing existing could carry the change, in the commit message.
- **Prefer a mechanism to a sentence** when the failure has a detectable trigger or came back after its rule existed: a sentence alone fixes nothing that recurred. A mechanism ships whole, the first time: it starts, restarts after a crash and a reboot, retires when its job is done, and runs one instance per job. Before calling it done, test it by killing it and finishing its job.
- **State the behavior you want** ("write one-line comments"), not only the one you don't. Keep a "never" for hard guardrails, paired with what to do instead.
- **No self-assessed opt-outs** ("skip on small fixes"). A missing precondition is a hard stop.
