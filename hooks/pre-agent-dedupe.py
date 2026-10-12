#!/usr/bin/env python3
"""Claude Code PreToolUse hook (matcher: Agent, Task, delegate_task). Exit 2 blocks the launch; stderr goes to the agent.
With the argument `register` it runs as the PostToolUse hook: only a launch that ran is registered, so one another hook blocked leaves no job.
One agent per job: a launch is registered under its job key (the ticket files its prompt names, else its title), and a second
launch of the same job is blocked until `agent-job done <key>` releases it. A turn that ended is not a finished agent: on T3 a
child wakes again when its background commands end, so only its terminal task status (read first) releases the job."""
import hashlib, json, os, re, sys, time
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import state_file
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
# A session working from a program state file (core 1.2) names the workstream of every agent it starts, so work the file
# records as done or replaced isn't started again after a compaction forgot it.
state = None if register else state_file.used(d)
if state:
    named = re.search(r'^\s*State:\s*(.+?)\s*$', gate_text, re.M)
    ws = state_file.workstreams(state)
    if not named or named.group(1) not in ws:
        sys.stderr.write(f"BLOCKED: {'no `State: <workstream>` line in the brief' if not named else f'no workstream {named.group(1)!r} in {state}'}. "
                         f"Read {state} first: if a workstream there already covers this job, continue it; otherwise add its block. "
                         f"Then name it in the brief as `State: <workstream>`. Workstreams: {', '.join(ws) or 'none'}.\n")
        sys.exit(2)
    status = state_file.field(ws[named.group(1)], 'status')
    if re.match(r'(done|merged|superseded|dead)\b', status, re.I):
        sys.stderr.write(f"BLOCKED: workstream {named.group(1)!r} is `{status}` in {state}. Use its result "
                         f"(evidence: {state_file.field(ws[named.group(1)], 'evidence') or 'none'}) or the workstream that replaced it; "
                         "new work gets its own block saying why the old result doesn't cover it.\n")
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
