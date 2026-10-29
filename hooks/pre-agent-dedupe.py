#!/usr/bin/env python3
"""Claude Code PreToolUse hook (matcher: Agent, Task, delegate_task, t3_thread_launch). Exit 2 blocks the launch; stderr goes to the agent.
With the argument `register` it runs as the PostToolUse hook: only a launch that ran is registered, so one another hook blocked leaves no job.
One agent per job: a launch is registered under its job key (the ticket files its prompt names, and its title), and a second
launch of the same job is blocked until `agent-job done <key>` releases it. A turn that ended is not a finished agent: on T3 a
child wakes again when its background commands end, so only its terminal task status (read first) releases the job."""
import datetime, fcntl, glob, hashlib, json, os, re, shlex, sys, time
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import failclosed
import memory_file, steward, subprocess
register = sys.argv[1:] == ['register']
d = json.load(sys.stdin)
ti = d.get('tool_input', {}) or {}
# T3 opens no run for a turn Claude Code starts by itself (a finished background command, a Monitor event), and refuses
# launches from it (pingdotgg/t3code#16808): nothing ran, so no job, and the session keeps working instead of waiting
if register and 'parent_not_active' in json.dumps(d.get('tool_response') or ''):
    print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PostToolUse', 'additionalContext':
        "T3 refused this launch: a background event started this turn, and T3 opened no run for it, so it refuses agent "
        "launches and the user doesn't see this turn in the thread. The next user message, scheduled task or finished agent "
        "starts a run. Until then, do the step yourself wherever the main session may (gates, tests, probes, an implementer's "
        "edits, preparing the push or the body: delegate step 7); only an independent review and a post wait for a run. "
        "Keep the brief, launch it in the next run, and add no status line on each wake."}}))
    sys.exit(0)
# T3 answers a delegate_task whose clientRequestId it has seen with that earlier task's result, without running anything.
# Reuse is allowed only within 10 minutes (a retry of the same launch).
cid = str(ti.get('clientRequestId') or '')
if cid:
    ids = os.path.expanduser('~/.claude/agent-client-request-ids.json'); os.makedirs(os.path.dirname(ids), exist_ok=True)
    lock = open(ids + '.lock', 'a'); fcntl.flock(lock, fcntl.LOCK_EX)  # held until exit: launches register at once
    seen = json.load(open(ids)) if os.path.exists(ids) else {}
    if cid in seen and time.time() - seen[cid] > 600:
        sys.stderr.write(f"BLOCKED: clientRequestId '{cid}' was used before; T3 would return that earlier task's result instead of running this one. Use a new id (add the date or the head SHA).\n")
        sys.exit(2)
    if register:
        seen.setdefault(cid, time.time())
        with open(ids + '.tmp', 'w') as f: json.dump(seen, f)
        os.replace(ids + '.tmp', ids)
text = '\n'.join(str(ti.get(k) or '') for k in ('prompt', 'task', 'message', 'description', 'title', 'workspaceStrategy'))
# a ticket is the brief file the agent executes; a file under ~/.mergeworthy (project notes, an installed skill) is a reference
mw = os.path.abspath(os.path.expanduser('~/.mergeworthy')) + os.sep
MD = r'(?<![\w.~/-])(~?/[^\s`\'"]+\.md)\b'
tickets = sorted({t for t in (os.path.abspath(os.path.expanduser(m)) for m in re.findall(MD, text))
                  if not t.startswith(mw)})
# A gate review (names a review output `.out` and CLEAN) starts only on drafts that passed post-lint in their current form.
# Reference files (project notes, installed skills) are read by the agent, not part of its brief: their history SHAs pin nothing
gate_text = text + '\n' + '\n'.join(open(t).read() for t in tickets if os.path.isfile(t))
if not register and re.search(r'\.out\b', gate_text) and 'CLEAN' in gate_text:
    # The gate names a review's output after its draft (`<name>.review.out` for `<name>.md`): when it does, that draft is
    # the one reviewed, and the files beside it (thread record, brief, parent) are not drafts
    named = {re.sub(r'(\.review)?\.out$', '.md', o) for o in re.findall(r'(/[^\s`\'"()]*/drafts/[^\s`\'"()]+\.out)\b', gate_text)}
    named = {p for p in named if os.path.isfile(p)}
    for draft in sorted(named or set(re.findall(r'(/[^\s`\'"()]*/drafts/[^\s`\'"()]+\.md)\b', gate_text))):
        base = os.path.basename(draft)
        if not named and (base.endswith(('.parent.md', '.current.md', '.report.md')) or re.search(r'ticket|brief|prompt|research|context', base) or re.search(r'\.v\d+\.md$', base)) or not os.path.isfile(draft):
            continue
        try: ok = open(draft + '.lint.sha').read().strip() == hashlib.sha256(open(draft, 'rb').read()).hexdigest()
        except OSError: ok = False
        if not ok:
            sys.stderr.write(f"BLOCKED: {draft} has no passing post-lint for its current text: run post-lint first, then the review.\n")
            sys.exit(2)
