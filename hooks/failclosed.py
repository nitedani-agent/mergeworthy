"""Imported first by every hook: an exception a hook doesn't handle blocks (exit 2, the traceback on stderr). Claude Code lets an
action through on any other exit code, so a check that crashed would pass everything it was there to stop."""
import os, sys


def _blocked(kind, value, tb):
    import traceback  # here, not at import: it costs every hook call ~14 ms
    name = os.path.basename(sys.argv[0])
    sys.stderr.write(f"BLOCKED by {name}: the check itself failed, so it can't tell whether this is allowed. Retry once; if it fails "
                     "again, tell the user, with this error, and do other work meanwhile:\n"
                     + ''.join(traceback.format_exception(kind, value, tb))[-1500:])
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _blocked
