#!/usr/bin/env python3
"""The memory file (core 1.2): <artifact root>/memory.md fills what the built-in compaction summary loses. Its Standing part
(rulings in force, ruled out, superseded, still intended) is carried forward until replaced; its Recent part covers the
last 24 hours. One Haiku merges new log lines into it (`memory-prep`), and it records the last log line it covered in
`<!-- covered-until: <log timestamp> -->`. A root is listed in ~/.mergeworthy/memory-roots.txt and has memory.source
(`memory-prep init`): the orchestrator's cwd, T3 thread id and session-log dir."""
import json, os, re, time

COVERED = re.compile(r'<!-- covered-until: (\S+) -->')
TS = re.compile(rb'"timestamp":"([0-9T:.\-]+Z)"')
STANDING = ('Rulings in force', 'Ruled out', 'Superseded', 'Still intended')
AIM, CAP = 8000, 16000  # digest characters: about 2k tokens, hard cap about 4k
REG = os.path.expanduser('~/.mergeworthy/memory-roots.txt')

def roots():
    dirs = [l.strip() for l in open(REG)] if os.path.exists(REG) else []
    return [r for r in dict.fromkeys(dirs) if r and os.path.isfile(os.path.join(r, 'memory.source'))]

def source(root):
    return json.load(open(os.path.join(root, 'memory.source')))

def for_cwd(cwd):
    """The root whose orchestrator works in cwd."""
    return next((r for r in roots() if cwd and (cwd == source(r)['cwd'] or cwd.startswith(source(r)['cwd'].rstrip('/') + '/'))), None)

def path(root):
    return os.path.join(root, 'memory.md')

def covered(root):
    m = COVERED.findall(open(path(root), errors='replace').read()) if os.path.isfile(path(root)) else []
    return m[-1] if m else ''

def thread_logs(root, since=0.0):
    """The orchestrator's session logs modified since `since`: files of its log dir that name its thread. Each file's
    checked size is cached, so a log is read once and a growing one only from where it was checked."""
    src = source(root); cache_f = os.path.join(root, '.memory-logs.json')
    cache = json.load(open(cache_f)) if os.path.exists(cache_f) else {}
    out, tid = [], src['thread'].encode()
    for f in os.listdir(src['logdir']):
        p = os.path.join(src['logdir'], f)
        if not f.endswith('.jsonl') or os.path.getmtime(p) < since:
            continue
        size, hit = cache.get(p, (0, False))
        if not hit and os.path.getsize(p) > size:
            with open(p, 'rb') as fh:
                fh.seek(max(0, size - len(tid))); hit = tid in fh.read()
            cache[p] = (os.path.getsize(p), hit)
        if hit:
            out.append(p)
    json.dump(cache, open(cache_f, 'w'))
    return out

def last_ts(p):
    """A log's latest timestamp, read from its end."""
    with open(p, 'rb') as f:
        f.seek(0, 2); end = f.tell(); n = 1 << 16
        while True:
            f.seek(max(0, end - n)); found = TS.findall(f.read())
            if found or n >= end: return found[-1].decode() if found else ''
            n *= 4

def behind(root):
    """True when the orchestrator's log has lines after what memory.md covers."""
    cov = covered(root)
    since = os.path.getmtime(path(root)) - 60 if cov else time.time() - 86400  # the first run covers the last 24 hours
    return any(last_ts(p) > cov for p in thread_logs(root, since))

def section(text, heading):
    m = re.search(r'^#+ *' + re.escape(heading) + r'[^\n]*\n(.*?)(?=^#+ |\Z)', text, re.M | re.S | re.I)
    return m.group(1).strip() if m else ''

def digest(root):
    """The Standing part, cut to the cap: one line per item, newest first, deduplicated by its lead. No model call."""
    text = open(path(root), errors='replace').read() if os.path.isfile(path(root)) else ''
    out, per = [], AIM // len(STANDING)
    for head in STANDING:
        seen, body = set(), ''
        for l in section(text, head).splitlines():
            l = l.strip()
            if not re.match(r'[-*] ', l):
                continue
            lead = re.sub(r'\W+', ' ', (re.match(r'[-*] \*\*(.+?)\*\*', l) or re.match(r'[-*] (.{0,60})', l)).group(1)).strip().lower()
            if lead in seen:
                continue
            seen.add(lead); l = l if len(l) <= 240 else l[:237] + '...'
            if len(body) + len(l) > per:
                body += f'- ... more in {path(root)}\n'; break
            body += l + '\n'
        out.append(f'### {head}\n' + (body or 'none\n'))
    return '\n'.join(out)[:CAP]

def notes(root):
    """What the guards grep: memory.md and every other .md under the root but drafts and briefs."""
    return sorted(os.path.join(dp, f) for dp, dn, fs in os.walk(root) if os.path.relpath(dp, root).split(os.sep)[0] != 'drafts'
                  for f in fs if f.endswith('.md') and not f.startswith('memory-brief'))
