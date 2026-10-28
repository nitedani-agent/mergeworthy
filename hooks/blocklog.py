"""The block log, ~/.mergeworthy/hooks-fired.log: `<UTC day> <hook> <check>` the first time on that day a check blocks, the check
being the source line that wrote its message. failclosed records it; `steward fired` reads it against each hook's `checks`."""
import fcntl, os, time

LOG = os.path.expanduser('~/.mergeworthy/hooks-fired.log')


def name(lines, lineno):
    """The check at line `lineno` of a hook's source: that line stripped, `#<n>` when it is the nth line with that text."""
    lines = [l.strip() for l in lines]
    n = lines[:lineno - 1].count(lines[lineno - 1])
    return lines[lineno - 1] + (f' #{n + 1}' if n else '')


def record(hook, check):
    line = f"{time.strftime('%Y-%m-%d', time.gmtime())} {hook} {check}\n"
    try:
        with open(LOG, 'a+') as f:
            fcntl.flock(f, fcntl.LOCK_EX)  # two sessions blocking at once still write the day's line once
            f.seek(0)
            if line not in f:
                f.write(line)
    except OSError:
        pass  # no ~/.mergeworthy: the block goes unlogged, its message and exit code unchanged


def checks(path):
    """{check: line number} for each place the hook at `path` writes a message to stderr; a `block()` helper writes for its callers."""
    import ast
    src = open(path).read()
    lines, out = src.splitlines(), {}
    def walk(node, fn):
        for c in ast.iter_child_nodes(node):
            if isinstance(c, ast.Call):
                f = ast.unparse(c.func)
                writes = f == 'sys.stderr.write' or f == 'print' and any(k.arg == 'file' and ast.unparse(k.value) == 'sys.stderr' for k in c.keywords)
                if f == 'block' or writes and fn != 'block':
                    out[name(lines, c.lineno)] = c.lineno
            walk(c, c.name if isinstance(c, (ast.FunctionDef, ast.AsyncFunctionDef)) else fn)
    walk(ast.parse(src), None)
    return out
