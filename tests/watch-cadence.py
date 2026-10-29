"""Tests of how often the watcher calls GitHub (watcher/gh-watch.py), offline: the stand-in GitHub of watch_sim.py, a simulated clock,
and the real watcher code, on a machine like the user's: seven watch dirs, ~200 threads (70 in one dir, most of them merged), 11 repos.
Every request counts, answers of 304 included. Usage: tests/watch-cadence.py [repo root]
Prints "case: <got> (want <want>)"; exits 0 only when every case matches."""
import collections, contextlib, importlib.util, itertools, json, os, re, shutil, sys, tempfile

R = os.path.realpath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import watch_sim as ws

T = tempfile.mkdtemp()
os.environ.update(HOME=f'{T}/home', GH_WATCH_ME='me')
fails, counter = 0, itertools.count()
STEADY_MAX, LATENCY_MAX = 20, 120  # counted calls a minute on the whole machine; seconds from a new comment on an open thread to its event
ALL = ('conv', 'd1', 'd2', 'd3', 'd4', 'd5', 'd6')
WARM, HOURS = 1, 10  # the first hour is the start-up (every thread is read once); the rate is measured over the rest


def check(name, want, got):
    global fails
    print(f"{name}: {got} (want {want})")
    if want != got:
        fails += 1
        print("  ^ FAIL")


emitted = []  # (simulated time, dir name, line)


def load(name, d, sim, daemon=None):
    """The watcher as the daemon of watch dir d runs it: a fresh module, the sim's clock, events into d/events.log."""
    spec = importlib.util.spec_from_file_location(f'ghc{next(counter)}', f'{R}/watcher/gh-watch.py')
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    m.HERE, m.STATE, m.THREADS = d, f'{d}/gh-watch-state.json', f'{d}/threads.txt'
    m.time, m.datetime = ws.clock_for(sim, daemon)
    def emit(line):
        emitted.append((sim.now, name, line))
        with open(f'{d}/events.log', 'a') as f:
            f.write(line + '\n')
    m.emit = emit
    return m


def machine(extra=None):
    """Seven daemons on the machine for HOURS hours, with three new comments on open threads (latency); -> (gh, dirs, arrivals, errors)."""
    shutil.rmtree(f'{T}/home', ignore_errors=True)
    os.makedirs(f'{T}/home/.claude')
    os.makedirs(f'{T}/home/.mergeworthy')
    emitted.clear()
    sim = ws.Sim()
    gh = ws.FakeGitHub(sim)
    plan, pick = ws.build_machine(gh)
    dirs = {}
    for name, threads in plan.items():
        d = f'{T}/{name}'
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
        open(f'{d}/threads.txt', 'w').write('\n'.join(threads) + '\n')
        open(f'{d}/repos.txt', 'w').close()
        open(f'{d}/events.log', 'w').close()
        open(f'{d}/gh-watch.pid', 'w').write(str(os.getpid()))
        dirs[name] = d
    open(f'{T}/home/.claude/gh-watch-dirs.txt', 'w').write('\n'.join(dirs.values()) + '\n')
    open(f'{T}/home/.mergeworthy/main-watch', 'w').write(dirs['conv'] + '\n')
    arrivals = {}  # name -> (simulated time of the comment, dir, thread key, line the event starts with)
    def comment(label, hour, second, pickfrom, kind, notify):
        d, repo, n = pickfrom
        def f():
            c = gh.comment(repo, n, 'alice', 'Could you look at this?', kind=kind)
            if notify:
                gh.notifications.append({'updated_at': c['created_at'], 'subject': {'url': f'https://api.github.com/repos/{repo}/issues/{n}'}})
            arrivals[label] = (sim.now, d, f'{repo}#{n}', f"### {repo}#{n} {'comment' if kind == 'comment' else 'review-comment'}")
        sim.at(ws.T0 + hour * 3600 + second, f)
    feed_only = [(3, 13), (3, 31), (4, 41), (4, 58), (5, 5), (5, 22), (6, 47), (7, 2)]  # (hour, second): at different places in the minute
    for i, (hour, second) in enumerate(feed_only):
        comment(f"comment on a recently changed open PR, seen only by the issue lists (#{i + 1})", hour, second, pick['recent_pr'][i % 4], 'comment' if i % 2 == 0 else 'review', False)
    comment('comment on an open issue nobody touched for days, with its notification', 8, 27, pick['stale_issue'][0], 'comment', True)
    comment("comment on someone else's open PR, seen only by its repo's issue list", 8, 55, next(p for p in pick['recent_pr'] if p[0] == 'd3'), 'comment', False)
    if extra:
        extra(sim, gh, dirs, pick)
    with ws.Shim(gh):
        for name, d in dirs.items():
            sim.spawn(name, lambda daemon, d=d, name=name: load(name, d, sim, daemon).main())
        sim.run_until(ws.T0 + WARM * 3600)
        gh.mark = len(gh.log)
        sim.run_until(ws.T0 + HOURS * 3600)
        sim.stop_all()
    return gh, dirs, arrivals, sim.errors