# A review round's launch is named `<loop>-r<N>` (delegate §Review rounds), maybe followed by the date or head SHA the reuse block asks for.
# A review is a review launch, or a launch with no role whose brief ends as a review template does (`exactly CLEAN`, `exactly NO BUGS`)
name = cid or str(ti.get('description') or '')
rnd = re.search(r'-r(\d+)$', re.sub(r'(-\d{4}-\d{2}-\d{2}|-[0-9a-f]{7,40})+$', '', name))
# a brief the launch follows from the work folder counts here, though the tickets above skip all of ~/.mergeworthy
briefs = gate_text + '\n' + '\n'.join(open(t).read() for t in {os.path.abspath(os.path.expanduser(m)) for m in re.findall(MD, text)}
                               if t.startswith(mw + 'work' + os.sep) and os.path.isfile(t))
if not register and (ti.get('role') == 'review' or not ti.get('role') and re.search(r'\bexactly (CLEAN|NO BUGS)\b', briefs)) and not (rnd and int(rnd[1]) <= 3):
    sys.stderr.write((f"BLOCKED: review round {rnd[1]} ('{name}') is past the budget" if rnd else
                      f"BLOCKED: name this review launch `<loop>-r<N>` (T3's clientRequestId, the Agent tool's description; '{name}' names no round)")
                     + ": mergeworthy:delegate §Review rounds allows 3 rounds per loop, never renewed or raised; a rewrite is a new loop. "
                     "A finding still open at the budget's end goes to the user, both sides in 2-3 lines.\n")
    sys.exit(2)
# A template's slot left unfilled (`<the slice's risky edges>`) reaches the agent as a rule it never got. A slot in backticks is
# the agent's own output form, the paste-in rules (agent.md) carry slots of their own, and an HTML tag a brief quotes is no slot.
if not register:
    tdir = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), 'skills', 'delegate')
    pasted = {l.strip() for l in open(os.path.join(tdir, 'agent.md'))} if os.path.isfile(os.path.join(tdir, 'agent.md')) else set()
    # only the brief itself: the task text and the brief files it executes, not the input files it names (memory.md quotes `<sha>`)
    own = [t for t in tickets if re.search(r'brief|prompt|ticket', os.path.basename(t))] or tickets[:1]
    brief_text = text + '\n' + '\n'.join(open(t).read() for t in own if os.path.isfile(t))
    brief = '\n'.join(l for l in brief_text.splitlines() if l.strip() not in pasted)
    brief = re.sub(r'`[^`\n]*`', '', brief)  # a form the brief quotes in backticks (`PROMISED <thread>: …`) is a format, not a slot
    HTML = set('a b base body br code div em footer form h1 h2 h3 head header html i img input li link main meta nav ol p path pre script section span strong style svg table td template title tr ul'.split())
    unfilled = {}
    for t in sorted(glob.glob(os.path.join(tdir, '*.md'))):
        for line in '\n'.join(re.findall(r'^```[^\n]*\n(.*?)^```', open(t).read(), re.M | re.S)).splitlines():
            code = [m.span() for m in re.finditer(r'`[^`]*`', line)]
            for m in re.finditer(r'<([^<>\n]+)>', line):
                if m[1] not in HTML and m[0] in brief and not any(a <= m.start() and m.end() <= b for a, b in code):
                    unfilled.setdefault(m[0], []).append(os.path.basename(t))
    if unfilled:
        sys.stderr.write("BLOCKED: the brief still has a template's placeholder; fill it with the specifics (mergeworthy:delegate §Brief):\n"
                         + '\n'.join(f"{p} (delegate/{', delegate/'.join(dict.fromkeys(fs))})" for p, fs in sorted(unfilled.items())) + '\n')
        sys.exit(2)
