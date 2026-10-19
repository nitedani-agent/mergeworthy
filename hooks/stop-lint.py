#!/usr/bin/env python3
"""Claude Code Stop hook. Blocks ending a turn with an offer or permission question the agent should just act on,
or after posting on GitHub with no live Monitor on a watcher's events.log in this session (the session is what answers
the events; nothing else wakes it), or with a line still owed in a live watcher's replies-owed.md (mergeworthy:reply)."""
import glob, json, os, re, sys
d = json.load(sys.stdin)
if d.get('stop_hook_active'):
    sys.exit(0)
last = ''
posted, monitor_ids, monitors, dead, commands, monitor_cmds = False, {}, set(), set(), [], []
last_user = ''  # the user's own last message (not a tool result or a hook's feedback)
said = []  # every text the agent wrote, in order
POST = re.compile(r'\bgh\b[^\n]*(body-file|body=@|--input|\s-F\s)')
READ = re.compile(r'\bgh\s+api\s+graphql\b|\bgh\s+api\b[^\n]*\s(?:-X\s*|--method[\s=])GET\b')  # a field makes `gh api` a POST, but these read
RUN_GH = re.compile(r'(?:^|[;&|(]|\s--)\s*gh\s')  # gh where the shell runs it: a line's start, after ; & | ( or mw post's --
QUOTED = re.compile(r"'[^'\n]*'|\"(?:[^\"\\\n]|\\.)*\"|`[^`\n]*`")  # text in quotes or backticks is data, not a command
def run_lines(cmd):  # the command's lines minus heredoc bodies, which are a file's text
    end = None
    for l in cmd.split('\n'):
        if end is not None:
            if l.strip() == end: end = None
            continue
        doc = re.search(r'<<-?\s*[\'"]?(\w+)', l)
        end = doc and doc.group(1)
        yield l
def posts(cmd):
    return any(POST.search(l) and RUN_GH.search(QUOTED.sub("''", l)) and not (READ.search(l) and 'mutation' not in cmd) for l in run_lines(cmd))
try:
    lines = open(d['transcript_path']).readlines()
except Exception:
    sys.exit(0)
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import steward
# A T3 Code delegated child (its thread has a parent in T3's state, or its prompt says so): its result is its last message, and the main session owns replies and next steps
child = len(steward.threads(d.get('session_id'))) > 1 or any(re.match(r'Act as the [\w-]+ sub-agent for this task', (json.loads(l).get('message') or {}).get('content') or '')
            for l in lines[:20] if '"type":"user"' in l.replace(' ', '') and 'sub-agent for this task' in l)
for line in lines:
    try:
        e = json.loads(line)
    except ValueError:
        continue  # one bad or half-written line must not disable the check
    if not isinstance(e, dict): continue
    c = (e.get('message') or {}).get('content')
    if e.get('type') == 'user':
        texts = [c] if isinstance(c, str) else [x.get('text', '') if x.get('type') == 'text' else json.dumps(x.get('content')) for x in c or [] if isinstance(x, dict)]
        for x in c if isinstance(c, list) else []:
            if isinstance(x, dict) and x.get('tool_use_id') in monitor_ids:
                m = re.search(r'Monitor started \(task (\w+)', json.dumps(x.get('content')))
                if m: monitors.add(m.group(1))
        typed = c if isinstance(c, str) else ' '.join(x.get('text', '') for x in c or [] if isinstance(x, dict) and x.get('type') == 'text')
        if typed.strip() and not typed.lstrip().startswith(('<', 'Stop hook feedback')):
            last_user = typed
        for t in texts:
            for tid in re.findall(r'<task-id>(\w+)</task-id>[\s\S]*?Monitor expired', t or ''): dead.add(tid)
    if e.get('type') == 'assistant':
        for x in c if isinstance(c, list) else []:
            if not isinstance(x, dict) or x.get('type') != 'tool_use': continue
            i = x.get('input') or {}
            if x.get('name') == 'Bash' and posts(i.get('command', '')): posted = True
            if x.get('name') == 'Bash': commands.append(i.get('command', ''))
            if x.get('name') == 'Monitor' and 'events.log' in i.get('command', ''):
                monitor_ids[x.get('id')] = 1
                monitor_cmds.append(i.get('command', ''))
            if x.get('name') == 'TaskStop': dead.add(i.get('task_id') or i.get('shell_id') or '')
        if isinstance(c, list):
            t = ''.join(x.get('text', '') for x in c if isinstance(x, dict) and x.get('type') == 'text')
            if t.strip(): last = t; said.append(t)
