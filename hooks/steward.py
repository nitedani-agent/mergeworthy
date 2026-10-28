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

def threads(session_id):
    """The T3 thread a Claude session runs in, then the threads that delegated it, read from T3 Code's state."""
    out = []
    try:
        c = sqlite3.connect(f"file:{os.path.expanduser('~/.t3/userdata/statev2.sqlite')}?mode=ro", uri=True, timeout=2)
        r = c.execute("select thread_id from orchestration_v2_projection_provider_threads where json_extract(payload_json, '$.nativeThreadRef.nativeId') = ?",
                      (session_id,)).fetchone()
        while r and r[0] not in out and len(out) < 8:
            out.append(r[0])
            r = c.execute('select thread_id from orchestration_v2_projection_subagents where child_thread_id = ?', (r[0],)).fetchone()
    except sqlite3.Error:
        pass
    return out

def task_done(session_id):
    """True when the Claude session is a T3 delegated task that completed, with no run of its thread queued or running and no
    task it delegated still running: T3 won't wake it again."""
    try:
        c = sqlite3.connect(f"file:{os.path.expanduser('~/.t3/userdata/statev2.sqlite')}?mode=ro", uri=True, timeout=2)
        r = c.execute("select thread_id from orchestration_v2_projection_provider_threads where json_extract(payload_json, '$.nativeThreadRef.nativeId') = ?",
                      (session_id,)).fetchone()
        return bool(r) and c.execute("select status from orchestration_v2_projection_subagents where child_thread_id = ?", r).fetchone() == ('completed',) \
            and not c.execute("select 1 from orchestration_v2_projection_runs where thread_id = ? and status in ('queued', 'running')", r).fetchone() \
            and not c.execute("select 1 from orchestration_v2_projection_subagents where thread_id = ? and status = 'running'", r).fetchone()
    except sqlite3.Error:
        return False

def is_task(session_id):
    """True when the Claude session is a T3 delegated task (a child agent), not a main session."""
    try:
        c = sqlite3.connect(f"file:{os.path.expanduser('~/.t3/userdata/statev2.sqlite')}?mode=ro", uri=True, timeout=2)
        r = c.execute("select thread_id from orchestration_v2_projection_provider_threads where json_extract(payload_json, '$.nativeThreadRef.nativeId') = ?",
                      (session_id,)).fetchone()
        return bool(r) and bool(c.execute("select 1 from orchestration_v2_projection_subagents where child_thread_id = ?", r).fetchone())
    except sqlite3.Error:
        return False

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
