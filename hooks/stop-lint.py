#!/usr/bin/env python3
"""Claude Code Stop hook. Blocks ending a turn while the task's scope.md has an open item and nothing this session armed will
wake it, with an offer or hand-back the agent should just act on, with a claim about a PR that GitHub contradicts, after posting
on GitHub with no live Monitor on a watcher's events.log in this session (the session is what answers the events; nothing else
wakes it), or with a line still owed in a watcher's replies-owed.md (mergeworthy:reply).
The final message is the hook input's last_assistant_message (the transcript may not hold it yet). stop_hook_active skips only
the check-in: every other check holds until it is met (Claude Code itself ends the turn after 8 blocks in a row)."""
import glob, hashlib, json, os, re, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import failclosed
d = json.load(sys.stdin)
active = bool(d.get('stop_hook_active'))
last = ''
posted, monitor_ids, monitors, dead, commands, monitor_cmds = False, {}, set(), set(), [], []
wakers, opened_task, acted, delegated = {}, False, False, False  # the background commands and Monitors this session started; whether it is a task's
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
    lines = open(d['transcript_path'], errors='replace').readlines()
except (KeyError, TypeError, OSError):
    # Without the transcript, what the session did can't be checked: block once; on the stop after, the final message's
    # own checks still run (this session can't make its transcript readable)
    claude = subprocess.run(['ps', '-p', os.environ.get('CLAUDE_PID', ''), '-o', 'command='], capture_output=True, text=True).stdout
    if '--no-session-persistence' in claude.split(): sys.exit(0)  # a run that keeps no transcript (claude -p for a program's output)
    if not active:
        print(f"stop-lint can't read this session's transcript ({d.get('transcript_path')}), so whether its work is finished can't be checked. "
              "Re-check it yourself: anything owed, unfinished or unwatched, do now; then end the turn.", file=sys.stderr)
        sys.exit(2)
    lines = []
import steward
from shellcmd import segments, prog, git_argv, Where
# A T3 Code delegated child (its thread has a parent in T3's state, or its prompt says so): its result is its last message, and the main session owns replies and next steps
def opening(l):  # a user line's typed text ('' for a tool result's list, or a line that isn't JSON)
    try: c = (json.loads(l).get('message') or {}).get('content')
    except (ValueError, AttributeError): return ''
    return c if isinstance(c, str) else ''
t3_chain = steward.threads(d.get('session_id'))  # its T3 thread, then the threads that delegated it; [] outside T3 Code
child = len(t3_chain) > 1 or any(re.match(r'Act as the [\w-]+ sub-agent for this task', opening(l))
            for l in lines[:20] if '"type":"user"' in l.replace(' ', '') and 'sub-agent for this task' in l)
reg = os.path.expanduser('~/.claude/gh-watch-dirs.txt')
def watching(wd):  # wd's watcher daemon runs
    try: os.kill(int(steward.first(os.path.join(wd, 'gh-watch.pid'))), 0)
    except (ValueError, OSError): return False
    return True
live_dirs = [wd for wd in ((l.strip() for l in open(reg)) if os.path.exists(reg) else ()) if wd and watching(wd)]
# a live watcher that sends wd's events to this session's T3 thread (gh-watch.py's wake_thread): its Monitor
t3_dirs = {wd for wd in live_dirs if steward.first(os.path.join(wd, 't3-thread')) in t3_chain}
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
            for tid, st in re.findall(r'<task-id>(\w+)</task-id>[\s\S]*?<status>(\w+)</status>', t or ''):
                if st in ('completed', 'failed', 'killed', 'stopped', 'cancelled', 'canceled', 'error'): dead.add(tid)
            for tid in re.findall(r'Command running in background with ID: (\w+)|Monitor started \(task (\w+)', t or ''):
                wakers[tid[0] or tid[1]] = 1
        opened_task = opened_task or '<command-name>/mergeworthy:task</command-name>' in typed
    if e.get('type') == 'assistant':
        for x in c if isinstance(c, list) else []:
            if not isinstance(x, dict) or x.get('type') != 'tool_use': continue
            i = x.get('input') or {}
            if x.get('name') == 'Bash' and posts(i.get('command', '')): posted = True
            if x.get('name') == 'Bash': commands.append(i.get('command', ''))
            if x.get('name') == 'Skill' and str(i.get('skill', '')) in ('task', 'mergeworthy:task'): opened_task = True
            if x.get('name') == 'Monitor' and 'events.log' in i.get('command', ''):
                monitor_ids[x.get('id')] = 1
                monitor_cmds.append(i.get('command', ''))
            if x.get('name') in ('Agent', 'Task') or re.search(r'(delegate_task|t3_thread_launch)$', x.get('name', '')): delegated = True
            if x.get('name') == 'TaskStop': dead.add(i.get('task_id') or i.get('shell_id') or '')
        if isinstance(c, list):
            t = ''.join(x.get('text', '') for x in c if isinstance(x, dict) and x.get('type') == 'text')
            if t.strip(): last = t; said.append(t)
