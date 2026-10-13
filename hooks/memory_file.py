#!/usr/bin/env python3
"""The memory file (mergeworthy:task step 8): <work folder>/memory.md fills what the built-in compaction summary loses. Its Standing part
(rulings in force, ruled out, superseded, still intended) is carried forward until replaced; its Recent part covers the
last 24 hours. One Haiku merges new log lines into it (`memory-prep`), and it records the last log line it covered in
`<!-- covered-until: <log timestamp> -->`. A root is listed in ~/.mergeworthy/memory-roots.txt and has memory.source
(`memory-prep init`): the main session's cwd, T3 thread id, session id and session-log dir."""
import json, os, re, time

COVERED = re.compile(r'<!-- covered-until: (\S+) -->')
READ = re.compile(r'read-through: (\S+)')
TS = re.compile(rb'"timestamp":"([0-9T:.\-]+Z)"')
STANDING = ('Rulings in force', 'Ruled out', 'Superseded', 'Still intended')
AIM, CAP = 6000, 7500  # digest characters: with the refresh order, under Claude Code's 10,000-character hook output limit
REG = os.path.expanduser('~/.mergeworthy/memory-roots.txt')

def roots():
    dirs = [l.strip() for l in open(REG)] if os.path.exists(REG) else []
    return [r for r in dict.fromkeys(dirs) if r and os.path.isfile(os.path.join(r, 'memory.source'))]

def source(root):
    return json.load(open(os.path.join(root, 'memory.source')))

def for_cwd(cwd):
    """The work folder whose main session works in cwd."""
    return next((r for r in roots() if cwd and (cwd == source(r)['cwd'] or cwd.startswith(source(r)['cwd'].rstrip('/') + '/'))), None)

def path(root):
    return os.path.join(root, 'memory.md')

def notes_path(root):
    return os.path.join(root, 'memory-notes.txt')

def covered(root):
    """What memory.md covers: its covered-until, never past the last chunk its run noted as read (delegate/memory-refresh.md)."""
    m = COVERED.findall(open(path(root), errors='replace').read()) if os.path.isfile(path(root)) else []
    n = READ.findall(open(notes_path(root), errors='replace').read()) if os.path.isfile(notes_path(root)) else []
    return min(m[-1], n[-1]) if m and n else (m[-1] if m else '')

def prompt(o):
    """A user turn's prompt as the log records it: typed by the user or sent through the SDK (T3 Code), never a skill body,
    hook feedback, task notification or the built-in compaction summary."""
    return (o.get('type') == 'user' and o.get('promptSource') in ('typed', 'sdk') and not o.get('isMeta')
            and not o.get('isCompactSummary'))

def texts(o):
    c = (o.get('message') or {}).get('content')
    return [c] if isinstance(c, str) else [b.get('text', '') for b in c or [] if b.get('type') == 'text']

def orchestrator(line, tid):
    """A log line that marks a later session of the orchestrator: a prompt naming its thread (T3 Code's context handoff).
    A child session's log names the thread only in tool output."""
    if tid not in line:
        return False
    try: o = json.loads(line)
    except ValueError: return False
    return prompt(o) and any(tid in t for t in texts(o))

def thread_logs(root, since=0.0):
    """The orchestrator's session logs modified since `since`: the session init ran in, and later ones its thread was handed
    to. Each file's checked position is cached, so a log is read once and a growing one only from where it was checked."""
    src = source(root); cache_f = os.path.join(root, '.memory-orchestrator-logs.json')
    cache = json.load(open(cache_f)) if os.path.exists(cache_f) else {}
    out, tid = [], src['thread']
    for f in os.listdir(src['logdir']):
        p = os.path.join(src['logdir'], f)
        if not f.endswith('.jsonl') or os.path.getmtime(p) < since:
            continue
        pos, hit = cache.get(p, (0, f[:-len('.jsonl')] in src.get('sessions', ())))
        if not hit and os.path.getsize(p) > pos:
            with open(p, 'rb') as fh:
                fh.seek(pos)
                for l in fh:
                    if not l.endswith(b'\n'):
                        break
                    pos += len(l)
                    if orchestrator(l.decode(errors='replace'), tid):
                        hit = True; break
            cache[p] = (pos, hit)
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

def order(root, live=False):
    """The order to refresh memory.md: at session start it waits, since the context was just summarized; repeated by stop-lint
    in a live session, whose context is whole, it runs beside the work."""
    wait = ("wait for its completion without starting other work and without reading its report; then run "
            f"`memory-prep digest {root}`, read it, and resume.")
    side = (f"keep working meanwhile (your context is intact), without reading its report; when it completes, run "
            f"`memory-prep digest {root}` and read it.")
    return (f"IMPORTANT: {path(root)} is behind your session log. If you are a delegated sub-agent, ignore this. "
            + ("" if live else "Before resuming: ")
            + f"run `memory-prep prep {root}`; start ONE Haiku at high effort (T3 Code: delegate_task, mode async) on the brief file it names; "
            + (side if live else wait))

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