path_set = lambda t: {os.path.expanduser(p.rstrip('/.,:')) for p in re.findall(r'(~?/[^\s`\'"()<>,;]+)', t)}
paths = path_set(gate_text)
# A brief names a worktree in its launch text or its brief file (a ticket it says to follow, or named so), not in a reference it names
# or an installed skill (~/.mergeworthy/current may link to a worktree of mergeworthy)
said = {os.path.abspath(os.path.expanduser(m)) for x in re.split(r'(?<=[.!?])\s+|\n', text)
        if re.search(r'\b(follow|execute|exactly|what it says)\b', x, re.I) for m in re.findall(MD, x)}
worktree_paths = {p for p in path_set(text + '\n' + '\n'.join(open(t).read() for t in tickets if os.path.isfile(t)
                                      and (t in said or re.search(r'brief|ticket|prompt', os.path.basename(t)))))
                  if not (os.path.abspath(p) + os.sep).startswith(mw + 'current' + os.sep)}
# A brief pinned to an older commit of a worktree it names (a linked one: the user's own checkouts are read at any
# commit) re-runs work on code that has moved on.
if not register:
    shas = set(re.findall(r'\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b', gate_text))
    git = lambda wt, *a: subprocess.run(['git', '-C', wt, *a], capture_output=True, text=True)
    for wt in sorted(worktree_paths if shas else ()):
        head = git(wt, 'rev-parse', 'HEAD').stdout.strip() if os.path.isfile(os.path.join(wt, '.git')) else ''
        if head and not any(head.startswith(x) for x in shas):
            old = [x for x in shas if git(wt, 'merge-base', '--is-ancestor', x, head).returncode == 0]
            if old:
                root = memory_file.for_cwd(d.get('cwd') or '')
                ruled = memory_file.section(open(memory_file.path(root)).read(), 'Ruled out') if root and os.path.isfile(memory_file.path(root)) else ''
                sys.stderr.write(f"BLOCKED: the brief pins {', '.join(sorted(old))} in {wt}, which has moved on to {head[:12]}. "
                                 "Pin the live head (and check the work isn't already done there)." + (f" Ruled out:\n{ruled}\n" if ruled else "\n"))
                sys.exit(2)
# A linked worktree the brief names (not the launcher's own) where another agent is still working: T3 can show that agent
# interrupted or cancelled while it runs. A process with its cwd there, or an agent transcript written in the last five
# minutes that names it, means it is alive. Only an agent's transcript counts (a main session, the steward's too, names paths
# it doesn't work in), not the launcher's own, nor that of a T3 task that completed and won't be woken again (a review round's last agent).
if not register:
    def linked(p):
        while p != '/':
            if os.path.exists(os.path.join(p, '.git')):
                return p if os.path.isfile(os.path.join(p, '.git')) else None
            p = os.path.dirname(p)
    own = linked(os.path.realpath(d.get('cwd') or '/'))
    wts = sorted({w for w in (linked(os.path.realpath(p)) for p in worktree_paths) if w and w != own})
    anc, p = set(), os.getpid()
    while wts and p > 1:
        anc.add(p)
        try: p = int(open(f'/proc/{p}/stat').read().rsplit(')', 1)[1].split()[1])
        except (OSError, IndexError, ValueError): break
    procs = []
    for e in os.listdir('/proc') if wts else ():
        try:
            if e.isdigit() and int(e) not in anc:
                procs.append((e, os.readlink(f'/proc/{e}/cwd'), open(f'/proc/{e}/comm').read().strip()))
        except OSError: pass
    me, now, logs = os.path.realpath(d.get('transcript_path') or '/'), time.time(), []
    for f in sorted(glob.glob(os.path.expanduser('~/.claude/projects/*/*.jsonl')) + glob.glob(os.path.expanduser('~/.claude/projects/*/*/subagents/*.jsonl'))) if wts else ():
        try:
            if os.path.realpath(f) != me and now - os.path.getmtime(f) < 300:
                logs.append((f, int(now - os.path.getmtime(f)), open(f, 'rb').read()))
        except OSError: pass
    busy = []
    for w in wts:
        pids = [f'{e} ({c})' for e, cwd, c in procs if cwd == w or cwd.startswith(w + '/')]
        named = [f'{f} (written {age}s ago)' for f, age, b in logs if re.search(re.escape(w.encode()) + rb'(?![\w.-])', b)  # the path itself, not a longer sibling
                 and ('/subagents/' in f or steward.is_task(os.path.basename(f)[:-len('.jsonl')]))  # an agent's, not a main session's
                 and not steward.task_done(os.path.basename(f)[:-len('.jsonl')])]
        if pids or named:
            busy.append(f"{w}: " + '; '.join((['processes with their cwd there: ' + ', '.join(pids)] if pids else []) + (['transcripts naming it: ' + ', '.join(named)] if named else [])))
    if busy:
        sys.stderr.write("BLOCKED: another agent is still working in a worktree this brief names (T3's interrupted or cancelled status doesn't mean it stopped):\n"
                         + '\n'.join(busy) + "\nContinue that agent with a message, or wait for it to finish; a replacement goes in a fresh worktree.\n")
        sys.exit(2)
