# Memory-refresh brief (merging new session-log lines into memory.md)

`memory-prep prep <work folder>` writes the brief that names this file, the input, the read-through notes and `memory.md`; one smallest-class agent at high effort follows it.

`memory.md` holds what the built-in compaction summary loses: the user's rulings in force, what is ruled out and why, what was superseded, what is still intended, and the last 24 hours of what happened and why. *The read-through notes* are your own scratch file (`memory-notes.txt`), named in the brief.
## 1. Read the input in chunks

The input is entries `[<log timestamp> ROLE] text`, oldest first: USER is the user (the project owner), ASSISTANT the main session. Its last line is `[<log timestamp> END]`.

Read it with the Read tool, 200 lines at a time (`offset`, `limit`; halve `limit` if Read says the chunk is too large). After each chunk, before reading the next, append to the read-through notes:

```
read-through: <the timestamp of the last entry header in this chunk>
- <section>: <item>
```

Each item names its date and time and, when the user said it, quotes the user's words. A chunk with nothing worth keeping gets only its `read-through` line. Read every line; don't skim or sample.

## 2. Classify each item

- **Rulings in force:** how the user wants the work done, and decisions the user made. `- **No cron** (2026-10-12 09:14Z). Recurring work runs in the watcher: "never use cron".`
- **Ruled out:** an approach, tool or path rejected or failed, and why. `- **Codex for implementation** (2026-10-11 18:02Z). Codex only reviews; its patches needed rewriting.`
- **Superseded:** `old → new`, and why it changed, naming the old plan so nobody resumes it. `- **Day files → one memory.md** (2026-10-12 21:00Z). Day files duplicated the compaction summary.`
- **Still intended:** what is meant to happen and hasn't, and what it waits on. `- **Release the RSC extension** (2026-10-12 15:30Z). Waits on the upstream fix being published.`
- **Recent:** what happened and why. `- 2026-10-12 16:40Z: the review found the stream closing early; the fix moved to the server.`

Leave out commit SHAs, branch heads and PR states except to say what was superseded (git and GitHub record those), the task in flight (the compaction summary keeps it), and step-by-step narration. Take facts only from the input; mark an ambiguous item as such.

## 3. Merge the notes into memory.md

When the input is read, read `memory.md` if it exists, then the notes, and write `memory.md` in exactly this shape:

```
# Memory
## Standing
### Rulings in force
### Ruled out
### Superseded
### Still intended
## Recent
<!-- covered-until: <log timestamp> -->
```

- Standing items are one line each, newest first: `- **<lead>** (<date time>). <one sentence>.`, ending with the user's words quoted or a link when there is one.
- Carry every existing Standing item forward unless a new item replaces it. A replaced ruling or plan leaves its section; a replaced plan goes under Superseded. Done intended work leaves Still intended. Age alone never drops an item.
- Recent keeps only the 24 hours up to covered-until, one line per item.
- covered-until is the last `read-through` in the notes, copied exactly. If you stop before the `END` line, write `memory.md` the same way with that value: the file is then honestly behind, and the next run continues from it. `memory.md` never counts as covered past the notes.
