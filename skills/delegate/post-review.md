# Post-review brief (every post's independent review)

Standards: `~/.mergeworthy/current/skills/writing/SKILL.md` (§Self-check is what you check). Include `delegate/agent.md`.

The main session fills it at `post` step 3 and starts the reviewer `delegate §Reviewers` names. **Fast form** (a reply of a few claims: "Done in <sha>", a holding reply): only the Claims check, on those claims.

```
Review the draft <abs>/drafts/<thread>/<name>.md (kind: <kind>) before it is posted on <owner/repo#N>.
The comment it answers: <name>.parent.md. The thread record: <abs>/drafts/<thread>/thread-context.md. The head: <SHA> in <worktree>.
Check facts and noise, not word choice. Each finding: the sentence, what's wrong, what it should say.

- Claims: every claim against the code (file:line or a command and its output), the thread and the evidence. Every claim about who said, proposed or agreed what against thread-context.md's permalinks; an unsupported attribution is a finding.
- Noise:
  - every con or risk names who hits it today (a caller, repo or user), or is cut;
  - the shortest version that still answers is the verdict, its one reason, the next step; every sentence outside it the reader wouldn't miss is a finding (mechanism nobody asked for, a justification of a justification, a reason true by definition, an "anyway" clause). True is not enough;
  - every question in the parent is answered; a gap in the author's work that a question points at is fixed before the reply, not offered;
  - every absolute word ("every", "unchanged", "always", "only") quotes what proves it, or is cut;
  - maintainer requests are followed, and links are correct.
- Convergence (design threads): the reply states its author's position and the design's weakest part; a change of position names the new evidence; every open invariant is a stated default or a question only the other side can answer, as few as that allows.
- Opening: from the opening alone, state the problem and, for a PR body, the change; if you can't, that's a finding.
- Reader: you have not seen this thread. List every term or sentence you can't understand, and say in one line what the reader is asked to decide. A decision you can't identify, a pronoun with two meanings, a term not yet seen, a sentence to read twice, or a bold label or fragment standing in for a sentence is a finding. So is anything writing/SKILL.md §Self-check catches.

Write the full findings to <abs>/drafts/<thread>/<name>.review.md.
Final message: exactly CLEAN, or the findings.
```