# quoted words are someone else's (a user's "should I ...?", a banned phrase being discussed): not an offer
own = re.sub(r'```.*?```|`[^`\n]*`|"[^"\n]*"|“[^”\n]*”|^>.*$', ' ', last, flags=re.S | re.M)
tail = own.strip()[-400:]
OFFER = r"(when you say (go|so)|say the word|want me to|shall I|should I\b|if you want|if you'd rather|your call|is yours to|or would you rather|which do you (want|prefer)|let me know if)"
if re.search(OFFER, tail, re.I) and 'GENUINE-FORK' not in last:
    print("Your last message ends with an offer or a permission question. If it is your own recommendation or in scope, "
          "do it now. Ask only for (a) irreversible actions on shared state you didn't create, (b) money, credentials "
          "or the user's global config, (c) an external maintainer's product decision or a fork you can't rank; then "
          "include a line starting 'GENUINE-FORK:' with your recommended default.", file=sys.stderr)
    sys.exit(2)
# A fork is asked once: until the user answers it, it waits in questions-owed.md, not at the end of every report
FORK = lambda t: {re.sub(r'\W+', ' ', f).strip().lower() for f in re.findall(r'^GENUINE-FORK:(.*)$', t, re.M)}
asked = set().union(*map(FORK, said[:-1])) if len(said) > 1 else set()
if not child and FORK(last) & asked:
    print("This GENUINE-FORK line was already sent to the user in this session. Ask a fork once: until they answer, "
          "it waits in questions-owed.md, and a later report doesn't repeat it. Send it again only with changed "
          "options, or when the user asks about it (always-on: Do, don't offer).", file=sys.stderr)
    sys.exit(2)
# A Running list in the reply is checked against T3 task status: it is read live (task_status) after the user's last
# message, and names no task whose last read status is terminal.
running = re.search(r'^(?:#+ *Running\b|[-*\s]*\*{0,2}Running\*{0,2}:)(.*(?:\n[ \t]*[-*\d].*)*)', last, re.M)  # a `Running:` label or heading
if running and not child:
    titles, status, launched, fresh = {}, {}, False, False
    for line in lines:
        try: e = json.loads(line)
        except ValueError: continue
        c = (e.get('message') or {}).get('content') if isinstance(e, dict) else None
        if e.get('type') == 'user' and isinstance(c, str) and not c.startswith('<'):
            # T3's own completion notice and a skill's re-invocation aren't the user: a notice marks its task terminal instead
            n = re.match(r'Delegated task (\S+) reached a terminal state', c)
            if n: status[n.group(1)] = ('completed', status.get(n.group(1), ('', ''))[1])
            elif not c.startswith('Skill /'): fresh = False
        for b in c if isinstance(c, list) else []:
            if b.get('type') == 'tool_use' and re.search(r'(delegate_task|task_status)$', b.get('name', '')):
                titles[b['id']] = (b.get('name', '').endswith('task_status'), str((b.get('input') or {}).get('title') or ''))
                launched = launched or not titles[b['id']][0]
            elif b.get('type') == 'tool_result' and b.get('tool_use_id') in titles:
                r = b.get('content'); r = ''.join(x.get('text', '') for x in r) if isinstance(r, list) else str(r or '')
                try: r = json.loads(r)
                except ValueError: continue
                if isinstance(r, dict) and r.get('taskId'):
                    is_read, title = titles[b['tool_use_id']]
                    old = status.get(r['taskId'], ('', ''))
                    status[r['taskId']] = (str(r.get('status') or ''), title or old[1])
                    fresh = fresh or is_read
    text = running.group(1).lower()
    done = [t or i for i, (st, t) in status.items() if re.match(r'(completed|failed|cancel+ed|interrupted|error)', st)
            and ((t and t.lower() in text) or i.rsplit('%3A', 1)[-1].lower() in text)]
    if launched and (done or not fresh):
        print(f"Your Running list names {', '.join(done)}, whose task status is terminal." if done else
              "Your Running list wasn't read from T3 since the user's last message.", "Read task_status for each agent you list "
              "and list only the ones still working (mergeworthy:writing §Reports to the user).", file=sys.stderr)
        sys.exit(2)