def kind_of(path):
    for pat, name in ((r'notifications', 'notifications'), (r'users/me/events', 'your events feed'), (r'^issues$|repos/[^/]+/[^/]+/issues$', 'issue-list feeds'), (r'search/', 'search'),
                      (r'repos/[^/]+/[^/]+/(issues|pulls)/comments$', 'discovery feeds'), (r'commits', 'follow-up commits'), (r'timeline', 'follow-up timelines'), (r'pr checks|graphql', 'graphql'),
                      (r'/reactions|/(issues|pulls)/\d+/comments|/issues/\d+$', 'thread lists, reactions'), (r'/pulls/\d+', 'thread state')):
        if re.search(pat, path):
            return name
    return 'other'


QUICK = bool(os.environ.get('WATCH_CADENCE_QUICK'))  # development only: skip the ten simulated hours
gh, dirs, arrivals, errors = (None, None, {}, []) if QUICK else machine()
if not QUICK:
    steady = gh.log[gh.mark:]
    minutes = (HOURS - WARM) * 60
    rate = len(steady) / minutes
    by_kind = collections.Counter(kind_of(e[2]) for e in steady)
    print(f"measured over {HOURS - WARM} simulated hours after the first: {len(steady)} requests, {sum(1 for e in steady if e[3] == 304)} of them 304 answers, {rate:.1f} a minute; "
          f"first hour {gh.mark}; by kind a minute: " + ', '.join(f"{k} {n / minutes:.1f}" for k, n in by_kind.most_common()))
    check("simulation: no daemon crashed", [], [e[1].strip().splitlines()[-1] for e in errors])
    check(f"seven daemons on this machine in steady state: at most {STEADY_MAX} counted calls a minute, 304 answers included", True, rate <= STEADY_MAX)

    for label, (when, d, key, start) in arrivals.items():
        seen = [t for t, name, line in emitted if name == d and line.startswith(start) and t >= when]
        delay = int(min(seen) - when) if seen else None
        print(f"measured: {label}: {delay} s")
        check(f"a new comment reaches its event within {LATENCY_MAX} s: {label}", True, delay is not None and delay <= LATENCY_MAX)

    # the daemons' own account of their calls (--stats) is the number above
    def counted(dirs):
        total = 0
        for d in dirs.values():
            try:
                st = json.load(open(f'{d}/gh-watch-state.json'))
            except (OSError, ValueError):
                continue
            total += sum(v[0] for v in (st.get('calls') or {}).values())
        return total
    logged = len(gh.log)
    mine = counted(dirs)
    print(f"measured: requests at the stand-in GitHub {logged}, requests the daemons counted in their state files {mine}")
    check("every request is counted in its daemon's state, 304s included (within the last round of calls)", True, logged - 100 <= mine <= logged)