# A brief that writes or reviews code, docs or a post (any role but research or test) for a repo whose maintainers' notes exist
# (delegate step 3) names the project file, so the agent reads them: by owner/repo, or by a path in that repo's checkout. A memory-refresh
# brief reads only the session log.
if not register and ti.get('role') not in ('research', 'test') and 'memory-refresh' not in gate_text:
    notes = {os.path.relpath(f, os.path.expanduser('~/.mergeworthy/projects'))[:-3].lower(): f
             for f in glob.glob(os.path.expanduser('~/.mergeworthy/projects/*/*.md'))}
    named = {r for r in notes if re.search(r'(?<![\w.-])' + re.escape(r) + r'(?!\.md)(?:\.git)?(?![\w.-])', gate_text, re.I)}
    tops = set()
    for p in paths if notes else ():
        if p.startswith('//'): continue  # the //host/… of a URL, not a path
        while p != '/' and not os.path.exists(os.path.join(p, '.git')): p = os.path.dirname(p)
        tops.add(p)
    for top in tops - {'/'}:
        url = subprocess.run(['git', '-C', top, 'remote', 'get-url', 'origin'], capture_output=True, text=True).stdout.strip()
        m = re.search(r'[:/]([\w.-]+/[\w.-]+?)(?:\.git)?$', url)
        named |= {m.group(1).lower()} & set(notes) if m else set()
    missing = [notes[r] for r in sorted(named) if f'projects/{r}.md' not in gate_text.lower()]
    if missing:
        sys.stderr.write("BLOCKED: the brief works on a repo with a project file; name each project file in it so the agent reads "
                         "and applies them (mergeworthy:delegate step 3):\n" + '\n'.join(missing) + '\n')
        sys.exit(2)
    # The producer reads the standard its checker uses, by path (delegate step 3): code for an implementer, writing for a drafter.
    need = [f for f, applies in (('skills/code/SKILL.md', named and ti.get('role') == 'implementation'),
                                 ('skills/writing/SKILL.md', 'thread-context.md' in gate_text)) if applies and f not in gate_text]
    if need:
        sys.stderr.write("BLOCKED: name the standard the agent writes to by its path, so it reads it before producing "
                         "(mergeworthy:delegate step 3): " + ', '.join('~/.mergeworthy/current/' + f for f in need) + '\n')
        sys.exit(2)
    # The main session decides on code it read itself, not on an agent's summary: an implementation brief for a repo needs a file
    # tracked in that repo read by this session in the last three hours (Read, Grep, a cat/sed/head/grep/git show on it, gh pr diff,
    # gh api .../contents, or a WebFetch of its github.com page); a report an agent wrote inside a checkout is untracked and doesn't count
    if ti.get('role') == 'implementation' and named and d.get('transcript_path') and os.path.isfile(d['transcript_path']):
        origin = {}
        def repo_of(p):
            top = p if os.path.isdir(p) else os.path.dirname(p)
            while top not in ('/', '') and not os.path.exists(os.path.join(top, '.git')): top = os.path.dirname(top)
            if top in ('/', ''): return '', top
            if top not in origin:
                u = subprocess.run(['git', '-C', top, 'remote', 'get-url', 'origin'], capture_output=True, text=True).stdout.strip()
                m = re.search(r'[:/]([\w.-]+/[\w.-]+?)(?:\.git)?$', u); origin[top] = m.group(1).lower() if m else ''
            return origin[top], top
        def code_read(q):
            q = os.path.expanduser(q.split(':')[0])
            if not os.path.exists(q): return False
            r, top = repo_of(q)
            if r not in named: return False
            return os.path.isdir(q) or subprocess.run(['git', '-C', top, 'ls-files', '--error-unmatch', q], capture_output=True).returncode == 0
        def bash_reads(cmd, cwd):
            out = []
            for seg in re.split(r'&&|\|\||;|\||\n', cmd):
                try: w = shlex.split(seg)
                except ValueError: continue
                if not w: continue
                if w[0] == 'cd' and len(w) > 1: cwd = os.path.join(cwd, os.path.expanduser(w[1])); continue
                if w[0] == 'git' and 'show' in w and not {'--stat', '--name-only', '--name-status', '--no-patch', '-s', '--oneline'} & set(w):
                    c = w[w.index('-C') + 1] if '-C' in w and w.index('-C') + 1 < len(w) else cwd
                    out += [os.path.join(c, a.split(':', 1)[1]) for a in w if re.match(r'^[\w./~^-]+:[^/]', a)] or [c]
                elif w[0] in ('cat', 'sed', 'head', 'tail', 'grep', 'rg', 'less', 'nl'):
                    out += [os.path.join(cwd, os.path.expanduser(a)) for a in w[1:] if not a.startswith('-') and (os.sep in a or '.' in a)]
            return out
        since, seen = time.time() - 3 * 3600, False
        for l in reversed(open(d['transcript_path'], errors='replace').readlines()[-4000:]):
            if seen or '"tool_use"' not in l: continue
            try: e = json.loads(l)
            except ValueError: continue
            try: t = datetime.datetime.fromisoformat(e.get('timestamp', '').replace('Z', '+00:00')).timestamp()
            except ValueError: continue
            if t < since: break
            for x in (e.get('message') or {}).get('content') or []:
                if not isinstance(x, dict) or x.get('type') != 'tool_use': continue
                i, n = x.get('input') or {}, x.get('name')
                if n == 'Bash' and re.search(r'\bgh (pr diff|api repos/\S+/(contents|commits))', i.get('command', '')) and any(r in i['command'].lower() for r in named) \
                        or n == 'WebFetch' and any('github.com/' + r + '/' in i.get('url', '').lower() for r in named):
                    seen = True; break
                cands = [i.get('file_path', '')] if n == 'Read' else [i.get('path', '')] if n == 'Grep' else \
                        bash_reads(i.get('command', ''), e.get('cwd') or '/') if n == 'Bash' else []
                if any(q and code_read(q) for q in cands):
                    seen = True; break
        if not seen:
            sys.stderr.write(f"BLOCKED: read the code this change is about yourself before briefing it ({', '.join(sorted(named))}): open the files "
                             "(no checkout: clone it, or gh pr diff / gh api), the feature's docs page and its JSDoc, and decide from them, not from an agent's report (always-on: the main session)\n")
            sys.exit(2)
    # An author or the fresh reader works from the repo study (task step 4): the project file's ## Who decides links one dated within 30 days
    authors = ti.get('role') == 'implementation' or 'thread-context.md' in gate_text or 'MERGE AS IS' in gate_text
    stale = []
    for r in sorted(named) if authors else ():
        sec = re.search(r'^## Who decides\n(.*?)(?=^## |\Z)', open(notes[r], errors='replace').read(), re.M | re.S)
        # a link relative to the project file counts too (`[r.study.md](r.study.md)`)
        cands = [os.path.join(os.path.dirname(notes[r]), os.path.expanduser(c)) for c in re.findall(r'[^\s()\[\]`]+\.study\.md', sec[1])] if sec else []
        study = next((c for c in cands if os.path.isfile(c)), None)
        first = open(study, errors='replace').readline() if study else ''
        dated = re.match(r'Studied:\s*(\d{4}-\d{2}-\d{2})', first)
        if not dated or (datetime.date.today() - datetime.date.fromisoformat(dated[1])).days > 30:
            stale.append(notes[r])
    if stale:
        sys.stderr.write("BLOCKED: write the repo study first (mergeworthy:task step 4, §Repo study): each project file's `## Who decides` links "
                         "~/.mergeworthy/projects/<owner>/<repo>.study.md whose first line is `Studied: <date>` within 30 days, so the author writes "
                         "what the maintainer merges:\n" + '\n'.join(stale) + '\n')
        sys.exit(2)
    # A drafter (reads the thread record, isn't a review) lists each scope-word claim beside its proof: the template's line
    if 'thread-context.md' in gate_text and 'CLEAN' not in gate_text and not re.search(r'scope word', gate_text, re.I):
        sys.stderr.write("BLOCKED: a drafter brief carries the template's scope-word check: paste "
                         "~/.mergeworthy/current/skills/delegate/drafter.md, filled in (mergeworthy:delegate step 3)\n")
        sys.exit(2)
