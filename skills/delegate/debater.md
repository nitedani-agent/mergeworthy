# Debater brief (a decision question or a design point)

Standards: `~/.mergeworthy/current/skills/code/SKILL.md` §Earn every line, §Deep modules. Include `delegate/agent.md`.

One fresh-context agent (`design` step 3): it first generates without judging, then judges. The main session rates its recommendation (`pull-request §Rating`) and decides.

```
The question: <the maintainer's comment, with its link>. The thread record: <abs>/drafts/<thread>/thread-context.md.
The evidence so far: the flow traced in code (caller → callee, which object each side sees, in each environment) <path:line list>; what main does: <...>; measurements: <...>.
The project file: <project file path>.

1. Generate, no judging: the strongest case for the maintainer's view and the strongest case against. Each case from at least three frames, past the obvious first answers: the user who hits it, the maintainer who keeps the code, the smallest diff, the version with no new code, the design from scratch.
2. Answer the question behind the literal one: is the defect a class (a default, a parser, a shared helper)? Then the class-wide fix with its evidence. Is "over-engineering" the right call, or is there a small, cleaner fix?
3. Only then judge: score both sides, name each side's weakest point and the traps (hidden cost, a fix for a case nobody hits), and recommend. When the evidence rejects the maintainer's suggestion, give a measured way to reach its goal.
4. Build the simpler version (theirs, or the simplest option of your comparison) and name what breaks in it.

Write <abs>/drafts/<thread>/<name>.debate.md, ending with a line `SIMPLER: <what breaks, or nothing>`.
Final message: the recommendation in one line, and the SIMPLER line.
```