# The final message as the harness hands it over: the transcript may not hold it yet when this hook runs
fin = d.get('last_assistant_message')
if isinstance(fin, str) and fin.strip():
    if not said or said[-1].strip() != fin.strip(): said.append(fin)
    last = fin
cwd_d = d.get('cwd') or ''
import work_folder
# Each stop reads the whole session's commands: their parses are kept per session (by the parser's pin and the command), so a
# stop parses only the commands since the last one
_parse_dir = os.path.expanduser('~/.claude/mergeworthy-parses')
_parse_file = os.path.join(_parse_dir, re.sub(r'[^\w-]', '', d.get('session_id') or '') or 'none') + '.json'
try: parsed = json.load(open(_parse_file))
except (OSError, ValueError): parsed = {}
import shellcmd
_pin = hashlib.sha256(open(shellcmd.REQUIREMENTS, 'rb').read()).hexdigest()[:16]
_key = lambda c: hashlib.sha256((_pin + c).encode()).hexdigest()[:32]
def runs(rx):  # the simple commands of this session's commands that rx finds a word of: a push names git, a work folder's path names it
    from concurrent.futures import ThreadPoolExecutor
    todo = [c for c in dict.fromkeys(commands) if _key(c) not in parsed and re.search(rx, c)]
    if todo:
        with ThreadPoolExecutor(8) as ex:  # each parse is its own shfmt process
            done = list(zip(todo, ex.map(shellcmd.parse, todo)))
        parsed.update({_key(c): segs for c, (segs, err) in done})
        keep = {_key(c): segs for c, (segs, err) in done if 'shell parser' not in err}  # not what a missing parser made of it
        try:
            os.makedirs(_parse_dir, exist_ok=True)
            [os.remove(os.path.join(_parse_dir, f)) for f in os.listdir(_parse_dir) if os.path.getmtime(os.path.join(_parse_dir, f)) < time.time() - 30 * 86400]
            old = json.load(open(_parse_file)) if os.path.exists(_parse_file) else {}
            open(_parse_file + '.tmp', 'w').write(json.dumps({**old, **keep})); os.replace(_parse_file + '.tmp', _parse_file)
        except (OSError, ValueError): pass  # the parses still hold for this stop
    return [prog(t) for c in commands if re.search(rx, c) for t in parsed[_key(c)]]
acted = posted or any(t[:3] in (['gh', 'pr', 'create'], ['gh', 'issue', 'create']) or t[:1] == ['git'] and git_argv(t, Where(cwd_d or '.'))[2] == 'push'
                      for t in runs(r'\b(?:git|gh)\b'))
# the folders it works in: its cwd, and where its commands cd, write, run git or the step tools; one it only read isn't
worked = [cwd_d]
for t in runs(r'\.mergeworthy/work|-work\b'):
    name = os.path.basename(t[0]) if t else ''
    worked += [x for x in t[1:] if not x.startswith('-')] if name in (
        'cd', 'pushd', 'mkdir', 'gh-watch-start', 'gate-pass', 'pr-steps', 'memory-prep', 'post-lint', 'thread-context') else []
    worked += [t[i + 1] for i in range(len(t) - 1) if t[i] == '-C' and name == 'git' or re.fullmatch(r'\d*>>?|&>>?', t[i])]
