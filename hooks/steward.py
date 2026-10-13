#!/usr/bin/env python3
"""The steward, declared in ~/.mergeworthy/steward as `<watch dir> <T3 thread id>`: the session that sorts follow-ups and owns
the mergeworthy repo. Without the file there is none, and each orchestrator keeps both."""
import os, sqlite3

def read():
    """(watch dir, T3 thread id), or None."""
    try: wd, tid = open(os.path.expanduser('~/.mergeworthy/steward')).read().split()[:2]
    except (OSError, ValueError): return None
    return os.path.expanduser(wd).rstrip('/'), tid

def threads(session_id):
    """The T3 thread a Claude session runs in, then the threads that delegated it, read from T3 Code's state."""
    out = []
    try:
        c = sqlite3.connect(f"file:{os.path.expanduser('~/.t3/userdata/statev2.sqlite')}?mode=ro", uri=True, timeout=2)
        r = c.execute('select thread_id from orchestration_v2_projection_provider_threads where instr(payload_json, ?) > 0',
                      (f'"nativeId":"{session_id}"',)).fetchone()
        while r and r[0] not in out and len(out) < 8:
            out.append(r[0])
            r = c.execute('select thread_id from orchestration_v2_projection_subagents where child_thread_id = ?', (r[0],)).fetchone()
    except sqlite3.Error:
        pass
    return out

def is_steward(session_id, cwd):
    """True for the steward's session and the agents it delegated: by its T3 thread, or a cwd in its watch dir."""
    s = read()
    return bool(s) and (((cwd or '').rstrip('/') + '/').startswith(s[0] + '/') or bool(session_id) and s[1] in threads(session_id))
