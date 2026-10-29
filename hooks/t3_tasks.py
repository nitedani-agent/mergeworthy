#!/usr/bin/env python3
"""T3 Code's delegated tasks as a session's transcript reports them: its tool calls and results (delegate_task, task_status,
t3_thread_send) and T3's notices. A thread is all its tasks: the first, each message sent to it, each turn T3 continues on its
own (provider-continuation)."""
import json, re


def observed(lines):
    """(status, thread, seen, launched): each task's (status, title), in the order last heard of; the name of its thread; the tasks
    heard of since the user's last message; whether the session launched or messaged one (a read with task_status alone doesn't)."""
    titles, status, launched, seen, thread = {}, {}, False, set(), {}
    for line in lines:
        try: e = json.loads(line)
        except ValueError: continue
        c = (e.get('message') or {}).get('content') if isinstance(e, dict) else None
        if e.get('type') == 'user' and isinstance(c, str) and not c.startswith('<'):
            # T3's own completion notice and a skill's re-invocation aren't the user: a notice marks its task terminal instead
            # T3's notice is `Delegated task <id> reached a terminal state`, or `Delegated task <id> (<title>) [<status>]:` with its result
            n = re.match(r'Delegated task (\S+) (?:reached a terminal state|\(.*?\) \[(\w+)\]:?)', c)
            # a sub-agent whose turn ends while its own background work runs says so, and T3 continues it later: not finished
            waits = n and re.search(r"\b(?:still running|I'll (?:continue|wait|resume)|I will (?:continue|wait|resume)|I'm waiting|wakes? (?:me )?when)\b", c[n.end():n.end() + 400], re.I)
            if n: status[n.group(1)] = ('waiting' if waits else n.group(2) or 'completed', status.pop(n.group(1), ('', ''))[1])
            elif not c.startswith(('Skill /', 'Stop hook feedback')): seen = set()
        for b in c if isinstance(c, list) else []:
            if b.get('type') == 'tool_use' and re.search(r'(delegate_task|task_status|thread_send)$', b.get('name', '')):
                titles[b['id']] = (b.get('name', '').endswith('task_status'), str((b.get('input') or {}).get('title') or ''))
                launched = launched or not titles[b['id']][0]
            elif b.get('type') == 'tool_result' and b.get('tool_use_id') in titles:
                r = b.get('content'); r = ''.join(x.get('text', '') for x in r) if isinstance(r, list) else str(r or '')
                try: r = json.loads(r)
                except ValueError: continue
                if isinstance(r, dict) and r.get('threadId') and not r.get('taskId'):  # a message sent to a task's thread runs it again
                    r = {'taskId': r['threadId'] + '#sent', 'childThreadId': r['threadId'], 'status': r.get('status') or 'running'}
                if isinstance(r, dict) and r.get('taskId'):
                    is_read, title = titles[b['tool_use_id']]
                    old = status.pop(r['taskId'], ('', ''))
                    status[r['taskId']] = (str(r.get('status') or ''), title or old[1])
                    thread[r['taskId']] = str(r.get('childThreadId') or r.get('threadId') or thread.get(r['taskId']) or r['taskId'])  # a follow-up message is a new task of its thread
                    seen.add(r['taskId'])
    def name_of(i):
        m = re.search(r'%25253A([^%]+)%3Aordinal', i)  # a continuation's id holds its thread's, encoded twice
        return (m[1] if m else thread.get(i, i).rsplit('%3A', 1)[-1]).lower()
    return status, {i: name_of(i) for i in status}, seen, launched