# Research the program already wrote up (memory.md, the notes) is read, not redone.
root = None if register else memory_file.for_cwd(d.get('cwd') or '')
if root and (ti.get('role') == 'research' or re.search(r'\bresearch', f"{ti.get('title') or ''} {ti.get('description') or ''}", re.I)):
    topic = re.search(r'^\s*Topic:\s*(.+?)\s*$', gate_text, re.M)
    if not topic:
        sys.stderr.write("BLOCKED: a research brief names its topic in a `Topic: <key words>` line, so the hook can search the work folder's files for research already done (mergeworthy:delegate §Brief).\n")
        sys.exit(2)
    words = [w.lower() for w in re.findall(r'[\w.-]{3,}', topic.group(1))]
    checked = ' '.join(re.findall(r'^\s*Checked:\s*(.+)$', gate_text, re.M))
    # covered = one paragraph holds every topic word: a long design doc that mentions them apart covers nothing
    covers = lambda p: any(all(w in para for w in words) for para in re.split(r'\n\s*\n', open(p, errors='replace').read().lower()))
    hits = [p for p in memory_file.notes(root) if p not in checked and os.path.abspath(p) not in tickets and covers(p)]
    if hits:
        sys.stderr.write("BLOCKED: these files already cover the topic; read them first. If one answers it, use it; "
                         "if not, add `Checked: <file>` to the brief for each:\n" + '\n'.join(hits) + '\n')
        sys.exit(2)