# ---------- the cases below each start from a fresh machine (only the dirs named run; all threads exist at the stand-in GitHub) ----------
@contextlib.contextmanager
def small(names=('d1',), poll=60):
    shutil.rmtree(f'{T}/home', ignore_errors=True)
    os.makedirs(f'{T}/home/.claude')
    os.makedirs(f'{T}/home/.mergeworthy')
    emitted.clear()
    sim = ws.Sim()
    gh = ws.FakeGitHub(sim)
    gh.poll = poll
    plan, pick = ws.build_machine(gh)
    dirs = {}
    for name in names:
        d = f'{T}/{name}'
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
        open(f'{d}/threads.txt', 'w').write('\n'.join(plan[name]) + '\n')
        open(f'{d}/repos.txt', 'w').close()
        open(f'{d}/events.log', 'w').close()
        open(f'{d}/gh-watch.pid', 'w').write(str(os.getpid()))
        dirs[name] = d
    open(f'{T}/home/.claude/gh-watch-dirs.txt', 'w').write('\n'.join(dirs.values()) + '\n')
    open(f'{T}/home/.mergeworthy/main-watch', 'w').write(dirs[names[0]] + '\n')
    with ws.Shim(gh):
        yield sim, gh, dirs, pick


def case(name, want):
    def deco(fn):
        try:
            got = fn()
        except Exception as e:
            got = f"error: {type(e).__name__}: {e}"
        check(name, want, got)
    return deco


def summary(m, state, jobs, now):
    return ', '.join(f"{n} {kind} {mode}" for (kind, mode), n in sorted(collections.Counter((m.thread_kind(state, f"{r}#{n}", now), mode) for r, n, mode, a in jobs).items())) or 'none'


def due_at(seconds):
    """After one full read of d1's 28 threads (2 open PRs changed in the last day, 3 other open PRs, 2 open issues, 21 merged or closed),
    what a round reads `seconds` later."""
    with small() as (sim, gh, dirs, pick):
        m = load('d1', dirs['d1'], sim)
        m.run_scan()
        sim.now += seconds
        state = m.load_state()
        return summary(m, state, m.plan(state, m.read_threads()), sim.now)


@case("cadence: 4 minutes after a full read nothing is due; at 6 minutes the 2 open PRs changed in the last day are checked", "none | 2 recent check")
def _():
    return f"{due_at(240)} | {due_at(360)}"


@case("cadence: after 34 minutes the 5 other open threads are checked too; merged and closed ones are not", "5 open check, 2 recent check")
def _():
    return due_at(34 * 60)


@case("cadence: after an hour the PRs changed in the last day are read in full again (edited comments); the rest is still checked", "5 open check, 2 recent full")
def _():
    return due_at(61 * 60)


@case("cadence: merged and closed threads are checked after 6 hours (24 hours after the last full read they are read in full)", "21 closed check | 21 closed full")
def _():
    return f"{[l for l in due_at(7 * 3600).split(', ') if 'closed' in l][0]} | {[l for l in due_at(25 * 3600).split(', ') if 'closed' in l][0]}"


def thread_of(m, kind):
    """The first thread of d1 of this kind: recent / open (PR), issue, merged."""
    state = m.load_state()
    for line in open(m.THREADS):
        repo, n = line.split()
        key = f"{repo}#{n}"
        k = m.thread_kind(state, key, m.time.time())
        if kind == 'merged' and k == 'closed' and state['prs'].get(key, {}).get('state') == 'merged' or kind == 'recent' and k == 'recent' or kind == 'open-pr' and k == 'open' and key in state['prs'] \
                or kind == 'issue' and k == 'open' and key not in state['prs']:
            return repo, n