# A message opening with "it's done" names no linked PR or MR that is still a draft or not green (mergeworthy:merging, Ready)
DONE = r"(?<!not )(?<!nem )\b(?:(?:is|are|all|work's|it's) (?:done|finished|complete)\b|ready (?:for review|to merge)|kész\b|elkészült|befejeztem)"
if not child and re.search(DONE, own.strip()[:300], re.I):
    import subprocess, urllib.parse
    def api(cmd):
        try: return json.loads(subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout or 'null')
        except (OSError, ValueError, subprocess.SubprocessError): return None
    unfinished = []
    for host, path, n in list(dict.fromkeys(re.findall(r'https://(github\.com|gitlab\.[\w.]+)/([\w.-]+/[\w./-]+?)(?:/-)?/(?:pull|merge_requests)/(\d+)', last)))[:10]:
        url = f'https://{host}/{path}/{"pull" if host == "github.com" else "-/merge_requests"}/{n}'
        if host == 'github.com':
            pr = api(['gh', 'api', f'repos/{path}/pulls/{n}'])
            if not isinstance(pr, dict) or pr.get('state') != 'open': continue
            runs = api(['gh', 'api', f'repos/{path}/commits/{pr["head"]["sha"]}/check-runs']) or {}
            red = [r.get('name') for r in runs.get('check_runs', []) if r.get('conclusion') not in ('success', 'skipped', 'neutral')]
            why = (['draft'] if pr.get('draft') else []) + ([f"checks not green: {', '.join(red[:3])}"] if red else [])
        else:
            mr = api(['glab', 'api', '--hostname', host, f'projects/{urllib.parse.quote(path, safe="")}/merge_requests/{n}'])
            if not isinstance(mr, dict) or mr.get('state') != 'opened': continue
            ci = (mr.get('head_pipeline') or {}).get('status') or 'no pipeline'
            why = (['draft'] if mr.get('draft') else []) + ([f'pipeline {ci}'] if ci != 'success' else [])
        if why: unfinished.append(f"{url} ({', '.join(why)})")
    if unfinished:
        print("Your message opens by calling the work done, but these PRs/MRs it links aren't: " + '; '.join(unfinished) +
              ". Say what is left on each instead (the converge gates, green CI, ready), and do it (mergeworthy:merging, Ready).", file=sys.stderr)
        sys.exit(2)
own_dirs = set()
reg = os.path.expanduser('~/.claude/gh-watch-dirs.txt')
cwd_d = d.get('cwd') or ''
for wd in (l.strip() for l in open(reg)) if os.path.exists(reg) else ():
    # or a watch dir this session works through from elsewhere (its cwd is a repo, the watch dir an artifact root):
    # it watches its events.log, starts its watcher or gates a draft in it. Only reading another session's files
    # (its state, its log) doesn't make that session's owed replies this one's.
    home_wd = wd.replace(os.path.expanduser('~'), '~', 1)
    def mentions(c): return wd in c or home_wd in c
    if wd and (cwd_d == wd or cwd_d.startswith(wd.rstrip('/') + '/') or any(map(mentions, monitor_cmds))
               or any(re.search(r'\b(gh-watch-start|gate-pass)\s+(--main\s+)?(\S*/)?(' + re.escape(wd) + '|' + re.escape(home_wd) + r')(/\S*)?(\s|$)', c) for c in commands)): own_dirs.add(wd)  # started or posted from there, not merely mentioned
