#!/usr/bin/env python3
"""The jobs pre-agent-dedupe registered (~/.claude/agent-jobs, one JSON file each: key, started, and the brief, the launcher's
session and transcript) and whether each one's agent has finished. T3's notices miss a run that ended interrupted or failed
and was revived, or that wrote its report without a final message, so the agent's own transcript decides: the one under
~/.claude/projects whose first prompt carries the brief (or, for a job an older hook registered with only its key and start,
every ticket path in the key). It has finished when that transcript has been quiet for QUIET
seconds with no tool call pending, or for LONG seconds whatever it was doing (no foreground tool call runs ten minutes)."""
import glob, json, os, re, time

JOBS = os.path.expanduser('~/.claude/agent-jobs')
REPORTED = os.path.expanduser('~/.claude/agent-jobs-reported')  # <job file>-<transcript mtime>: reported once per finish
LAUNCH = re.compile(rb'"name": ?"(Agent|Task|mcp__[^"]*(delegate_task|t3_thread_launch))"')  # pre-agent-dedupe's matcher
QUIET, LONG, OPEN = 180, 660, 24 * 3600  # OPEN: pre-agent-dedupe's window, after which a job no longer counts

def jobs(now=None):
    """(file name, job) for each open job: registered in the last day and not released."""
    now, out = now or time.time(), []
    for f in sorted(os.listdir(JOBS)) if os.path.isdir(JOBS) else ():
        try: j = json.load(open(os.path.join(JOBS, f)))
        except (OSError, ValueError): continue
        if isinstance(j, dict) and j.get('key') and now - j.get('started', 0) < OPEN:
            out.append((f, j))
    return out

_first = {}
def first_prompt(path):
    """A transcript's first prompt (it never changes, so each file is read once)."""
    if path not in _first:
        _first[path] = ''
        with open(path, errors='replace') as fh:
            for i, line in zip(range(50), fh):
                try: o = json.loads(line)
                except ValueError: continue
                if isinstance(o, dict) and o.get('type') == 'user' and not o.get('isMeta'):
                    c = (o.get('message') or {}).get('content')
                    t = c if isinstance(c, str) else ' '.join(b.get('text', '') for b in c or [] if isinstance(b, dict) and b.get('type') == 'text')
                    if t.strip():
                        _first[path] = t
                        break
    return _first[path]

def needles(job):
    """What the agent's first prompt carries: the brief, else the ticket paths the key lists (a title-only key has none)."""
    return [job['brief'].strip()[:500]] if job.get('brief') else [w for w in job['key'].split() if w.startswith('/')]

_hit = {}
def transcript(job):
    """The agent's transcript: written since the launch, its first prompt carrying the needles; None until it starts."""
    ns = needles(job); k = (tuple(ns), job['started'])
    if not ns: return None
    if os.path.exists(_hit.get(k) or '/nonexistent'):
        return _hit[k]
    root = os.path.expanduser('~/.claude/projects')
    for p in glob.glob(f'{root}/*/*.jsonl') + glob.glob(f'{root}/*/*/subagents/*.jsonl'):
        try:
            if os.path.getmtime(p) >= job['started'] - 60 and p != job.get('transcript') and all(n in first_prompt(p) for n in ns):
                _hit[k] = p
                return p
        except OSError: pass

def launchers(items):
    """{file name: launcher transcript} for (file name, job, agent transcript) items whose job recorded no launcher: the
    session transcript written since the launch, not the agent's, with a launch call naming every needle (a transcript
    that only lists the job doesn't count). Each transcript is read once."""
    out, todo = {}, [(f, j, c, [n.encode() for n in needles(j)]) for f, j, c in items if needles(j)]
    for p in glob.glob(os.path.expanduser('~/.claude/projects/*/*.jsonl')) if todo else ():
        try:
            m = os.path.getmtime(p)
            want = [t for t in todo if t[0] not in out and m >= t[1]['started'] - 60 and p != t[2]]
            calls = [l for l in open(p, 'rb') if b'"tool_use"' in l and LAUNCH.search(l)] if want else []
        except OSError: continue
        for f, j, c, ns in want:
            if any(all(n in l for n in ns) for l in calls): out[f] = p
    return out

def pending(path):
    """The transcript's last turn is a tool call still running (or cut off by a crash: LONG covers that)."""
    with open(path, 'rb') as fh:
        fh.seek(max(0, os.path.getsize(path) - 65536))
        for line in reversed(fh.read().splitlines()):
            try: o = json.loads(line)
            except ValueError: continue
            if isinstance(o, dict) and o.get('type') in ('user', 'assistant'):
                c = (o.get('message') or {}).get('content')
                return o['type'] == 'assistant' and any(isinstance(b, dict) and b.get('type') == 'tool_use' for b in c or [] if not isinstance(c, str))
    return False

def finished(job, now=None):
    """(transcript, its mtime) when the job's agent has finished, else None."""
    p = transcript(job)
    if not p: return None
    m = os.path.getmtime(p); quiet = (now or time.time()) - m
    return (p, m) if quiet >= LONG or (quiet >= QUIET and not pending(p)) else None

def reported(f, mtime):
    return os.path.exists(os.path.join(REPORTED, f'{f}-{int(mtime)}'))

def claim(f, mtime):
    """True once per job and finish: the first caller reports it."""
    os.makedirs(REPORTED, exist_ok=True)
    try: os.close(os.open(os.path.join(REPORTED, f'{f}-{int(mtime)}'), os.O_CREAT | os.O_EXCL)); return True
    except FileExistsError: return False