@case("a check of a thread nothing happened on costs 2 requests for an open PR (the PR with its validator, and its CI), 1 for an open issue, 1 for a merged PR", "2 1 1")
def _():
    with small() as (sim, gh, dirs, pick):
        m = load('d1', dirs['d1'], sim)
        m.run_scan()
        sim.now += 400
        out = []
        for kind in ('recent', 'issue', 'merged'):
            repo, n = thread_of(m, kind)
            state, mark = m.load_state(), len(gh.log)
            m.scan(state, [(repo, n, 'check', 0)])
            out.append(len(gh.log) - mark)
        return ' '.join(map(str, out))


@case("a check that finds the thread changed (a comment since the last read) reads it in full, and the comment is an event", "True True")
def _():
    with small() as (sim, gh, dirs, pick):
        m = load('d1', dirs['d1'], sim)
        m.run_scan()
        sim.now += 400
        repo, n = thread_of(m, 'recent')
        gh.comment(repo, int(n), 'alice', 'Could you look at this?')
        state = m.load_state()
        m.scan(state, [(repo, n, 'check', 0)])
        return f"{state['sched'][f'{repo}#{n}']['full'] == sim.now} {any(l.startswith(f'### {repo}#{n} comment') for _, _, l in emitted)}"


@case("a 👍 on the agent's comment is reported at the thread's next check, not its next full read, also after an update from a state that read reactions only in full; unchanged comment lists then answer 304", "True 1 0")
def _():
    with small() as (sim, gh, dirs, pick):
        m = load('d1', dirs['d1'], sim)
        repo, n = next(p for p in pick['stale_issue'] if p[0] == 'd1')[1:]
        mine = gh.comment(repo, n, 'me', 'the agent', at=sim.now - 3 * 86400)
        m.GATED_POSTS = f"{dirs['d1']}/gated"
        open(m.GATED_POSTS, 'w').write(m._norm('the agent') + '\n')
        m.run_scan()
        state = m.load_state()
        state.pop('agent_lists')  # the update: the comment lists' validators are kept, nothing says which hold the agent's comments
        json.dump(state, open(m.STATE, 'w'))
        sim.now += 1900  # the open issue's check is due, its full read not for a day
        m.run_scan()
        sim.now += 1900
        mine['reactions'] = {'+1': 1, '-1': 0}
        gh.reactions[mine['id']] = [{'id': 1, 'user': {'login': 'me', 'type': 'User'}, 'content': '+1', 'created_at': ws.iso(sim.now)}]
        m.run_scan()
        state, mark = m.load_state(), len(gh.log)
        sim.now += 1900
        m.run_scan()
        lists = [e for e in gh.log[mark:] if re.search(r'/comments$', e[2])]
        return f"{state['sched'][f'{repo}#{n}']['full'] < sim.now - 5000} {sum(1 for _, _, l in emitted if l.startswith(f'### THUMBS UP {repo}#{n} by me'))} {sum(1 for e in lists if e[3] != 304)}"


@case("activity named by a notification or an issue list is read at once, even on a merged thread that is not due for hours", "[('vikejs/vike', '{n}', 'full')]")
def _():
    with small() as (sim, gh, dirs, pick):
        m = load('d1', dirs['d1'], sim)
        m.run_scan()
        sim.now += 120
        repo, n = thread_of(m, 'merged')
        m.publish({f"{repo}#{n}"})
        state = m.load_state()
        return str([(r, x, mode) for r, x, mode, a in m.plan(state, m.read_threads())]).replace(n, '{n}')


@case("a failed read of a thread is not asked for again in the next rounds (5 minutes)", 28)
def _():
    with small() as (sim, gh, dirs, pick):
        m = load('d1', dirs['d1'], sim)
        asked = []
        def failing(*a, **k):
            asked.append(a[:2])
            raise RuntimeError('boom')
        m.fetch_thread = failing
        for _ in range(6):
            m.tick()
            sim.now += 10
        return len(asked)


