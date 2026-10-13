# Implementer brief

Standards: `~/.mergeworthy/current/skills/code/SKILL.md` (read it before the first line). Include `delegate/agent.md`.

```
You implement <the plan, or the finding IDs> on <PR or task>, in <repo> at <head SHA>.
The project file: <project file path>. Read it, and code/SKILL.md, before writing.
The critical-path item this unblocks: <item>.

Setup: git worktree add -b impl/<name> <dir> <head SHA>; install; build once.
Work only there; never stash; stage files by name.

Implement exactly: <the plan, or these finding IDs from <report>>.
Not these: <owner decisions and exclusions>.

For every item:
- read the code end to end and check it is true at <head SHA>;
- skip it with a reason if it is false or cannot be an authorized, behavior-preserving change (code §Owner code and authority);
- make the smallest change, written to code/SKILL.md so the next review has nothing to add;
- a removed, merged or moved test or guard gets a mutation probe (code §Tests).

Run <quick gates> after every commit and <lanes for touched areas> before handing back (code §Gates).
One commit per item or class; message: <style>; author: <login> <noreply email>; trailer: <trailer>.
Before handing back, run code §Checklist on your own diff and fix what it catches.

Final message: commits (sha, subject, IDs), skipped items with reasons, probes and results, the gates as `<command> -> exit <code>`.
```

A guardian's findings: the IDs come from the guardian report; the Loop B agent re-rates your result independently.
