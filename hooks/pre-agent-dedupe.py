#!/usr/bin/env python3
"""Claude Code PreToolUse hook (matcher: Agent, Task, delegate_task). Exit 2 blocks the launch; stderr goes to the agent.
With the argument `register` it runs as the PostToolUse hook: only a launch that ran is registered, so one another hook blocked leaves no job.
One agent per job: a launch is registered under its job key (the ticket files its prompt names, else its title), and a second
launch of the same job is blocked until `agent-job done <key>` releases it. A turn that ended is not a finished agent: on T3 a
child wakes again when its background commands end, so only its terminal task status (read first) releases the job."""
import hashlib, json, os, re, sys, time
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import memory_file, subprocess
register = sys.argv[1:] == ['register']
d = json.load(sys.stdin)
ti = d.get('tool_input', {}) or {}
# T3 answers a delegate_task whose clientRequestId it has seen with that earlier task's result, without running anything.
# Reuse is allowed only within 10 minutes (a retry of the same launch).
cid = str(ti.get('clientRequestId') or '')
if cid:
    ids = os.path.expanduser('~/.claude/agent-client-request-ids.json'); os.makedirs(os.path.dirname(ids), exist_ok=True)
    seen = json.load(open(ids)) if os.path.exists(ids) else {}
    if cid in seen and time.time() - seen[cid] > 600:
        sys.stderr.write(f"BLOCKED: clientRequestId '{cid}' was used before; T3 would return that earlier task's result instead of running this one. Use a new id (add the date or the head SHA).\n")
        sys.exit(2)
    if register:
        seen.setdefault(cid, time.time()); json.dump(seen, open(ids, 'w'))
text = '\n'.join(str(ti.get(k) or '') for k in ('prompt', 'task', 'description', 'title'))
tickets = sorted(set(re.findall(r'(/[^\s`\'"]+\.md)\b', text)))
# A gate review (names a review output `.out` and CLEAN) starts only on drafts that passed post-lint in their current form.
gate_text = text + '\n' + '\n'.join(open(t).read() for t in tickets if os.path.isfile(t))
if not register and re.search(r'\.out\b', gate_text) and 'CLEAN' in gate_text:
    for draft in sorted(set(re.findall(r'(/[^\s`\'"()]*/drafts/[^\s`\'"()]+\.md)\b', gate_text))):
        base = os.path.basename(draft)
        if base.endswith(('.parent.md', '.current.md', '.report.md')) or 'ticket' in base or 'research' in base or re.search(r'\.v\d+\.md$', base) or not os.path.isfile(draft):
            continue
        try: ok = open(draft + '.lint.sha').read().strip() == hashlib.sha256(open(draft, 'rb').read()).hexdigest()
        except OSError: ok = False
        if not ok:
            sys.stderr.write(f"BLOCKED: {draft} has no passing post-lint for its current text: run post-lint first, then the review.\n")
            sys.exit(2)
# A brief pinned to an older commit of a worktree it names (a linked one: the user's own checkouts are read at any
# commit) re-runs work on code that has moved on.
if not register:
    shas = set(re.findall(r'\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b', gate_text))
    git = lambda wt, *a: subprocess.run(['git', '-C', wt, *a], capture_output=True, text=True)
    for wt in sorted({p.rstrip('/.,:') for p in re.findall(r'(/[^\s`\'"()<>,;]+)', gate_text)} if shas else ()):
        head = git(wt, 'rev-parse', 'HEAD').stdout.strip() if os.path.isfile(os.path.join(wt, '.git')) else ''
        if head and not any(head.startswith(x) for x in shas):
            old = [x for x in shas if git(wt, 'merge-base', '--is-ancestor', x, head).returncode == 0]
            if old:
                root = memory_file.for_cwd(d.get('cwd') or '')
                ruled = memory_file.section(open(memory_file.path(root)).read(), 'Ruled out') if root and os.path.isfile(memory_file.path(root)) else ''
                sys.stderr.write(f"BLOCKED: the brief pins {', '.join(sorted(old))} in {wt}, which has moved on to {head[:12]}. "
                                 "Pin the live head (and check the work isn't already done there)." + (f" Ruled out:\n{ruled}\n" if ruled else "\n"))
                sys.exit(2)
# Research the program already wrote up (memory.md, the notes) is read, not redone.
root = None if register else memory_file.for_cwd(d.get('cwd') or '')
if root and (ti.get('role') == 'research' or re.search(r'\bresearch', f"{ti.get('title') or ''} {ti.get('description') or ''}", re.I)):
    topic = re.search(r'^\s*Topic:\s*(.+?)\s*$', gate_text, re.M)
    if not topic:
        sys.stderr.write("BLOCKED: a research brief names its topic in a `Topic: <key words>` line, so the program's notes are searched first.\n")
        sys.exit(2)
    words = [w.lower() for w in re.findall(r'[\w.-]{3,}', topic.group(1))]
    checked = ' '.join(re.findall(r'^\s*Checked:\s*(.+)$', gate_text, re.M))
    hits = [p for p in memory_file.notes(root) if p not in checked and all(w in open(p, errors='replace').read().lower() for w in words)]
    if hits:
        sys.stderr.write("BLOCKED: these files already cover the topic; read them first. If one answers it, use it; "
                         "if not, add `Checked: <file>` to the brief for each:\n" + '\n'.join(hits) + '\n')
        sys.exit(2)
key = ' '.join(tickets) or (str(ti.get('title') or ti.get('description') or '').strip())
if not key:
    sys.exit(0)
jobs = os.path.expanduser('~/.claude/agent-jobs'); os.makedirs(jobs, exist_ok=True)
f = os.path.join(jobs, hashlib.sha256(key.encode()).hexdigest()[:16])
if register:
    json.dump({'key': key, 'started': time.time()}, open(f, 'w'))
elif os.path.exists(f):
    j = json.load(open(f))
    if time.time() - j.get('started', 0) < 24 * 3600:
        age = int((time.time() - j['started']) / 60)
        sys.stderr.write(
            f"BLOCKED: an agent for this job is already registered ({key[:160]}, started {age} min ago). One agent per job: "
            "read its status first (task_status, its latest runs); a turn that ended or 'waiting_for_children' means it is still alive. "
            "Continue it with a message instead of starting another. Only when its task is terminal and you have read its result, "
            f"release the job with `agent-job done '{key[:200]}'`, then launch.\n")
        sys.exit(2)
sys.exit(0)
