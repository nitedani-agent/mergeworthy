---
name: docs
description: "Writing or changing docs a user reads (a docs page, a README, JSDoc, an llms.txt line): the project's docs voice, where the text belongs, the shape, drafting from the closest sibling page, and the docs reader."
---

# Docs

A docs change passes when a maintainer would have written it: imitating the project's own pages produces that, and the checks only confirm it. The voice is the project's, never the warm first person of a post; `writing` covers how any words read.

## Steps

1. **The voice profile:** the project file's `## Docs voice` section, each line a rule with a page path as its example; give it to every agent that writes docs. Missing: derive it before the first draft. Read at least 8 sibling pages of the kinds you will write (reference, guide, concept) in full, plus the contributing guide and the docs lint. Read the maintainer's own edits on docs, above all what they changed on an agent's or a contributor's page: what they cut, shorten or move is the profile. Note how a page opens, sentence length, what goes in a `>` note and what in a section, the components and link form, code block conventions (file path comment, environment line), heading case, what a reference entry contains, how long the longest section is, how pages end, and what the project's docs never do. Update a line when a later edit contradicts it; keep only what would change your next draft.
   Run: `git log --author=<maintainer> -p -- docs/ | head -2000` · Record: the `## Docs voice` section
2. **Placement:** where would a user with this task look, and what exists there?
   - Match the kind of page to the content: reference for what a thing is and does, a guide for a task, a concept page for why. Mixing them is the usual fault.
   - A new public thing gets what its siblings have (its own page with its header, a one-line entry in the property list, the index or `llms.txt` line), each as short as its siblings' entries.
   - What another page already says is linked, never repeated. A comparison table gets a row, not a section.
   - A link replaces an explanation, never the code a user copies for their setup: show every case the project's own pages show (each server tab the siblings have), each with working code.
   - A rare case belongs on the page of the thing it concerns, or nowhere.
3. **Draft by imitation, in the shape.** Pick the closest sibling page (same kind, same neighbours in the nav) and the closest section in it; copy its structure, header, sentence order, code block form and note style, and put your content into that frame. Where the frame has no slot for a sentence, the sentence is a candidate for deletion.
   - Lead with the common case and its code, so a reader who stops after the first block has done the task. Details go later, in a `>` note or behind a link, in the order users hit them.
   - Say what a user can act on; leave out how it works inside, a dependency's helpers, and hedges about cases the user can't reach.
   - Describe how it works now, never its history: no "now", "no longer", "instead of", "unlike before". That belongs in the PR.
   - A sentence that says when something applies states its exact condition and one example with real names, in words the docs already use.
   - Keep sections near their siblings' length; one several times longer is probably two pages, or details that don't belong.
   Record: the draft
4. **The docs reader:** a fresh agent with only the rendered page and two sibling pages: (a) can I do the task from this, and (b) which sentences read unlike the siblings? Fix the text from step 3 until (a) is yes and (b) is empty.
   Open: `delegate/docs-reader.md` · Record: its report
5. **Gates:** the project's docs lint and spellcheck; update `llms.txt` or the index where the project keeps one. In a PR, `converge` covers the docs with the code; docs that disagree with the code: `code §Docs are a claim`.
   Open: the project file's Gates · Record: the gates log
