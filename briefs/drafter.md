Notes: {{notes_path}}
Pin: {{head}}
Thread record: {{thread_record}}
Voice: {{voice_path}}

Goal: a reply to {{author}}'s comment {{comment_url}} ({{kind}}), written to {{draft_path}}, that answers exactly what it asks.

Facts:
- The thread is {{thread}}. Write its full record first: `mw thread {{thread_url}} > {{thread_record}}`; the record must contain comment {{comment_id}}. Read all of it, not only the comment.
- Read the notes and the voice file before writing. Cite code only at the pinned commit, with a link.
- Results of earlier steps on this comment:
{{results}}
- What failed or was ruled out on this thread before (don't repeat it):
{{memory}}

To check: is anything in the thread newer than {{comment_id}} that changes the answer? Does the reply claim anything the pin doesn't show?

Scope: read-only on GitHub (no posting, no reactions); write only {{draft_path}} and {{thread_record}}. Kill only PIDs you start. No agents of your own.

Acceptance: `mw lint {{draft_path}} --kind reply` exits 0; the final message lists each claim with its source and a not_checked line, at most 10 lines.