_env = os.path.expanduser('~/.mergeworthy/settings.env')
# MERGEWORTHY_WATCHER in the environment wins over the plugin option, as for every script
watcher_on = (os.environ.get('MERGEWORTHY_WATCHER') or ('off' if 'MERGEWORTHY_WATCHER=off' in (open(_env).read() if os.path.exists(_env) else '') else 'on')) != 'off'
# A headless run (`claude -p`, entrypoint sdk-cli) has no Monitor tool: its caller watches
headless = any('"entrypoint":"sdk-cli"' in l for l in lines[-20:])
# The user paused the work: nothing is to be watched or answered until they resume
paused = re.search(r'\bpause\b', last_user, re.I) is not None
if posted and watcher_on and not headless and not paused and not (monitors - dead):
    print("You posted on GitHub in this session and no Monitor in it watches a watcher's events.log, so replies go unseen: "
          "nothing else answers them. Run `gh-watch-start <your work folder> <owner/repo> <N>` and arm the Monitor it "
          "prints, with the longest timeout; re-arm it whenever it expires (mergeworthy:reply step 1).", file=sys.stderr)
    sys.exit(2)
# The owed-reply list: the daemon records each human comment in the live watcher's replies-owed.md; a turn
# cannot end with a line still owed.
if watcher_on and not paused and not child:
    for wd in sorted(own_dirs):
        try:
            os.kill(int(open(os.path.join(wd, 'gh-watch.pid')).read().strip()), 0)
        except (OSError, ValueError):
            continue  # no live daemon in this dir
        f = os.path.join(wd, 'replies-owed.md')
        owed = [l.strip() for l in open(f) if l.strip() and not l.startswith('#')] if os.path.exists(f) else []
        import datetime
        try: events_text = open(os.path.join(wd, 'events.log'), errors='replace').read()
        except OSError: events_text = ''
        def holding(l):  # `holding: <reply url> <ETA>`: a holding reply was posted; `drafting: <comment url> <ETA>`: an agent drafts the answer; ETA is an ISO time
            m = re.match(r'(holding|drafting):\s+(\S+)\s+(\S+)', l, re.I)
            try:
                eta = m and datetime.datetime.fromisoformat(m.group(3).replace('Z', '+00:00'))
                if not eta or eta <= datetime.datetime.now(datetime.timezone.utc): return False
            except ValueError:
                return False
            # a drafting line holds only a short wait: an answer due over 30 minutes after the comment gets a holding reply (reply step 3)
            cid = re.search(r'(?:note_|issuecomment-|discussion_r|#r)(\d+)', m.group(2))
            when = cid and re.search(rf'\b{cid.group(1)} by \S+ (\d{{4}}-\d\d-\d\dT[\d:]+Z)', events_text)
            if m.group(1).lower() == 'drafting' and when and eta - datetime.datetime.fromisoformat(when.group(1).replace('Z', '+00:00')) > datetime.timedelta(minutes=30):
                return False
            return True
        open_owed = [l for l in owed if not l.lower().startswith('done:') and not holding(l)]
        if open_owed:
            print(f"replies-owed.md in {wd} still has an owed reply ({open_owed[0][:120]}). Answer it through the gate and clear the "
                  "line with 'done: <reply url> <what changed>' (mergeworthy:post step 5), or clear it with the reason no reply is owed. "
                  "An answer due more than 30 minutes after the comment gets a holding reply now, through post's fast form, "
                  "with what you found so far and when the answer comes (`holding: <reply url> <ETA>`, mergeworthy:reply step 3).",
                  file=sys.stderr)
            sys.exit(2)
