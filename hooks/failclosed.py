"""Imported first by every hook: an exception a hook doesn't handle blocks (exit 2, the traceback on stderr). Claude Code lets an
action through on any other exit code, so a check that crashed would pass everything it was there to stop. A block (exit 2) is
recorded in the block log (blocklog.py) by the line that wrote its message."""
import os, sys
import blocklog


def _blocked(kind, value, tb):
    import traceback  # here, not at import: it costs every hook call ~14 ms
    name = os.path.basename(sys.argv[0])
    sys.stderr.write(f"BLOCKED by {name}: the check itself failed, so it can't tell whether this is allowed. Retry once; if it fails "
                     "again, tell the user, with this error, and do other work meanwhile:\n"
                     + ''.join(traceback.format_exception(kind, value, tb))[-1500:])
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _blocked


class _Stderr:
    """sys.stderr, noting the line that writes first: the check whose message it is (a `block()` helper writes for its caller)."""
    def __init__(self, out):
        self.out, self.at = out, None

    def write(self, s):
        if self.at is None:
            f = sys._getframe(1)
            while f.f_code.co_name == 'block' and f.f_back:
                f = f.f_back
            self.at = f.f_code.co_filename, f.f_lineno
        return self.out.write(s)

    def __getattr__(self, k):
        return getattr(self.out, k)


_stderr, _sys_exit = _Stderr(sys.stderr), sys.exit


def _exit(code=None):
    if code == 2 and _stderr.at:
        import linecache
        path, lineno = _stderr.at
        blocklog.record(os.path.basename(path), blocklog.name(linecache.getlines(path), lineno))
    _sys_exit(code)


sys.stderr, sys.exit = _stderr, _exit