task_dirs = {t for p in worked if p.startswith(('/', '~')) and (t := work_folder.task_of(p))}
# mergeworthy work (a task, a work folder, a push or post, a watcher, an agent it started) gets the hand-back check;
# a plain question answered doesn't
working = opened_task or acted or delegated or bool(task_dirs or monitor_cmds or t3_dirs)
# the check-in asks only where work can still be waiting after the answer: a work folder it worked in, an agent it started, a Monitor
may_wait = delegated or bool(task_dirs or monitor_cmds or t3_dirs)
# quoted words are someone else's (a user's "should I ...?", a banned phrase being discussed): not an offer
own = re.sub(r'```.*?```|`[^`\n]*`|"[^"\n]*"|[“„][^”\n]*”|^>[^\n]*$', ' ', last, flags=re.S | re.M)
# An offer, or a hand-back of work the agent can do or wait for itself ("tell me when to re-check CI", "nothing will notify me")
OFFER = (r"(when you say (go|so)|say the word|(do|would) you (want|like) me to|want me to|shall I\b|should I\b|if you want|if you'd (rather|like)|your call|"
         r"is yours to|up to you|or would you rather|which do you (want|prefer)|let me know (if|when|whether)|"
         r"(?:^[\s>*\-•]*|[.!?:;,]\s*|\b(?:or|and|just|please)\s+)(?:tell me (when|to|if|whether)|ask me (to|when|if)|ping me)|nothing (will|would|is going to) (notify|wake|tell) me|(won't|will not|doesn't|does not|can't) (notify|wake) me)\b")