# a fan-out runs several agents on one brief, each under its own title: the title is part of the job
key = ' '.join([*tickets, str(ti.get('title') or ti.get('description') or '').strip()]).strip()
if not key:
    sys.exit(0)  # nothing names the job (no ticket, title or description), so no second launch of it can be told apart
jobs = os.path.expanduser('~/.claude/agent-jobs'); os.makedirs(jobs, exist_ok=True)
f = os.path.join(jobs, hashlib.sha256(key.encode()).hexdigest()[:16])
if register:
    json.dump({'key': key, 'started': time.time(), 'brief': str(ti.get('task') or ti.get('prompt') or '')[:2000],
               'session': d.get('session_id'), 'transcript': d.get('transcript_path')}, open(f, 'w'))
    # an agent now runs memory-prep's brief: stop-lint's hourly repeat of the refresh order waits an hour
    for t in tickets:
        if os.path.basename(t).startswith('memory-brief-') and os.path.isfile(os.path.join(os.path.dirname(t), 'memory.source')):
            open(os.path.join(os.path.dirname(t), '.memory-order-repeated'), 'w').close()
elif os.path.exists(f):
    j = json.load(open(f))
    if time.time() - j.get('started', 0) < 24 * 3600:
        age = int((time.time() - j['started']) / 60)
        sys.stderr.write(
            f"BLOCKED: an agent for this job is already registered ({key[:160]}, started {age} min ago). One agent per job: "
            "read its status first (task_status, its latest runs); a turn that ended or 'waiting_for_children' means it is still alive. "
            "Continue it with a message instead of starting another. Only when its task is terminal and you have read its result, "
            f"release the job with `agent-job done {shlex.quote(key[:200])}`, then launch.\n")
        sys.exit(2)
# At most 3 agents at a time per session (delegate step 1): a job is open until released or its agent finished; a memory refresh doesn't count
# A fan-out a step names (finality steps 2-3, converge's per-slice verifiers) says so on a `Fan-out:` line, in the task or its brief, and passes
fanout = ti.get('role') != 'implementation' and re.search(r'^Fan-out: (finality step [23]|converge §Running the agents)$', briefs, re.M)
if not register and d.get('session_id') and 'memory-refresh' not in gate_text and not fanout:
    import agent_jobs
    live = [j for _, j in agent_jobs.jobs() if j.get('session') == d['session_id'] and '/memory-brief-' not in j['key']
            and 'memory-refresh' not in j.get('brief', '') and not agent_jobs.finished(j)]
    if len(live) >= 3:
        sys.stderr.write(f"BLOCKED: this session already has {len(live)} agents open, and the limit is 3 at a time (mergeworthy:delegate step 1):\n"
                         + '\n'.join(f"{j['key'][:160]} (started {int((time.time() - j['started']) / 60)} min ago)" for j in live)
                         + "\nContinue one with a message, or wait for one to finish, read its result and release it with `agent-job done <key>`.\n")
        sys.exit(2)
sys.exit(0)
