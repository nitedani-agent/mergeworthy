# Implementer brief

Standards: `~/.mergeworthy/current/skills/code/SKILL.md` (read it before the first line). Include `delegate/agent.md`.

```
You implement <the plan, or the finding IDs> on <PR or task>, in <repo> at <head SHA>.
The project file: <project file path>; its repo study: <the .study.md it links>. Read both, and code/SKILL.md, before writing: write what <the login under the project file's ## Who decides> would merge exactly as it is (the study holds their asks, cuts and rewrites and the forms they merge).
The critical-path item this unblocks: <item>.

Setup: git worktree add -b impl/<name> <dir> <head SHA>; install; build once.
Work only there; never stash; stage files by name.

Implement exactly: <the plan, or these finding IDs from <report>>.
Not these: <owner decisions and exclusions>.

For every item:
- read the code end to end and check it is true at <head SHA>;
- skip it with a reason if it is false or cannot be an authorized, behavior-preserving change (code §Owner code and authority);
- make the smallest change, plus the fixes the main session decides under task §Dispositions, meeting code/SKILL.md so the next review has nothing to add;
- a removed, merged or moved test or guard gets a mutation probe (code §Tests).

Run <quick gates> after every commit and <lanes for touched areas> before handing back (code §Gates).
One commit per item or class; message: <style>; author: <login> <noreply email>; trailer: <the agent trailer, the `Co-Authored-By:` line your harness adds to agent commits>.
Before handing back, run code §Checklist on your own diff and fix what it catches; a diff touching a body, buffer, stream, cancellation, a transport or a hot path (when unsure, it does) is checked against code §No regressions' nine items before each commit, and your final message answers them under `## Bodies and streams`. A test you add follows the maintainer's test habit (code §Tests); a finding is fixed in the code, with a test only where that habit keeps regression tests.

Final message: commits (sha, subject, IDs), skipped items with reasons, probes and results, the gates as `<command> -> exit <code>`, ending with what that run measured: `(N tests)` for a test run, `(N projects)` for a type check, `(N words)` for a word count.
```

A shape pass's findings: the IDs come from its report; the Loop B agent re-rates your result independently.
