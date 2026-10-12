Goal: <MEMORY> holds what the built-in compaction summary loses: the user's rulings in force, what is ruled out and why, what was superseded, what is still intended, and the last 24 hours of what happened and why. Merge the new log lines in <NEW> into it. Work in the foreground; end your turn only with your result; no subagents; read and write only <NEW> and <MEMORY>.

Input: <NEW>, the orchestrator's session-log lines since <MEMORY> was last merged; entries `[YYYY-MM-DD HH:MMZ ROLE] text`. USER is the user (the project owner), ASSISTANT the orchestrator, TOOL lines git, gh and agent commands. Read all of it, in chunks; don't skim. Then read <MEMORY> if it exists.

Write <MEMORY> in exactly this shape (create it if missing):

# Memory
## Standing
### Rulings in force
### Ruled out
### Superseded
### Still intended
## Recent
<!-- covered-until: <UNTIL> -->

- Standing items are one line each, newest first: `- **<lead>** (<date time>). <one sentence>.`, ending with the user's words quoted or a link when there is one.
    - Rulings in force: how the user wants the work done, and decisions the user made.
    - Ruled out: an approach, tool or path rejected or failed, and why.
    - Superseded: `old → new`, with why it changed. Name the old plan so nobody resumes it.
    - Still intended: what is meant to happen and hasn't, and what it waits on.
- Carry every existing Standing item forward unless a new line replaces it. When a ruling or plan replaces an item, remove that item (a replaced plan goes under Superseded); when intended work is done, remove it. Never drop an item only because it is old.
- Recent: what happened and why, one line per item with its date and time, only the 24 hours up to <NOW>. Drop older items.
- Leave out commit SHAs, branch heads and PR states except to say what was superseded (git and GitHub record those), the task in flight (the built-in summary keeps it), and step-by-step narration. Facts only from the lines; mark an ambiguous item as such.
- End the file with the `<!-- covered-until: <UNTIL> -->` line, replacing any earlier one.

Final message: one line, the path.