@case("the pass limit counts every request, 304 answers too: 3 left, so 3 requests and then the pass is spent", 3)
def _():
    with small() as (sim, gh, dirs, pick):
        m = load('d1', dirs['d1'], sim)
        store, url = {}, 'repos/vikejs/vike/issues/101/comments?per_page=100'
        m.request(url, store=store)
        mark = len(gh.log)
        m._pass['left'] = 3
        try:
            for _ in range(10):
                m.request(url, store=store)
        except m.PassSpent:
            pass
        finally:
            m._pass['left'] = None
        return len(gh.log) - mark


@case("a thread named by a notification whose read fails is not asked for again for 5 minutes, then it is", "1 2")
def _():
    with small() as (sim, gh, dirs, pick):
        m = load('d1', dirs['d1'], sim)
        m.run_scan()
        sim.now += 120
        repo, n = thread_of(m, 'recent')
        asked = []
        def failing(r, num, *a, **k):
            asked.append((r, num))
            raise RuntimeError('boom')
        m.fetch_thread = failing
        m.publish({f"{repo}#{n}"})
        for _ in range(6):
            m.tick()
            sim.now += 10
        first = asked.count((repo, n))
        sim.now += 300
        m.tick()
        return f"{first} {asked.count((repo, n))}"


@case("an update does not lose a comment that arrives, with its notification, after the last read of the old state: it is an event within 2 minutes", 1)
def _():
    with small() as (sim, gh, dirs, pick):
        m = load('d1', dirs['d1'], sim)
        m.run_scan()
        repo, n = thread_of(m, 'recent')
        state = m.load_state()
        for k in ('sched', 'upd'):
            state.pop(k)
        json.dump(state, open(m.STATE, 'w'))
        sim.now += 60
        c = gh.comment(repo, int(n), 'alice', 'Could you look at this?')
        gh.notifications.append({'updated_at': c['created_at'], 'subject': {'url': f'https://api.github.com/repos/{repo}/issues/{n}'}})
        m2 = load('d1', dirs['d1'], sim)
        for _ in range(13):
            m2.tick()
            sim.now += 10
        return sum(1 for _, _, l in emitted if l.startswith(f'### {repo}#{n} comment'))


@case("an issue list with more updates than a page between two polls (50 other issues of yours updated after the watched thread's comment) still names the watched thread: an event within 2 minutes", 1)
def _():
    with small() as (sim, gh, dirs, pick):
        m = load('d1', dirs['d1'], sim)
        for _ in range(3):  # the first rounds read everything and record the list
            m.tick()
            sim.now += 10
        sim.now += 120
        repo, n = thread_of(m, 'recent')
        gh.comment(repo, int(n), 'alice', 'Could you look at this?')
        for i in range(50):
            gh.issues[('vikejs/other', 1000 + i)] = {'number': 1000 + i, 'user': {'login': 'me'}, 'state': 'open', 'body': ''}
            gh.touch('vikejs/other', 1000 + i, ws.iso(sim.now + 1 + i))
        for _ in range(13):
            m.tick()
            sim.now += 10
        return sum(1 for _, _, l in emitted if l.startswith(f'### {repo}#{n} comment'))


@case("a long history whose newest entries all moved (the whole saved page of 50 updated, 2,000 older issues behind it) costs at most 4 requests a poll, not the whole history, and still names the watched thread", "1 True")
def _():
    with small() as (sim, gh, dirs, pick):
        m = load('d1', dirs['d1'], sim)
        for i in range(2000):
            gh.issues[('vikejs/old', 5000 + i)] = {'number': 5000 + i, 'user': {'login': 'me'}, 'state': 'closed', 'body': '', 'updated_at': ws.iso(ws.T0 - 40 * ws.DAY + i)}
        for _ in range(3):
            m.tick()
            sim.now += 10
        sim.now += 120
        repo, n = thread_of(m, 'recent')
        gh.comment(repo, int(n), 'alice', 'Could you look at this?')
        for key in list(m.shared_read()['feeds'][m.OWN_FEED]):
            r, k = key.split('#')
            gh.touch(r, int(k), ws.iso(sim.now + 5))
        mark = len(gh.log)
        for _ in range(13):
            m.tick()
            sim.now += 10
        asked = sum(1 for e in gh.log[mark:] if e[2] == 'issues')
        return f"{sum(1 for _, _, l in emitted if l.startswith(f'### {repo}#{n} comment'))} {asked <= 12}"


