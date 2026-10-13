Notes: {{notes_path}}
Pin: {{head}}
Thread record: {{thread_record}}

Goal: before we take a position on {{author}}'s design point {{comment_url}}, the strongest case against our current position and the simplest design that still meets every requirement in the thread, written to {{debate_path}}.

Facts:
- Write the thread's full record first: `mw thread {{thread_url}} > {{thread_record}}`; it must contain comment {{comment_id}}.
- Read code only at the pinned commit.
- Options already ruled out on this thread, with the reason (argue against one only with new evidence):
{{memory}}

To check: which requirement does each candidate fail, shown as code? What would the maintainer have to give up under each?

Scope: read-only; write only {{debate_path}} and {{thread_record}}. Kill only PIDs you start. No agents of your own.

Acceptance: {{debate_path}} ends with one line `SIMPLER: <the simplest design that holds>` or `SIMPLER: none, because <requirement>`; final message at most 10 lines.