offer = re.search(OFFER, own, re.I | re.M)
if working and not child and offer and 'GENUINE-FORK' not in last:
    print(f"Your last message hands the next step back (\"{offer.group(0)}\"). If it is your own recommendation or in scope, "
          "do it now; if it waits on something (CI, an agent, a reply), arm a Monitor or a background command that wakes you when it lands, "
          "and continue then. Ask only for (a) irreversible actions on shared state you didn't create, (b) money, credentials "
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
# A Running list in the reply is checked against T3 task status: each task it names was launched or read (task_status) after the
# user's last message, and none has a terminal status.
running = re.search(r'^(?:#+ *Running\b|[-*\s]*\*{0,2}Running\*{0,2}:)(.*(?:\n[ \t]*[-*\d].*)*)', last, re.M)  # a `Running:` label or heading
if running and not child:
    titles, status, launched, seen, thread = {}, {}, False, set(), {}  # status: in the order last heard of
    for line in lines:
        try: e = json.loads(line)
        except ValueError: continue
        c = (e.get('message') or {}).get('content') if isinstance(e, dict) else None
        if e.get('type') == 'user' and isinstance(c, str) and not c.startswith('<'):
            # T3's own completion notice and a skill's re-invocation aren't the user: a notice marks its task terminal instead
            # T3's notice is `Delegated task <id> reached a terminal state`, or `Delegated task <id> (<title>) [<status>]:` with its result
            n = re.match(r'Delegated task (\S+) (?:reached a terminal state|\(.*?\) \[(\w+)\]:?)', c)
            # a sub-agent whose turn ends while its own background work runs says so, and T3 continues it later: not finished
            waits = n and re.search(r"\b(?:still running|I'll (?:continue|wait|resume)|I will (?:continue|wait|resume)|I'm waiting|wakes? (?:me )?when)\b", c[n.end():n.end() + 400], re.I)
            if n: status[n.group(1)] = ('waiting' if waits else n.group(2) or 'completed', status.pop(n.group(1), ('', ''))[1])
            elif not c.startswith(('Skill /', 'Stop hook feedback')): seen = set()
        for b in c if isinstance(c, list) else []:
            if b.get('type') == 'tool_use' and re.search(r'(delegate_task|task_status|thread_send)$', b.get('name', '')):
                titles[b['id']] = (b.get('name', '').endswith('task_status'), str((b.get('input') or {}).get('title') or ''))
                launched = launched or not titles[b['id']][0]
            elif b.get('type') == 'tool_result' and b.get('tool_use_id') in titles:
                r = b.get('content'); r = ''.join(x.get('text', '') for x in r) if isinstance(r, list) else str(r or '')
                try: r = json.loads(r)
                except ValueError: continue
                if isinstance(r, dict) and r.get('threadId') and not r.get('taskId'):  # a message sent to a task's thread runs it again
                    r = {'taskId': r['threadId'] + '#sent', 'childThreadId': r['threadId'], 'status': r.get('status') or 'running'}
                if isinstance(r, dict) and r.get('taskId'):
                    is_read, title = titles[b['tool_use_id']]
                    old = status.pop(r['taskId'], ('', ''))
                    status[r['taskId']] = (str(r.get('status') or ''), title or old[1])
                    thread[r['taskId']] = str(r.get('childThreadId') or r.get('threadId') or thread.get(r['taskId']) or r['taskId'])  # a follow-up message is a new task of its thread
                    seen.add(r['taskId'])
    text = running.group(1).lower()
    # a link names a thread, and a list with no link names a thread by a title its tasks hold ("memory refresh" is the refresh just
    # launched). A thread is all its tasks: the first, each message sent to it, each turn T3 continues on its own (provider-continuation).
    # It is finished only when every task of it is; it is current when one of them was heard of since the user's last message.
    def name_of(i):
        m = re.search(r'%25253A([^%]+)%3Aordinal', i)  # a continuation's id holds its thread's, encoded twice
        return (m[1] if m else thread.get(i, i).rsplit('%3A', 1)[-1]).lower()
    threads = {}
    for i in status: threads.setdefault(name_of(i), []).append(i)
    named = [g for n, g in threads.items() if re.search(r'(?:%3a|[^\w-])' + re.escape(n) + r'(?![\w-])', text)]
    if not named:
        for t in {t.lower() for _, t in status.values() if t and t.lower() in text}:
            named.append(threads[name_of([i for i, (_, u) in status.items() if t in u.lower()][-1])])
    label = lambda g: next((status[i][1] for i in g if status[i][1]), g[0])
    done = [label(g) for g in named if all(re.match(r'(completed|failed|cancel+ed|interrupted|error)', status[i][0]) for i in g)]
    stale = [label(g) for g in named if not set(g) & seen]
    if launched and (done or stale):
        print(f"Your Running list names {', '.join(done)}, whose task status is terminal." if done else
              f"Your Running list names {', '.join(stale)}, not read from T3 since the user's last message.", "Read task_status for each agent you list "
              "and list only the ones still working (mergeworthy:writing §Reports to the user).", file=sys.stderr)
        sys.exit(2)
# A message opening with "it's done" names no linked PR or MR that is still a draft or not green (mergeworthy:merging, Ready).
# The opening sentence is about the PRs it links ("#1 is ready for review", while #26 is a draft); one linking none, about all of them
DONE = r"\b(?:(?:is|are|all|work's|it's) (?:done|finished|complete)\b|ready (?:for review|to merge)|kész\b|elkészült|befejeztem)"
# a negation or a condition earlier in the done word's clause: "isn't quite ready", "once it is ready", "amint kész"
NOT_NOW = re.compile(r"\b(?:not|nem|nincs(?:enek)?|\w+n['’]t|once|when|if|until|after|ha|amint|amikor|mihelyt|amíg|\w+-ig)\b", re.I)
# a future or a conditional anywhere in its clause: "it will be ready for review tomorrow", "holnapra kész lesz", "kész lenne"
FUTURE = re.compile(r"\b(?:will|would|\w+['’]ll|going to|tomorrow|later|soon|lesz\w*|lenne\w*|majd|holnap\w*|később|hamarosan)\b", re.I)
# a clause ends at a comma, semicolon or colon, or before a conjunction: "the tests are not flaky | and the work is done"
CLAUSE = re.compile(r"[,;:]|(?=\b(?:and|but|so|és|de|ezért|viszont|majd)\b)", re.I)
LINK = r'https://(github\.com|gitlab\.[\w.]+)/([\w.-]+/[\w./-]+?)(?:/-)?/(?:pull|merge_requests)/(\d+)'
SENTENCE = r'(?<=[.!?])\s+|\n+'
first = re.split(SENTENCE, own.strip())[0]
def is_claim(m):
    before, after = CLAUSE.split(first[:m.start()])[-1], CLAUSE.split(first[m.start():])[0]
    return not NOT_NOW.search(before) and not FUTURE.search(before + after)
if not child and any(map(is_claim, re.finditer(DONE, first, re.I))):
    import subprocess, urllib.parse
    def api(cmd):
        try: return json.loads(subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout or 'null')
        except (OSError, ValueError, subprocess.SubprocessError): return None
    unfinished = []
    for host, path, n in list(dict.fromkeys(re.findall(LINK, first) or re.findall(LINK, last)))[:10]:
        url = f'https://{host}/{path}/{"pull" if host == "github.com" else "-/merge_requests"}/{n}'
        if host == 'github.com':
            pr = api(['gh', 'api', f'repos/{path}/pulls/{n}'])
            if not isinstance(pr, dict):
                unfinished.append(f"{url} (gh couldn't read it)"); continue
            if pr.get('state') != 'open': continue
            runs = api(['gh', 'api', f'repos/{path}/commits/{pr["head"]["sha"]}/check-runs'])
            if not isinstance(runs, dict):
                unfinished.append(f"{url} (gh couldn't read its checks)"); continue
            red = [r.get('name') for r in runs.get('check_runs', []) if r.get('conclusion') not in ('success', 'skipped', 'neutral')]
            why = (['draft'] if pr.get('draft') else []) + ([f"checks not green: {', '.join(red[:3])}"] if red else [])
        else:
            mr = api(['glab', 'api', '--hostname', host, f'projects/{urllib.parse.quote(path, safe="")}/merge_requests/{n}'])
            if not isinstance(mr, dict):
                unfinished.append(f"{url} (glab couldn't read it)"); continue
            if mr.get('state') != 'opened': continue
            ci = (mr.get('head_pipeline') or {}).get('status') or 'no pipeline'
            why = (['draft'] if mr.get('draft') else []) + ([f'pipeline {ci}'] if ci != 'success' else [])
        if why: unfinished.append(f"{url} ({', '.join(why)})")
    if unfinished:
        print("Your message opens by calling the work done, but these PRs/MRs it links aren't: " + '; '.join(unfinished) +
              ". Say what is left on each instead (the converge gates, green CI, ready), and do it (mergeworthy:merging, Ready).", file=sys.stderr)
        sys.exit(2)
# A sentence whose subject is a PR (`#N`, `owner/repo#N`, its URL, `PR #N`, `CI on #N`) and that states its live state (a draft,
# ready, merged, CI green or red) is checked against GitHub now: the PR may have moved since the agent last looked (a maintainer
# marks it ready, CI finishes), and the user acts on what the report says. "My reply to #12 is a draft" has another subject.
REF = r"(?:https://github\.com/(?P<r1>[\w.-]+/[\w.-]+)/pull/(?P<n1>\d+)|(?<![\w/])(?P<r2>[\w.-]+/[\w.-]+)?#(?P<n2>\d+)\b)"
SUBJECT = r"(?:^[\s>*\-•\d.)]*|(?<=[,;:(])\s*|\b(?:and|but|so|now)\s+)(?:(?:the\s+)?PR\s*)?\(?" + REF + \
          r"\)?(?:\s*\([^()\n]{0,80}\))?(?:'s\s+(?:CI|checks?|jobs?)|:\s*(?:CI|checks?|jobs?))?\s+"
STATE = {'a draft': r"(?:is|remains|stays)\s+(?:still\s+|now\s+)?(?:a\s+|in\s+)?draft\b", 'ready for review': r"is\s+(?:now\s+)?(?:ready for review|out of draft|marked ready)\b",
         'merged': r"(?:is|was|got|has been)\s+(?:now\s+)?merged\b", 'green': r"(?:is|are)\s+(?:now\s+|all\s+)?(?:green|passing)\b", 'red': r"(?:is|are)\s+(?:still\s+|now\s+)?(?:red|failing)\b"}
ON = r"\s+(?:on|for|of)\s+(?:PR\s*)?" + REF
CLAIMS = [(c, re.compile(rx, re.I)) for c, rx in [(c, SUBJECT + x) for c, x in STATE.items()] + [
    (c, r"\b(?:CI|checks?)" + ON + r"\s+" + STATE[c]) for c in ('green', 'red')] + [
    (c, r"\b(?:CI|checks?|jobs?)\s+" + STATE[c] + ON) for c in ('green', 'red')] + [('green', r"\ball\s+\d+\s+(?:CI\s+)?(?:checks|jobs)\s+pass(?:ed)?" + ON)]]
# a condition, a plan or a wait is no claim about now
LATER = re.compile(r"\b(?:once|when|after|until|if|before|unless|whether|will|would|waiting|wait|expect|next|tomorrow|soon|later)\b", re.I)
if not child and last.strip():
    import subprocess
    def gh(*a):
        try: r = subprocess.run(['gh', *a], capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.TimeoutExpired) as e: return None, str(e)
        try: return (json.loads(r.stdout or 'null') if r.returncode == 0 else None), r.stderr
        except ValueError: return None, 'unreadable answer'
    def remotes():
        out = []
        for name in ('upstream', 'origin'):
            u = subprocess.run(['git', '-C', d.get('cwd') or '.', 'remote', 'get-url', name], capture_output=True, text=True).stdout.strip()
            if m := re.search(r'github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?$', u): out.append(m[1])
        return out
    url_repos = re.findall(r'github\.com/([\w.-]+/[\w.-]+)/pull/\d+', last)
    states, wrong = {}, []
    for sentence in re.split(SENTENCE, own):
        for claim, m in [(c, m) for c, rx in CLAIMS for m in rx.finditer(sentence) if not re.search(r"\blocal(ly)?\b", sentence, re.I) and not LATER.search(re.split(r'[,;:]', sentence[:m.start()])[-1] + sentence[m.start():])]:
            key = (m['r1'] or m['r2'], m['n1'] or m['n2'])
            if key not in states:
                pr, why = None, ''
                repos = list(dict.fromkeys(([key[0]] if key[0] else []) + url_repos + remotes()))
                for repo in repos:
                    pr, why = gh('api', f'repos/{repo}/pulls/{key[1]}')
                    if pr is not None or 'HTTP 404' not in (why or ''): break
                if pr is None and 'HTTP 404' in (why or '') and any(isinstance(i := gh('api', f'repos/{r}/issues/{key[1]}')[0], dict) and 'pull_request' not in i for r in repos[:1]):
                    states[key] = None  # an issue, not a PR: its state is no PR state
                    continue
                if not isinstance(pr, dict):
                    print(f"Your message states #{key[1]}'s state (\"{sentence.strip()[:120]}\"), and gh couldn't read that PR ({(why or 'no repo to look in').strip()[:120]}). "
                          "Name it by its URL, read its state live (`gh pr view <url> --json isDraft,state,statusCheckRollup`), and say what that shows.", file=sys.stderr)
                    sys.exit(2)
                runs, why = gh('api', f"repos/{pr['base']['repo']['full_name']}/commits/{pr['head']['sha']}/check-runs?per_page=100")
                if not isinstance(runs, dict):
                    print(f"Your message states {pr.get('html_url')}'s state, and gh couldn't read its checks ({(why or '').strip()[:120]}): read them live and say what they show.", file=sys.stderr)
                    sys.exit(2)
                runs = runs.get('check_runs', [])
                states[key] = (pr, [r.get('name') for r in runs if r.get('conclusion') in ('failure', 'timed_out', 'cancelled', 'action_required', 'startup_failure')],
                               [r.get('name') for r in runs if r.get('status') != 'completed'], len(runs))
            if states[key] is None: continue
            pr, red, pending, total = states[key]
            ok = {'a draft': pr.get('draft') and pr.get('state') == 'open', 'ready for review': not pr.get('draft') and pr.get('state') == 'open',
                  'merged': pr.get('merged'), 'green': total and not red and not pending, 'red': bool(red)}[claim]
            if not ok:
                actual = ('merged' if pr.get('merged') else pr.get('state', '?')) + (', a draft' if pr.get('draft') else ', ready for review' if pr.get('state') == 'open' else '') + \
                         f"; checks: {len(red)} failing, {len(pending)} pending, of {total}"
                wrong.append(f"{pr.get('html_url')} is {claim}, you say (\"{sentence.strip()[:100]}\"); GitHub says {actual}")
    if wrong:
        print("Your message states a PR's state that GitHub contradicts now: " + '; '.join(wrong) + ". Re-read it live and say what it shows "
              "(mergeworthy:writing §Evidence for claims); then act on it (a ready PR: the reply loop; red CI: fix it).", file=sys.stderr)
        sys.exit(2)
own_dirs = set(t3_dirs)
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
# A steward pass's round (gh-watch-start --round, mergeworthy:steward) names its session in <dir>/passed: that dir's owed lines hold the
# session's turn as a live watcher's do. It has no daemon, so a post there still needs a live watcher, as any post does
pass_dirs = {wd for wd in ((l.strip() for l in open(reg)) if os.path.exists(reg) else ()) if d.get('session_id') and steward.passed_by(wd) == d['session_id']}
own_dirs |= pass_dirs
if posted and watcher_on and not headless and not paused and not t3_dirs and not (monitors - dead):
    # under T3, a watcher of this session's that dropped its t3-thread (the thread or t3 gone) wakes nothing: its events.log says why
    dropped = [wd for wd in live_dirs if t3_chain and steward.first(os.path.join(wd, 'session')) == d.get('session_id')
               and not os.path.exists(os.path.join(wd, 't3-thread'))]
    if dropped:
        how = (f"The watcher in {dropped[0]} stopped waking this T3 thread (its events.log's WATCH ERROR says why): run "
               f"`gh-watch-start {dropped[0]}` again and arm the Monitor it prints, if any")
    elif t3_chain:
        how = "Run `gh-watch-start <your work folder> <owner/repo> <N>`: its watcher then wakes this T3 thread itself"
    else:
        how = "Run `gh-watch-start <your work folder> <owner/repo> <N>` and arm the Monitor it prints, with the longest timeout; re-arm it whenever it expires"
    print("You posted on GitHub in this session and nothing wakes it on a watcher's events, so replies go unseen: nothing else answers them. "
          + how + " (mergeworthy:reply step 1).", file=sys.stderr)
    sys.exit(2)
# The owed-reply list: the daemon records each human comment in the live watcher's replies-owed.md; a turn
# cannot end with a line still owed.
if watcher_on and not paused and not child:
    for wd in sorted(own_dirs):
        f = os.path.join(wd, 'replies-owed.md')
        owed = [l.strip() for l in open(f) if l.strip() and not l.startswith('#')] if os.path.exists(f) else []
        try:
            os.kill(int(open(os.path.join(wd, 'gh-watch.pid')).read().strip()), 0)
        except (OSError, ValueError):
            if wd not in pass_dirs:  # a dir this session's round passed has no daemon: its owed lines are checked below
                # a retired watcher has nothing left to answer; one that died still owes its lines, and sees no new comment
                if not os.path.exists(os.path.join(wd, 'retired')) and any(not l.lower().startswith('done:') for l in owed):
                    print(f"The watcher in {wd} isn't running and its replies-owed.md still has open lines ({owed[0][:120]}): restart it "
                          f"(`gh-watch-start {wd} <owner/repo>`), arm the Monitor it prints if any, then answer them (mergeworthy:reply).", file=sys.stderr)
                    sys.exit(2)
                continue
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
# The task isn't finished while its scope.md has an open box (task step 10 walks them). A turn ends with one only when something
# this session armed will wake it for the work (a live Monitor, a background command, an agent it launched) or with a
# GENUINE-FORK the user must answer. A session that opened `task` or pushed or posted has a scope.md (task steps 2-3).
if (opened_task or acted) and not child and not paused and not headless:
    import agent_jobs
    folders = set(own_dirs) | task_dirs
    scopes = {f: open(os.path.join(f, 'scope.md'), errors='replace').read() for f in folders if os.path.isfile(os.path.join(f, 'scope.md'))}
    scopes = {f: t for f, t in scopes.items() if re.match(r'\s*Tier:', t)}
    if not scopes:
        print("This session works on a task (it opened mergeworthy:task, or pushed or posted) and no work folder it used has a scope.md "
              "opening with `Tier: <0|S|M|L>, because <signals>`: write ~/.mergeworthy/work/<task>/scope.md, with each ask and its link as "
              "a checkbox (mergeworthy:task steps 2-3), then run the steps it leads to.", file=sys.stderr)
        sys.exit(2)
    open_items = [(f, m) for f, t in sorted(scopes.items()) for m in re.findall(r'^\s*[-*] \[ \] (.+)$', t, re.M)]
    jobs = [j for _, j in agent_jobs.jobs() if j.get('session') == d.get('session_id') and not agent_jobs.finished(j)] if d.get('session_id') else []
    live = [w for w in wakers if w not in dead] + jobs + sorted(t3_dirs)
    if open_items and not live and 'GENUINE-FORK' not in last:
        print(f"{open_items[0][0]}/scope.md still has open items ({'; '.join(m[:80] for _, m in open_items[:3])}) and nothing this session "
              "started will wake it: no live Monitor, background command or agent. Do the next one now. If it waits on something (CI, a review, "
              "an agent), arm a Monitor or a background command that ends when it lands, and continue then. Only what the user alone "
              "can decide ends the turn, as a GENUINE-FORK line (always-on: Every session).", file=sys.stderr)
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
if (not child and may_wait and d.get('session_id') and '/plugins/cache/' in own_root and os.path.isdir(own_root) and os.path.isdir(cur) and os.path.realpath(own_root) != cur
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
if (not child and may_wait and d.get('session_id') and '/plugins/cache/' in own_root and os.path.isdir(own_root) and os.path.isdir(cur)
        and os.path.realpath(own_root) != cur and not os.path.exists(told) and skill_texts(own_root) != skill_texts(cur)):
    os.makedirs(os.path.dirname(told), exist_ok=True); open(told, 'w').close()
    names = ', '.join(sorted(os.path.basename(x) for x in glob.glob(os.path.join(cur, 'skills', '*')) if os.path.isdir(x)))
    print(f"The Skill tool opens this session's older copy of the mergeworthy skills ({own_root}); the installed version ({cur}) "
          f"changed them. Until a restart, after opening a skill, read and follow ~/.mergeworthy/current/skills/<name>/SKILL.md "
          f"and paste briefs from there. Installed skills: {names}. Renamed: core -> task; github-threads -> post and reply; "
          "design-loop -> design; delegating -> delegate and rules; past-failures -> rules; verify, guardian and refactor -> converge; mechanisms -> docs/mechanisms.md; memory-refresh -> delegate/memory-refresh.md.", file=sys.stderr)
    sys.exit(2)
# Before a turn ends, one check-in (not twice in a row: on the stop after a block, stop_hook_active skips it)
# At most once per MERGEWORTHY_STOP_CHECKIN_SECONDS (default 30 min): every extra turn re-reads the whole context from cache
def checkin_due():
    import time
    key = re.sub(r'[^\w-]', '', d.get('session_id') or '') or hashlib.sha256(str(d.get('transcript_path')).encode()).hexdigest()[:16]
    f = os.path.expanduser(f'~/.claude/mergeworthy-stop-checkins/{key}')  # per session (the single file mergeworthy-stop-checkin was shared)
    try:
        last = float(open(f).read().strip())
    except (OSError, ValueError):
        last = 0
    if time.time() - last < float(os.environ.get('MERGEWORTHY_STOP_CHECKIN_SECONDS', '1800')):
        return False
    os.makedirs(os.path.dirname(f), exist_ok=True)
    open(f, 'w').write(str(time.time()))
    return True
if (os.environ.get('MERGEWORTHY_STOP_CHECKIN', 'on') != 'off' and may_wait and not child and not active
        and not re.search(r'^GENUINE-FORK:.*\Z', last.rstrip(), re.M) and checkin_due()):
    print("Before you stop, check once, unless the user asked you to stop or pause: is there work you said is next, or that the "
          "critical path needs, that you could start now? Is anything waiting on you (a reply owed, red CI, a finished agent's result "
          "to read, a dependency that landed)? If so, do it now, or brief a subagent for it. Otherwise end the turn without writing "
          "anything: the user already has your answer.",
          file=sys.stderr)
    sys.exit(2)
sys.exit(0)