@case("an issue list that answers 200 with no issues is a baseline too: an issue of someone else's that appears in it later marks the repo for discovery", True)
def _():
    with small() as (sim, gh, dirs, pick):
        open(f"{dirs['d1']}/repos.txt", 'w').write('vikejs/empty\n')
        m = load('d1', dirs['d1'], sim)
        for _ in range(3):
            m.tick()
            sim.now += 10
        sim.now += 120
        gh.issues[('vikejs/empty', 1)] = {'number': 1, 'user': {'login': 'carol'}, 'state': 'open', 'body': ''}
        gh.touch('vikejs/empty', 1)
        for _ in range(8):
            m.tick()
            sim.now += 10
        return bool(m.shared_read()['dirty'].get('vikejs/empty'))


def polls(poll, names=('d1',), minutes=10):
    """Requests of the notifications, your events feed and your own threads' list in `minutes` minutes of rounds every 10 s of the named daemons."""
    with small(names, poll) as (sim, gh, dirs, pick):
        mods = [load(n, dirs[n], sim) for n in names]
        for _ in range(minutes * 6):
            for m in mods:
                m.tick()
            sim.now += 10
        return ' '.join(str(sum(1 for e in gh.log if e[2] == path)) for path in ('notifications', 'users/me/events', 'issues'))


@case("polling follows X-Poll-Interval: ten minutes of rounds every 10 s, the notifications, your events feed and your threads' list are each requested 10 times at 60 s and 5 times at 120 s", "10 10 10 | 5 5 5")
def _():
    return f"{polls(60)} | {polls(120)}"


@case("seven daemons on one machine poll the notifications, your events feed and your threads' list once per interval together, not once each", "10 10 10")
def _():
    return polls(60, names=ALL)


@case("an update keeps the schedule: a state from before it (every thread read a minute ago, no schedule) reads no thread (no comment list, no CI) in its first rounds", 0)
def _():
    with small() as (sim, gh, dirs, pick):
        m = load('d1', dirs['d1'], sim)
        m.run_scan()
        state = m.load_state()
        for k in ('sched', 'upd'):
            state.pop(k)
        json.dump(state, open(m.STATE, 'w'))
        sim.now += 60
        m2 = load('d1', dirs['d1'], sim)
        mark = len(gh.log)
        for _ in range(6):
            m2.tick()
            sim.now += 10
        return sum(1 for e in gh.log[mark:] if re.search(r'/(issues|pulls)/\d+/(comments|reviews)|pr checks|graphql', e[2]))


@case("the hourly line: gh-watch-stats.log gets one line an hour with the counted requests a minute of the hour, as the stand-in GitHub saw them; --stats prints the same", "True True")
def _():
    with small() as (sim, gh, dirs, pick):
        m = load('d1', dirs['d1'], sim)
        for _ in range(6 * 60 * 2 + 30):  # two hours and a bit of rounds
            m.tick()
            sim.now += 10
        lines = open(f"{dirs['d1']}/gh-watch-stats.log").read().splitlines()
        wrote = m.iso_epoch(lines[-1].split()[0])
        last = float(re.search(r'last hour: ([\d.]+)', lines[-1])[1])
        hour = sum(1 for e in gh.log if (wrote // 60 - 59) * 60 <= e[0] <= wrote) / 60  # the minutes the daemon counts for that line
        return f"{len(lines) >= 1 and abs(last - hour) < .6} {'counted requests a minute in the last hour' in m.stats_text() and 'all watch dirs' in m.stats_text()}"


shutil.rmtree(T, ignore_errors=True)
print(f"failures: {fails}")
sys.exit(1 if fails else 0)