# A promise posted with a time (`by 2026-10-12T17:30Z`, `by 18:00 UTC`, in its PROMISED line or its draft) is kept by then: past it,
# a line still opening with PROMISED, not cleared by the commit or link that delivers it (task §Files), blocks the turn
if watcher_on and not paused and not child:
    import datetime, time
    BY = re.compile(r'\b(?:by|before)\s+(?:(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?Z)|(\d{1,2}):(\d{2})\s*(?:Z|UTC)\b)', re.I)
    def due(text, written):
        """The first promised time in text; a bare time of day is the first one after the draft was written."""
        m = BY.search(text)
        if not m: return None
        if m[1]: return datetime.datetime.fromisoformat(m[1].replace('Z', '+00:00')).timestamp()
        w = datetime.datetime.fromtimestamp(written, datetime.timezone.utc)
        t = w.replace(hour=int(m[2]) % 24, minute=int(m[3]), second=0, microsecond=0)
        return (t + datetime.timedelta(days=1) if t < w else t).timestamp()
    for po in sorted(p for wd in own_dirs for p in glob.glob(os.path.join(wd, 'proposals-open.md')) + glob.glob(os.path.join(wd, '*', 'proposals-open.md'))):
        for l in open(po, errors='replace'):
            if not l.startswith('PROMISED'): continue
            name = re.search(r'\(([^()\s]+\.md)[,)]', l)
            drafts = [x for n in ([name[1]] if name else []) for x in glob.glob(os.path.join(os.path.dirname(po), 'drafts', n)) + glob.glob(os.path.join(os.path.dirname(po), 'drafts', '*', n))]
            at = due(l, os.path.getmtime(drafts[0] if drafts else po)) or next((t for t in (due(open(x, errors='replace').read(), os.path.getmtime(x)) for x in drafts) if t), None)
            if at and at < time.time():
                print(f"A promise in {po} fell due at {datetime.datetime.fromtimestamp(at, datetime.timezone.utc):%Y-%m-%dT%H:%MZ} and isn't delivered: {l.strip()[:200]}. "
                      "Deliver it now, or post (through the gate) why it's late and when it lands; then open the line with `DONE <commit or link>` (mergeworthy:task §Files).", file=sys.stderr)
                sys.exit(2)
# Each FOLLOW-UP the watcher reported is sorted by a verdict line in followups-sorted.txt within 30 minutes (mergeworthy:rules step 6),
# by the session whose dir's events.log got it (steward.recipient chose it): the session's own dirs, and a declared steward's
if watcher_on and not paused and not child:
    import datetime, time
    st = steward.read()
    for wd in sorted(own_dirs | ({st[0]} if st and steward.is_steward(d.get('session_id'), cwd_d) else set())):
        try: log = open(os.path.join(wd, 'events.log'), errors='replace').read()
        except OSError: continue
        f = os.path.join(wd, 'followups-sorted.txt')
        done = re.findall(r'^(\S+)\s+(?:MISS|TASTE|DIRECTION|WORKED)\s+\S', open(f, errors='replace').read() if os.path.exists(f) else '', re.M)
        late = [k for k, at in re.findall(r'^### (?:FOLLOW-UP|MAINTAINER REVIEW) [^:\n]+: (\S+) by .*  at (\S+Z)$', log, re.M)
                if time.time() - datetime.datetime.fromisoformat(at.replace('Z', '+00:00')).timestamp() > 1800
                and not any(v == k or (len(v) >= 7 and k[:7] == v[:7] and (v.startswith(k) or k.startswith(v))) for v in done)]
        if late:
            print(f"These FOLLOW-UP and MAINTAINER REVIEW events in {wd}/events.log are unsorted after 30 minutes: {', '.join(dict.fromkeys(late))}. Brief the sort "
                  f"(mergeworthy:rules step 6) and record each as `<sha, PR or review URL> MISS|TASTE|WORKED|DIRECTION <link or reason>` in {f}.", file=sys.stderr)
            sys.exit(2)
# The main session's memory.md is behind and covers nothing from the last 2 hours: the session-start order is repeated, at most hourly
if not child and not paused:
    sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
    import datetime, time, memory_file as mf
    try: root = mf.for_cwd(cwd_d)
    except (OSError, ValueError): root = None
    stamp = root and os.path.join(root, '.memory-order-repeated')
    if root and time.time() - (os.path.getmtime(stamp) if os.path.exists(stamp) else 0) > 3600:
        cov = mf.covered(root)
        if (not cov or time.time() - datetime.datetime.fromisoformat(cov.replace('Z', '+00:00')).timestamp() > 7200) and mf.behind(root):
            open(stamp, 'w').close()
            print(mf.order(root, live=True), file=sys.stderr)
            sys.exit(2)
# An agent this session launched has finished (its transcript went quiet) and its job is still open: its result is unread
if not child and d.get('session_id'):
    sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
    import agent_jobs, shlex
    for f, j in agent_jobs.jobs():
        done = j.get('session') == d['session_id'] and agent_jobs.finished(j)
        if done:
            print(f"The agent for {j['key'][:200]} has finished (its transcript {done[0]} went quiet) and its job is open: read its "
                  f"result (task_status / its report), act on it, then `agent-job done {shlex.quote(j['key'][:200])}` (mergeworthy:delegate step 6).", file=sys.stderr)
            sys.exit(2)
