#!/usr/bin/env python3
"""The steward, declared in ~/.mergeworthy/steward as `<watch dir> <T3 thread id>`: the session that sorts follow-ups and owns
the mergeworthy repo. Without the file there is none, and each main session keeps both."""
import os, sqlite3, time

def read():
    """(watch dir, T3 thread id), or None."""
    try: wd, tid = open(os.path.expanduser('~/.mergeworthy/steward')).read().split()[:2]
    except (OSError, ValueError): return None
    return os.path.expanduser(wd).rstrip('/'), tid

def passed_by(wd):
    """The session whose watcher round in wd passed in the last day (gh-watch-start --round writes <wd>/passed), or None."""
    try:
        p = os.path.join(wd, 'passed')
        return open(p).read().split()[0] if time.time() - os.path.getmtime(p) < 86400 else None
    except (OSError, IndexError):
        return None

# The statuses T3 Code counts as active: a run's (its orchestration_v2_projection_runs_recovery_idx) and a delegated task's (its binary's widest set)
ACTIVE_RUNS = ('queued', 'preparing', 'starting', 'running', 'waiting')
ACTIVE_TASKS = ('pending', 'starting', 'running', 'waiting')

def _thread(session_id):
    """(read-only connection to T3 Code's state, the T3 thread a Claude session runs in), or None."""
    try:
        c = sqlite3.connect(f"file:{os.path.expanduser('~/.t3/userdata/statev2.sqlite')}?mode=ro", uri=True, timeout=2)
        r = c.execute("select thread_id from orchestration_v2_projection_provider_threads where json_extract(payload_json, '$.nativeThreadRef.nativeId') = ?",
                      (session_id,)).fetchone()
        return (c, r[0]) if r else None
    except sqlite3.Error:
        return None

def _in(values):
    return f"({','.join('?' * len(values))})"

def threads(session_id):
    """The T3 thread a Claude session runs in, then the threads that delegated it, read from T3 Code's state."""
    t, out = _thread(session_id), []
    if not t: return out
    c, tid = t
    try:
        while tid and tid not in out and len(out) < 8:
            out.append(tid)
            r = c.execute('select thread_id from orchestration_v2_projection_subagents where child_thread_id = ?', (tid,)).fetchone()
            tid = r and r[0]
    except sqlite3.Error:
        pass
    return out

def _busy(c, tid):
    return bool(c.execute(f"select 1 from orchestration_v2_projection_runs where thread_id = ? and status in {_in(ACTIVE_RUNS)}", (tid, *ACTIVE_RUNS)).fetchone()
                or c.execute(f"select 1 from orchestration_v2_projection_subagents where thread_id = ? and status in {_in(ACTIVE_TASKS)}", (tid, *ACTIVE_TASKS)).fetchone())

def busy(session_id):
    """True when the Claude session's T3 thread has an active run, or a task it delegated still active: T3 will act on it again."""
    t = _thread(session_id)
    try: return bool(t) and _busy(*t)
    except sqlite3.Error: return False

def task_done(session_id):
    """True when the Claude session is a T3 delegated task that completed and isn't busy: T3 won't wake it again."""
    t = _thread(session_id)
    if not t: return False
    c, tid = t
    try:
        return c.execute("select status from orchestration_v2_projection_subagents where child_thread_id = ?", (tid,)).fetchone() == ('completed',) \
            and not _busy(c, tid)
    except sqlite3.Error:
        return False

def is_task(session_id):
    """True when the Claude session is a T3 delegated task (a child agent), not a main session."""
    t = _thread(session_id)
    if not t: return False
    c, tid = t
    try: return bool(c.execute("select 1 from orchestration_v2_projection_subagents where child_thread_id = ?", (tid,)).fetchone())
    except sqlite3.Error: return False

def first(path):
    try: return open(path).read().split()[0]
    except (OSError, IndexError): return ''

def is_steward(session_id, cwd):
    """True for the steward's session and the agents it delegated: by its T3 thread, a cwd in its watch dir, or, without
    T3's database, the session gh-watch-start recorded in its watch dir."""
    s = read()
    return bool(s) and (((cwd or '').rstrip('/') + '/').startswith(s[0] + '/') or bool(session_id) and
                        (first(os.path.join(s[0], 'session')) == session_id or s[1] in threads(session_id)))

def recipient(dirs):
    """Where a follow-up goes: the steward's watch dir while its watcher runs (someone reads it), else dirs."""
    s = read()
    try: os.kill(int(first(os.path.join(s[0], 'gh-watch.pid'))), 0)
    except (TypeError, ValueError, OSError): return dirs
    return [s[0]]
