---
name: docs
description: "Writing or changing a docs page, a README, or a JSDoc or llms.txt summary a user reads: the project's docs voice, where the text belongs, the shape, drafting from the closest sibling page, and the fresh-reader check."
---

# Docs that read as the project's own

True docs can still be wrong for the project: a section that explains every case, in the author's words, on the page nobody looks at. A docs change passes when a maintainer would have written it, so the producing step (core 1.1.17) is imitation of the project's pages, and the checks only confirm it. `writing` covers how any outward words read (no em dashes, no coined terms); this skill covers fit with one project's docs. The voice here is the project's, never the warm first person of a post.

### 1. The voice profile

A project's profile is a `## Docs voice` section of `~/.mergeworthy/projects/<owner>/<repo>.md`, each line a rule with a page path as its example. Read it before drafting and give it to every subagent that writes docs. If it is missing, derive it once, before the first draft:
- Read at least 8 sibling pages of the kinds you will write (reference, guide, concept) in full, plus the contributing guide and the docs lint.
- Read the maintainer's own edits on docs: `git log --author=<maintainer> -p -- docs/ | head -2000`, and above all what they changed on an agent's or a contributor's page. What they cut, shorten or move is the profile.
- Note: how a page opens, sentence length, what goes in a `>` note and what in a section, the components and link form, code block conventions (file path comment, environment line), heading case, what a reference entry contains, how long the longest section is, how pages end (see also), and what the project's docs never do.

Update a line when a later edit contradicts it. Keep only what would change your next draft.

### 2. Placement

Before writing, answer where a user with this task would look, and what already exists there.
- Match the kind of the page to the content: reference for what a thing is and does, a guide for a task, a concept page for why. Mixing them is the usual fault.
- A new public thing gets what its siblings have (their own page with its header, a one-line entry in the property list, the index or `llms.txt` line), each as short as its siblings' entries.
- What another page already says is linked, never repeated. A comparison table gets a row, not a section.
- A link replaces an explanation, never the code a user copies for their setup: show every case the project's own pages show (each server tab the siblings have), each with working code.
- A rare case belongs on the page of the thing it concerns, or nowhere.

### 3. Shape

- Lead with the common case and its code, so a reader who stops after the first block has done the task.
- Give the minimum a user needs. Details go later, in a `>` note or behind a link, in the order users hit them.
- Say what a user can act on. Leave out how it works inside, the names of a dependency's helpers, and hedges about cases the user can't reach.
- Describe how it works now, never its history: no "now", "no longer", "instead of", "unlike before", and nothing about what an earlier version did or why it changed. That belongs in the PR, not the docs.
- A sentence that says when something applies states its exact condition and one example with real names, in words the docs already use.
- Keep sections near the length of their siblings. A section several times longer than any neighbour is probably two pages, or details that don't belong.

### 4. Draft by imitation

Pick the closest sibling page (same kind, same neighbours in the nav) and the closest section in it. Copy its structure, header, sentence order, code block form and note style, and put your content into that frame. Where the frame has no slot for a sentence, the sentence is a candidate for deletion.

### 5. Verify

A fresh-context reader (`review`, Codex when available) gets only the rendered page text and two sibling pages, not the diff or your reasons. It answers:
- (a) Can I do the task from this alone, for each setup the page claims to cover (each server, framework or runtime)? Where do I get stuck?
- (b) Which sentences read unlike the siblings, and why?

Fix the text, from the producing step in 4, until (a) is yes and (b) is empty. Docs in a PR go through `converge`'s pipeline with its code (`converge`, Docs go through with the code). Run the project's docs lint and spellcheck, and update `llms.txt` or the index where the project keeps one. Docs that disagree with the code are a code question (`converge`, Docs are the contract).