# Hook scripts run from ~/.mergeworthy/current (hooks/run), but the hook list is the one this session started with: when a newer
# version changed hooks.json, say so once per session
own_root, cur = os.environ.get('CLAUDE_PLUGIN_ROOT') or '', os.path.realpath(os.path.expanduser('~/.mergeworthy/current'))
def hook_list(r):
    try: return open(os.path.join(r, 'hooks', 'hooks.json')).read()
    except OSError: return None
told = os.path.expanduser(f"~/.claude/mergeworthy-restart-told/{d.get('session_id')}")
if (not child and d.get('session_id') and '/plugins/cache/' in own_root and os.path.isdir(own_root) and os.path.isdir(cur) and os.path.realpath(own_root) != cur
        and os.path.getmtime(own_root) < os.path.getmtime(cur) and hook_list(own_root) != hook_list(cur) and not os.path.exists(told)):
    os.makedirs(os.path.dirname(told), exist_ok=True); open(told, 'w').close()
    print(f"mergeworthy's hook list changed after this session started ({own_root} -> {cur}): tell the user that a restart of this "
          "session (exit, then `claude --resume`) loads it.", file=sys.stderr)
    sys.exit(2)
# The Skill tool opens the skills this session started with: when a newer version changed them, say once per session where
# the installed text is
def skill_texts(r):
    out = {}
    for f in glob.glob(os.path.join(r, 'skills', '*', '*.md')):
        try: out[os.path.relpath(f, r)] = open(f).read()
        except OSError: pass
    return out
told = os.path.expanduser(f"~/.claude/mergeworthy-skills-told/{d.get('session_id')}")
if (not child and d.get('session_id') and '/plugins/cache/' in own_root and os.path.isdir(own_root) and os.path.isdir(cur)
        and os.path.realpath(own_root) != cur and not os.path.exists(told) and skill_texts(own_root) != skill_texts(cur)):
    os.makedirs(os.path.dirname(told), exist_ok=True); open(told, 'w').close()
    names = ', '.join(sorted(os.path.basename(x) for x in glob.glob(os.path.join(cur, 'skills', '*')) if os.path.isdir(x)))
    print(f"The Skill tool opens this session's older copy of the mergeworthy skills ({own_root}); the installed version ({cur}) "
          f"changed them. Until a restart, after opening a skill, read and follow ~/.mergeworthy/current/skills/<name>/SKILL.md "
          f"and paste briefs from there. Installed skills: {names}. Renamed: core -> task; github-threads -> post and reply; "
          "design-loop -> design; delegating -> delegate and rules; past-failures -> rules; verify, guardian and refactor -> converge; mechanisms -> docs/mechanisms.md; memory-refresh -> delegate/memory-refresh.md.", file=sys.stderr)
    sys.exit(2)
# Before a turn ends, one check-in (the hook doesn't ask twice in a row: stop_hook_active lets the next stop through)
# At most once per MERGEWORTHY_STOP_CHECKIN_SECONDS (default 30 min): every extra turn re-reads the whole context from cache
def checkin_due():
    import time
    f = os.path.expanduser('~/.claude/mergeworthy-stop-checkin')
    try:
        last = float(open(f).read().strip())
    except (OSError, ValueError):
        last = 0
    if time.time() - last < float(os.environ.get('MERGEWORTHY_STOP_CHECKIN_SECONDS', '1800')):
        return False
    os.makedirs(os.path.dirname(f), exist_ok=True)
    open(f, 'w').write(str(time.time()))
    return True
if os.environ.get('MERGEWORTHY_STOP_CHECKIN', 'on') != 'off' and not child and checkin_due():
    print("Before you stop, check once: did the user ask you to stop or pause? Then stop. Otherwise: is there work you said "
          "is next, or that the critical path needs, that you could start now? Is anything waiting on you (a reply owed, "
          "red CI, a finished agent's result to read, a dependency that landed)? If so, do it now, or brief a subagent for it. If nothing is, stop.",
          file=sys.stderr)
    sys.exit(2)
sys.exit(0)
