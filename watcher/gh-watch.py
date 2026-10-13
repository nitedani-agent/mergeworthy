#!/usr/bin/env python3
"""Robust GitHub watch for the tracked threads. One line on stdout per event.

- The comments the agent answers (mergeworthy:github-threads), new or edited, each with an :eyes: reaction: a maintainer's
  (write access) on a thread in threads.txt, the threads the agent opened or posted in; and yours with /ai or /agent, on any thread
  (your events feed; one watch dir gets each, see main_dir). Nothing else.
- Your "/agent ..." comments on threads no watch dir lists, found in the watched repos' recent comments (search as a backup) and sent to one dir (see agent_command): `### AGENT COMMAND`.
- FOLLOW-UP: later commits by others to the lines of your merged PRs, and PRs that reference them (see follow_ups), for 60 days after the merge.
- Machine-wide work (those two) runs in one daemon at a time (shared_pass). Every call goes through request(), which keeps the
  hour's budget (see "The GitHub API budget") and sends ETags; a rate-limit pause prints one WATCH ERROR per daemon.
- Maintainers' commits pushed to a tracked PR, and 👍/👎 from GH_WATCH_EYES on the agent's comments.
- WAIT PING DUE: your account's comment is the last on an open thread, and nobody else in it has replied or acted in any watched thread for WAIT_PING_HOURS (3).
- PR head/state changes (pushes, merges, closes), CI turning red or green on open PRs, and your PR's code (tests excluded) changing by more than ~80 lines since its last refactor pass (REFACTOR STALE).
- How often each thread is read depends on its state (see "How often a thread is read"); the notifications, your events feed
  and the repos' issue lists are polled once per X-Poll-Interval, the repo lists by the one daemon holding the lease for all.
- GitLab threads in threads.txt are read by gl_watch.py (scan_gitlab), into the same events.log and replies-owed.md.
- AGENT DONE: an agent the session launched has finished (hooks/agent_jobs.py), once per finish, until `agent-job done` releases its job.
- Every request is counted, 304 answers too (tally; `gh-watch.py --stats` prints the rate, and once an hour a line goes to gh-watch-stats.log).
State lives in gh-watch-state.json: every seen (id, updated_at) pair, so nothing is skipped or repeated,
and scans overlap by 10 minutes. A failed API call prints WATCH ERROR and that thread's scan position isn't advanced.
"""
import contextlib, datetime, fcntl, hashlib, http.client, json, os, re, subprocess, sys, threading, time, urllib.parse
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))  # a watch dir runs this through a link
import gl_watch
sys.path.insert(1, os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), 'hooks'))
import agent_jobs, shlex

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(HERE, 'gh-watch-state.json')
THREADS = os.path.join(HERE, 'threads.txt')  # one "owner/repo number" per line
ONCE = '--once' in sys.argv  # a manual check: prints events but doesn't consume them or react, so the daemon still logs them
WAIT_PING_HOURS = float(os.environ.get('WAIT_PING_HOURS') or 3)  # mergeworthy:github-threads: a wait ping may follow after this long
EYES_FOR = set(filter(None, os.environ.get('GH_WATCH_EYES', '').split(',')))  # maintainers: their commits on your PRs and 👍/👎 are reported


# ---------- The GitHub API budget ----------
# Every watcher on the machine shares one account's 5,000 calls an hour. All of them go through request() below, and what
# is machine-wide lives in ~/.mergeworthy/shared-watch.json: the rate limit as GitHub last reported it, the pause after a
# rate-limit answer, when each shared job last ran, the follow-up cursors and the commit details already read.
# Machine-wide jobs (shared_pass) run in one daemon at a time, the one holding the lease.

class Budget(Exception):
    """The machine-wide pause is on, or a rate-limit answer just started it. Not reported per call (see announce_pause)."""


class PassSpent(Exception):
    """A shared job used its calls for this pass (PASS_CALLS); it carries over to the next one."""


OK, RESERVE, LOW, PAUSED = range(4)  # level(): how much budget is left
RESERVE_AT, LOW_AT = 1500, 500  # remaining calls: below RESERVE_AT only the daemons' own threads are scanned; below LOW_AT only the notifications fast path
IDLE_DISCOVERY = 1800  # seconds after which a repo's comment feeds (and the search backup) are read although nothing is known to have moved in it
PASS_CALLS, STABLE = 40, 86400  # calls one shared job may make per pass; seconds a polled URL's `since` stays the same, so its ETag still matches
POLL_DEFAULT = 60  # seconds between polls of the notifications, your events feed and the repos' issue lists, unless GitHub's X-Poll-Interval says longer
_pass = {'left': None}


def shared_path(name='shared-watch.json'):
    return os.path.expanduser('~/.mergeworthy/' + name)


def shared_default():
    return {'rate': {}, 'pause_until': 0, 'jobs': {}, 'etags': {}, 'commits': {}, 'followups': {}, 'backlog': {}, 'agent_since': None, 'me': None,
            'poll': POLL_DEFAULT, 'feeds': {}, 'activity': {}, 'dirty': {}, 'disc': {}}


_read, _once_state = {}, {}


def shared_read():
    """The shared state, read without the lock: every write replaces the file whole, so a read sees one version. Don't mutate."""
    if ONCE and _once_state:
        return _once_state
    try:
        st = os.stat(shared_path())
        if _read.get('key') != (st.st_mtime_ns, st.st_size):
            with open(shared_path()) as f:
                _read.update(key=(st.st_mtime_ns, st.st_size), val={**shared_default(), **json.load(f)})
        return _read['val']
    except (OSError, ValueError):
        return shared_default()


def shared_update(fn):
    """Read-modify-write the shared state under its lock, written atomically. A manual --once run changes memory only."""
    if ONCE:
        if not _once_state:
            _once_state.update(json.loads(json.dumps(shared_read())))
        fn(_once_state)
        return
    os.makedirs(os.path.dirname(shared_path()), exist_ok=True)
    with open(shared_path('shared-watch.json.lock'), 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(shared_path()) as f:
                s = {**shared_default(), **json.load(f)}
        except (OSError, ValueError):
            s = shared_default()
        fn(s)
        prune(s['etags'])
        tmp = shared_path() + '.tmp'
        with open(tmp, 'w') as f:
            json.dump(s, f)
        os.replace(tmp, shared_path())


@contextlib.contextmanager
def lease():
    """The machine-wide runner: the daemon holding this lock for a pass runs the shared jobs for every live watch dir; one that
    doesn't get it skips them (it never waits). The kernel drops the lock if the holder dies."""
    os.makedirs(os.path.dirname(shared_path()), exist_ok=True)
    f = open(shared_path('shared-watch.lease'), 'a')
    try:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            yield False
            return
        yield True
    finally:
        f.close()


def level():
    """OK, RESERVE (below RESERVE_AT calls left), LOW (below LOW_AT) or PAUSED, from the rate limits any daemon last saw."""
    s, now, lvl = shared_read(), time.time(), OK
    if s['pause_until'] > now:
        return PAUSED
    for r in s['rate'].values():
        if r['reset'] > now:
            lvl = max(lvl, LOW if r['remaining'] < LOW_AT else RESERVE if r['remaining'] < RESERVE_AT else OK)
    return lvl


_noted = {}


def note_rate(h):
    """Record GitHub's x-ratelimit headers (core and graphql) in the shared state. A write every call would be a lock per
    call, so a change under 25 calls is skipped while the budget is healthy."""
    res = h.get('x-ratelimit-resource')
    if res not in ('core', 'graphql') or 'x-ratelimit-remaining' not in h:
        return
    left, reset = int(h['x-ratelimit-remaining']), int(h['x-ratelimit-reset'])
    last = _noted.get(res)
    if last and last[1] == reset and abs(last[0] - left) < 25 and left >= RESERVE_AT + 100:
        return
    def put(s):
        cur = s['rate'].get(res)
        if not cur or reset > cur['reset'] or (reset == cur['reset'] and left < cur['remaining']):
            s['rate'][res] = {'remaining': left, 'reset': reset}
    shared_update(put)
    _noted[res] = (left, reset)


def pause_until(t):
    shared_update(lambda s: s.__setitem__('pause_until', max(s['pause_until'], t)))


def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def iso_epoch(t):
    return datetime.datetime.strptime(t, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()


def announce_pause(state):
    """One `WATCH ERROR` per pause per daemon, however many calls it stopped."""
    until = shared_read()['pause_until']
    if until > time.time() and state.get('pause_notified') != until:
        state['pause_notified'] = until
        emit(f"WATCH ERROR API budget: paused until {iso(until)}")


def prune(etags, keep=2 * 86400):
    for k in [k for k, v in etags.items() if v['t'] < time.time() - keep]:
        del etags[k]


class Resp:
    def __init__(self, status, headers, body):
        self.status, self.headers, self.body = status, headers, body

    def json(self):
        return json.loads(self.body)

    def next(self):
        m = re.search(r'<([^>]+)>;\s*rel="next"', self.headers.get('link', ''))
        return m and m[1].split('api.github.com/', 1)[-1]


_token, _conn = [None], threading.local()  # kept across calls: a new TLS connection per request makes a round several times slower


def http_get(path, headers):
    """A GET over a kept-alive connection (a `gh` process per poll costs ~50 ms of CPU, and the feeds are polled every 10 s)."""
    for attempt in (0, 1):
        if not _token[0]:
            _token[0] = subprocess.run(['gh', 'auth', 'token'], capture_output=True, text=True).stdout.strip()
        h = {'Authorization': f'Bearer {_token[0]}', 'User-Agent': 'gh-watch', 'Accept': 'application/vnd.github+json', **headers}
        try:
            _conn.c = getattr(_conn, 'c', None) or http.client.HTTPSConnection('api.github.com', timeout=20)
            _conn.c.request('GET', '/' + path, headers=h)
            r = _conn.c.getresponse()
            resp = Resp(r.status, {k.lower(): v for k, v in r.getheaders()}, r.read().decode('utf-8', 'replace'))
        except (http.client.HTTPException, OSError):  # a dropped keep-alive connection: reconnect once
            _conn.c = None
            if attempt:
                raise
            continue
        if resp.status == 401 and not attempt:  # `gh auth login` replaced the token this process had read
            _token[0] = None
            continue
        return resp


def gh_send(method, path, headers, args):
    """`gh api -i`: the status line and headers come first. gh exits 1 on a 304 or an error status and still prints them."""
    argv = ['gh', 'api', '-i', '-X', method] + [x for k, v in headers.items() for x in ('-H', f'{k}: {v}')] + list(args) + [path]
    r = subprocess.run(argv, capture_output=True, text=True)
    if not r.stdout.startswith('HTTP/'):
        raise RuntimeError(f"gh api {path}: {r.stderr.strip()[:200]}")
    head, _, body = r.stdout.partition('\r\n\r\n') if '\r\n\r\n' in r.stdout else r.stdout.partition('\n\n')
    lines = head.splitlines()
    return Resp(int(lines[0].split()[1]), {k.strip().lower(): v.strip() for k, _, v in (l.partition(':') for l in lines[1:])}, body)


def limit_pause(resp):
    """-> when a rate-limit answer (429, or 403 naming a limit) lets calls resume, else None."""
    h = resp.headers
    if resp.status not in (403, 429) or not (resp.status == 429 or h.get('x-ratelimit-remaining') == '0' or 'retry-after' in h or 'rate limit' in resp.body.lower()):
        return None
    if 'retry-after' in h:
        return time.time() + int(h['retry-after'])
    return int(h['x-ratelimit-reset']) if h.get('x-ratelimit-remaining') == '0' else time.time() + 60


_calls, _calls_lock, _poll_seen = {}, threading.Lock(), [POLL_DEFAULT]


def tally(status):
    """Every request counts, a 304 too: observed on 2026-10-09, the account's drain matched ~180 304 answers a minute, not zero.
    Kept per minute until save_state moves it into the daemon's state (`calls`: minute -> [requests, of them 304])."""
    with _calls_lock:
        c = _calls.setdefault(int(time.time() // 60), [0, 0])
        c[0] += 1
        c[1] += status == 304


def note_poll(h):
    """GitHub's X-Poll-Interval (seconds; usually 60) on the notifications and events answers is how often they may be polled."""
    try:
        every = int(h.get('x-poll-interval') or 0)
    except ValueError:
        return
    if every and every != _poll_seen[0]:
        _poll_seen[0] = every
        shared_update(lambda s: s.__setitem__('poll', every))


def poll_interval():
    return max(POLL_DEFAULT, shared_read()['poll'])


def spend():
    if _pass['left'] is not None:
        if _pass['left'] <= 0:
            raise PassSpent()
        _pass['left'] -= 1


def request(path, method='GET', args=(), store=None, pending=None, fresh=False, newest_first=False):
    """The one place the watcher calls GitHub: pause check, rate-limit bookkeeping, conditional requests.
    - store: a dict of validators by path. A request sends If-None-Match for its path; a 304 (counted like any call, see tally)
      comes back as status 304 with no body, for the caller to read as "nothing new since I last read it".
      The new validators go to `pending` if given (the caller commits them once it has used the answer), else straight to store.
      A first page with more pages after it is cached only if the list is newest first: otherwise a change on a later page hides.
    - fresh: send no validators (the caller can't use a 304, e.g. a new PR it has never read).
    - GETs go over the kept-alive connection; the rest through `gh api -i`."""
    if shared_read()['pause_until'] > time.time():
        raise Budget('paused')
    spend()
    seen = store.get(path) if store is not None and not fresh else None
    headers = {'If-None-Match': seen['e']} if seen and seen.get('e') else {'If-Modified-Since': seen['lm']} if seen and seen.get('lm') else {}
    if method == 'GET' and not os.environ.get('GH_HOST'):
        resp = http_get(path, headers)
    else:
        resp = gh_send(method, path, headers, args)
    tally(resp.status)
    note_rate(resp.headers)
    note_poll(resp.headers)
    until = limit_pause(resp)
    if until:
        pause_until(until)
        raise Budget(f"rate limited until {iso(until)}")
    if resp.status == 304:
        return resp
    if resp.status >= 400:
        raise RuntimeError(f"gh api {path}: HTTP {resp.status} {resp.body.strip()[:150]}")
    if store is not None and (resp.headers.get('etag') or resp.headers.get('last-modified')) and (newest_first or not resp.next()):
        (store if pending is None else pending)[path] = {'e': resp.headers.get('etag'), 'lm': resp.headers.get('last-modified'), 't': time.time()}
    return resp


def paged(path, store=None, pending=None, fresh=False, newest_first=False, until=None):
    """Every item of a list. -> [] on a 304. `until(page)`: stop once a page of a newest-first list reaches what was already read."""
    resp = request(path, store=store, pending=pending, fresh=fresh, newest_first=newest_first)
    items = []
    while resp.status != 304:
        page = resp.json()
        items.extend(page if isinstance(page, list) else [page])
        if not resp.next() or (until and page and until(page)):
            break
        resp = request(resp.next())
    return items


def run_gh(argv):
    """A gh command that isn't `gh api` (`gh pr checks` is GraphQL and shows no headers), under the same pause and pass limits."""
    if shared_read()['pause_until'] > time.time():
        raise Budget('paused')
    spend()
    r = subprocess.run(['gh'] + argv, capture_output=True, text=True)
    tally(None)
    if r.returncode and 'rate limit' in r.stderr.lower():
        pause_until(time.time() + 600)
        raise Budget('rate limited')
    return r


def fail(what, e):
    """`WATCH ERROR` for a failed call, except when the pause stopped it: that is announced once (announce_pause)."""
    if not isinstance(e, Budget):
        emit(f"WATCH ERROR {what}: {e}")


def stable_since(since):
    """A polled URL must stay the same for its ETag to match, so `since` is rounded down to the start of its day. The
    answer holds a little more than was asked for; seen/claims drop what was handled."""
    return iso(iso_epoch(since) // STABLE * STABLE)


def login():
    if os.environ.get('GH_WATCH_ME'):
        return os.environ['GH_WATCH_ME']
    token = subprocess.run(['gh', 'auth', 'token'], capture_output=True, text=True).stdout.strip()
    fp, cached = hashlib.sha256(token.encode()).hexdigest()[:12], shared_read()['me'] or {}
    if cached.get('token') == fp:  # read once per account, not on every restart
        return cached['login']
    try:
        name = request('user').json().get('login') or ''
    except Exception:
        return ''
    shared_update(lambda s: s.__setitem__('me', {'token': fp, 'login': name}))
    return name


ME = login()
if not ME:
    sys.exit("WATCH ERROR could not read your login (gh api user); set GH_WATCH_ME")  # else your own comments become events


def load_state():
    try:
        s = json.load(open(STATE))
        s.setdefault('since_by', {})
        s.setdefault('etag', {})
        return s
    except Exception:
        now = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)
        return {'since': now.strftime('%Y-%m-%dT%H:%M:%SZ'), 'seen': {}, 'prs': {}, 'ci': {}, 'is_pr': {}, 'since_by': {}, 'etag': {}}


def flush_calls(s):
    """Move the minutes counted since the last save into the state, and drop what is older than a day."""
    with _calls_lock:
        mine = dict(_calls)
        _calls.clear()
    calls = s.setdefault('calls', {})
    for minute, (n, n304) in mine.items():
        c = calls.setdefault(str(minute), [0, 0])
        c[0] += n
        c[1] += n304
    for k in [k for k in calls if int(k) < time.time() // 60 - 1440]:
        del calls[k]


def rates(calls, minutes):
    """-> (counted requests a minute, of them 304 answers) over the last `minutes` minutes, from a state's `calls`."""
    lo = time.time() // 60 - minutes
    rows = [v for k, v in calls.items() if int(k) > lo]
    return sum(v[0] for v in rows) / minutes, sum(v[1] for v in rows) / minutes


def stats_text():
    """`gh-watch.py --stats`: the counted requests a minute of each live watch dir's daemon and of the machine, read from their state files."""
    out, total = [], 0
    for d in dict.fromkeys(live_dirs() + [HERE]):
        try:
            calls = json.load(open(os.path.join(d, 'gh-watch-state.json'))).get('calls') or {}
        except (OSError, ValueError):
            continue
        hour, slow = rates(calls, 60)
        total += hour
        out.append(f"{d}: {hour:.1f} counted requests a minute in the last hour ({slow:.1f} of them 304 answers), {rates(calls, 1440)[0]:.1f} in the last 24 hours")
    return '\n'.join(out + [f"all watch dirs: {total:.1f} counted requests a minute in the last hour (the limit is 83 a minute)"])


def log_stats(state):
    """Once an hour a line in gh-watch-stats.log (not events.log: it would wake the session), so the rate can be looked at later."""
    now = time.time()
    if 'stats_at' not in state:
        state['stats_at'] = now
    elif now - state['stats_at'] >= 3600:
        state['stats_at'] = now
        flush_calls(state)
        hour, slow = rates(state['calls'], 60)
        if not ONCE:
            with open(os.path.join(HERE, 'gh-watch-stats.log'), 'a') as f:
                f.write(f"{iso(now)} counted requests a minute in the last hour: {hour:.1f} ({slow:.1f} of them 304 answers), in the last 24 hours: {rates(state['calls'], 1440)[0]:.1f}\n")


def save_state(s):
    if ONCE:
        return
    flush_calls(s)
    prune(s.setdefault('etag', {}))
    tmp = STATE + '.tmp'
    json.dump(s, open(tmp, 'w'))
    os.replace(tmp, STATE)


# The agent and the user may post as the same account (ME). The agent posts only gated drafts
# (gate-pass registers each one's hash), so a comment by ME whose text matches no gated post is the user's.
GATED_POSTS = os.path.expanduser(os.environ.get('GATED_POSTS', '~/.claude/gated-posts.txt'))  # written by gate-pass


def _norm(text):
    import hashlib
    return hashlib.sha256((text or '').replace('\r\n', '\n').strip().encode()).hexdigest()


def agent_post_hashes():
    try:
        return set(open(GATED_POSTS).read().split())
    except OSError:
        return set()


MAINTAINER = ('OWNER', 'MEMBER', 'COLLABORATOR')
AI_CALL = re.compile(r'(^|\s)/(ai|agent)\b', re.I)


def answerable(u, body, agent_hashes, kind='comment', own=False):
    """mergeworthy:github-threads. On a thread the agent opened (own), what a person would answer on their own PR:
    every human's comment, and a review bot's inline finding (its summaries ask nothing). On a thread it only posted
    in: a maintainer's comment or the user's. The user's /ai calls elsewhere go through ai_call_elsewhere."""
    if own and kind == 'review-comment' and is_bot(u):
        return True
    if not is_human(u, body, agent_hashes):
        return False
    return own or u.get('login') == ME or u.get('assoc') in MAINTAINER


def is_bot(u):
    return bool(u) and (u.get('type') == 'Bot' or u.get('login', '').endswith('[bot]'))


def is_human(u, body=None, agent_hashes=frozenset()):
    if not u or is_bot(u):
        return False
    if u.get('login') != ME:
        return True
    return _norm(body) not in agent_hashes  # ME: the user's own comment unless it's an agent post


def append_owed(entry, d=None):
    """replies-owed.md (mergeworthy:github-threads): the daemon records each human comment as an owed reply; the session
    clears the line with "done: <reply url> <what changed>" when it is answered. The Stop hook
    blocks a turn while a line is still owed, so an unposted reply cannot end the session unseen."""
    path = os.path.join(d or HERE, 'replies-owed.md')
    owed = open(path).read().splitlines() if os.path.exists(path) else []
    if any(f' {entry.split()[2]} ' in l for l in owed):
        return  # already recorded
    with open(path, 'a') as f:
        if not owed:
            f.write('# replies owed (mergeworthy:github-threads): clear each line with "done: <reply url> <what changed>"\n')
        f.write(entry + '\n')


def handle_comment(state, repo, key, kind, cid, upd, login, url, body, extra='', react=None):
    """An answerable comment (mergeworthy:github-threads): an event, an owed reply and an :eyes: reaction, each once."""
    sk = f"{kind}:{cid}"
    if state['seen'].get(sk) == upd:
        return
    edited = sk in state['seen']
    state['seen'][sk] = upd
    indented = '\n'.join('    ' + l for l in body.splitlines())  # no body line can start with ### and pass as an event
    emit(f"### {key} {kind}{' (edited)' if edited else ''} {cid} by {login} {upd} {extra} {url}\n{indented}\n")
    if edited:
        return
    append_owed(f"{key} {kind} {cid} by {login} {url} — {body.strip().splitlines()[0][:80]}" if body.strip() else f"{key} {kind} {cid} by {login} {url}")
    if re.fullmatch(r"\W*(ok(ay)?|good|great|lgtm|yes|sure|agreed|sounds good|👍|nice)\W*", body.strip().lower()):
        emit(f"### ACK {key} {cid}: an acknowledgement answers your last open proposal in that thread or PR; apply it now (mergeworthy:github-threads)")
    if not ONCE and kind != 'review':  # GitHub has no reactions on a review
        (react or react_eyes)(repo, kind, cid)


def watch_dirs():
    reg = os.path.expanduser('~/.claude/gh-watch-dirs.txt')
    return [l.strip() for l in open(reg)] if os.path.exists(reg) else []


def live(d):
    try:
        os.kill(int(open(os.path.join(d, 'gh-watch.pid')).read().strip()), 0)
        return True
    except (OSError, ValueError):
        return False


def main_dir():
    """The watch dir that gets /ai calls on threads no live watcher watches: ~/.mergeworthy/main-watch
    (gh-watch-start --main) while its watcher runs, else the first live dir in gh-watch-dirs.txt."""
    try:
        m = open(os.path.expanduser('~/.mergeworthy/main-watch')).read().strip()
    except OSError:
        m = ''
    if m and live(m):
        return m
    return next((d for d in watch_dirs() if live(d)), None)


def emit(line):
    print(line, flush=True)  # into events.log, where the session's Monitor delivers it (mergeworthy:github-threads)


def waiting_keys(d=None):
    """waiting-on.txt: "<owner/repo#N> -> <dependent thread>: <what to do>", one per line. Yields (line, "owner/repo#N"):
    the key is the left side's start, so a trailing note such as "(Version Packages, releases #390)" doesn't hide it."""
    path = os.path.join(d or HERE, 'waiting-on.txt')
    if not os.path.exists(path):
        return
    for l in (l.strip() for l in open(path)):
        if not l or l.startswith('#') or l.lower().startswith('done:') or ' -> ' not in l:
            continue
        m = re.match(r'([\w.-]+/[\w.-]+)#(\d+)', l.split(' -> ')[0].strip())  # only a PR key; other waits stay unwatched
        if m:
            yield l, f"{m[1]}#{m[2]}"


def emit_dependents(key):
    for l, k in waiting_keys():
        if k == key:
            emit(f"### DEPENDENT of merged {key}: {l.split(' -> ', 1)[1]}: do it now and post the progress on that PR (mergeworthy:github-threads)")


def emit_tracker_stale(key, ended):
    """umbrella.txt ("owner/repo N"): the program's umbrella issue (methodology 1.2). When a PR merges or closes, its
    checkbox there must be ticked and say how it ended."""
    path = os.path.join(HERE, 'umbrella.txt')
    w = open(path).read().split() if os.path.exists(path) else []
    if len(w) < 2 or f"{w[0]}#{w[1]}" == key:
        return
    try:
        body = request(f"repos/{w[0]}/issues/{w[1]}").json()['body'] or ''
    except Exception as e:
        fail(f"tracker check {key}", e)
        return
    repo, num = key.split('#')
    ref = re.compile(rf'(?<![\w/.-])(?:{re.escape(repo)}#|{"#" if repo == w[0] else "(?!)"}){num}(?!\d)')
    items = [l for l in body.splitlines() if re.match(r'\s*- \[[ x]\] ', l) and ref.search(l)]
    if not items:
        emit(f"### TRACKER STALE {w[0]}#{w[1]}: {key} {ended} and has no checkbox there: add it with its state, through the gate (mergeworthy:core 1.2)")
    elif not any(l.lstrip().startswith('- [x]') and re.search(r'\((merged|closed|released)', l) for l in items):
        emit(f"### TRACKER STALE {w[0]}#{w[1]}: {key} {ended}: tick its checkbox and write '({ended}…)' after it, through the gate (mergeworthy:core 1.2)")


def emit_maintainer_commits(state, repo, key, old, new):
    """A maintainer's commits pushed to a tracked PR: reviewing them was requested ("Review each of my commit as I push them")."""
    try:
        commits = [{'sha': c['sha'][:10], 'login': (c.get('author') or {}).get('login') or '', 'date': c['commit']['committer']['date']} for c in request(f"repos/{repo}/compare/{old}...{new}").json()['commits']]
    except Exception as e:
        fail(f"compare {key} {old}...{new}", e)
        return
    try:  # commits that came from merging the base branch aren't the PR's
        base = request(f"repos/{repo}/pulls/{key.split('#')[1]}").json()['base']['ref']
        on_pr = {c['sha'][:10] for c in request(f"repos/{repo}/compare/{base}...{new}").json()['commits']}
    except Exception as e:
        fail(f"compare {key} base...{new}", e)
        return
    for c in commits:
        if c['sha'] in on_pr:
            note_active(state, {'login': c['login']}, c['date'])
    theirs = [c['sha'] for c in commits if c['login'] in EYES_FOR and c['login'] != ME and c['sha'] in on_pr]
    if theirs:
        emit(f"### MAINTAINER COMMITS {key}: {' '.join(theirs)}: review each one in a table (| Commit | What it does, and the idea behind it | Rating |, one short sentence each; rated N/10 with a short reason next to anything below 10, e.g. 9/10 (Vite's built-ins differ); an emoji only where it's funny; 10/10 only when nothing could be better), as requested (mergeworthy:github-threads)")


def emit_refactor_stale(repo, key, new):
    """Your PR's own commits changed more than ~80 lines since its last refactor pass (`pr-steps refactor`): the ratings
    describe old code. Merges of the base branch, tests and lockfiles don't count: they aren't the PR's code to rate."""
    num = key.split('#')[1]
    try:
        pr = request(f"repos/{repo}/pulls/{num}").json()
        if pr['user']['login'] != ME: return
        commits = [{'sha': c['sha'], 'merge': len(c['parents']) > 1} for c in request(f"repos/{repo}/compare/{pr['base']['ref']}...{new}").json()['commits']]
        rec = os.path.expanduser('~/.claude/pr-steps')
        idx = max((i for i, c in enumerate(commits) if os.path.exists(f"{rec}/{c['sha']}") and any(l.startswith('refactor ') for l in open(f"{rec}/{c['sha']}"))), default=-1)
        since = [c['sha'] for c in commits[idx + 1:] if not c['merge']]
        skip = re.compile(r'\.(spec|test)\.|(^|/)tests?/|(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock)$')
        lines = sum(f['additions'] + f['deletions'] for sha in since for f in (request(f"repos/{repo}/commits/{sha}").json().get('files') or []) if not skip.search(f['filename']))
    except Exception as e:
        fail(f"refactor check {key}", e)
        return
    if lines > 80:
        last = commits[idx]['sha'][:10] if idx >= 0 else 'never'
        emit(f"### REFACTOR STALE {key}: {lines} changed lines since the last refactor pass ({last}): re-run it on the whole PR diff (mergeworthy:refactor), then `pr-steps refactor`")


def read_threads():
    threads = []
    for l in open(THREADS):
        w = l.split('#', 1)[0].split() if not l.lstrip().startswith('#') else []
        if w[:1] and w[0].startswith(gl_watch.HOST):
            continue  # gl_watch reads it
        if len(w) == 2 and w[1].isdigit():
            threads.append(w)
        elif w:
            emit(f"WATCH ERROR threads.txt: bad line {l.strip()!r} (want 'owner/repo number')")
    for _, key in waiting_keys():  # a PR you wait on is watched too, so its merge emits DEPENDENT
        repo, num = key.rsplit('#', 1)
        if [repo, num] not in threads:
            threads.append([repo, num])
    return threads


def scan_reactions(state, threads):
    """A 👍 or 👎 from GH_WATCH_EYES on one of the agent's comments is feedback on that comment (mergeworthy:github-threads)."""
    agent_hashes = agent_post_hashes()
    seen, etags = state.setdefault('reactions', {}), state['etag']  # seen: "<kind>:<id>" -> ["<login>:<content>", ...]
    for repo, num in threads:
        pending, clean = {}, True  # an answer's ETag is kept only once everything in it was handled: a 304 later means "nothing new"
        for kind, path in (('body', 'issues'), ('comment', 'issues'), ('review-comment', 'pulls')):
            if kind == 'review-comment' and state['is_pr'].get(f"{repo}#{num}") is False:
                continue  # an issue has no review comments
            try:
                if kind == 'body':  # the PR or issue description itself
                    comments = paged(f"repos/{repo}/issues/{num}", etags, pending)
                else:
                    comments = paged(f"repos/{repo}/{path}/{num}/comments?per_page=100", etags, pending)
            except Exception as e:
                if path == 'issues':
                    clean = False
                    fail(f"reactions {repo}#{num}", e)
                continue  # an issue has no review comments
            for c in comments:
                counts = c.get('reactions') or {}
                if c['user'].get('login') != ME or _norm(c.get('body')) not in agent_hashes or not (counts.get('+1') or counts.get('-1')):
                    continue
                sk = f"{kind}:{c['id']}"
                try:
                    url = f"repos/{repo}/issues/{num}/reactions" if kind == 'body' else f"repos/{repo}/{path}/comments/{c['id']}/reactions"
                    reactions = paged(f"{url}?per_page=100", etags, pending)
                except Exception as e:
                    clean = False
                    fail(f"reactions {sk}", e)
                    continue
                for r in reactions:
                    who, content = r['user']['login'], r['content']
                    if content not in ('+1', '-1') or who not in EYES_FOR or f"{who}:{content}" in seen.get(sk, []):
                        continue
                    seen.setdefault(sk, []).append(f"{who}:{content}")
                    if content == '-1':
                        emit(f"### THUMBS DOWN {repo}#{num} by {who} on {c['html_url']} (reaction {r['id']}): work out why and fix the rule behind it; if the thread is still on that point, post a new reply with the fix that @-mentions {who}; if it has moved past it or it's resolved, instead edit that comment to add how you'll do better. Leave the 👎 (mergeworthy:github-threads)")
                    else:
                        emit(f"### THUMBS UP {repo}#{num} by {who} on {c['html_url']}: note what they liked and reinforce the rule that produced it (mergeworthy:github-threads)")
        if clean:
            etags.update(pending)


def react_eyes(repo, kind, cid):
    path = f"repos/{repo}/issues/comments/{cid}/reactions" if kind == 'comment' else f"repos/{repo}/pulls/comments/{cid}/reactions"
    try:
        request(path, 'POST', ['-f', 'content=eyes'])
    except Exception as e:
        fail(f"eyes {repo} {kind} {cid}", e)


def fetch_thread(repo, num, since, is_pr_known, author_known, prev_pr, etags, mode='full', upd_known=True):
    """Network only (runs in a worker thread). Returns (is_pr, author, events, pr_state, red, last_comment, validators, full, updated_at):
    validators are the ETags to keep once the caller has used the answers; full says whether the comment lists were read.
    A list that answers 304 has nothing new (comments, reviews), and an unchanged PR keeps its previous state.
    mode 'check' first asks for the PR (or the issue) itself, with its validator: its body shows its comment counts and update time,
    so a 304 means nothing happened in the thread (a comment, review, push, merge or close changes it), and only CI is then asked
    for. Anything else reads the thread in full. updated_at is None while the PR or issue answered 304."""
    is_pr, author, pending, updated = is_pr_known, author_known, {}, None
    full, fresh = mode == 'full', not upd_known  # a thread whose update time isn't known yet can't use a 304
    if is_pr is None or author is None:
        issue = request(f"repos/{repo}/issues/{num}").json()
        is_pr, author, updated, full = 'pull_request' in issue, (issue.get('user') or {}).get('login'), issue.get('updated_at'), True
    pr_state = red = None
    if is_pr:
        resp = request(f"repos/{repo}/pulls/{num}", store=etags, pending=pending, fresh=fresh or not prev_pr)
        if resp.status == 304:
            pr_state = prev_pr
        else:
            pr = resp.json()
            # 'conflict': GitHub runs no CI on a PR that conflicts with its base, so a conflict must be reported like red CI
            pr_state = {'head': pr['head']['sha'][:10], 'state': 'merged' if pr.get('merged') else pr['state'], 'conflict': pr.get('mergeable_state') == 'dirty'}
            updated, full = pr.get('updated_at') or updated, True
        if pr_state['state'] == 'open':
            r = run_gh(['pr', 'checks', num, '-R', repo])
            if r.returncode not in (0, 1, 8) and 'no checks reported' not in r.stderr:  # 1 = some failed, 8 = some pending
                raise RuntimeError(f"gh pr checks {num} -R {repo}: {r.stderr.strip()[:200]}")
            red = sorted(l.split('\t')[0] for l in r.stdout.splitlines() if '\tfail\t' in l)
    elif not full or updated is None:
        resp = request(f"repos/{repo}/issues/{num}", store=etags, pending=pending, fresh=fresh)
        if resp.status != 304:
            updated, full = resp.json().get('updated_at'), True
    events, last = [], None
    if full:
        for c in paged(f"repos/{repo}/issues/{num}/comments?since={stable_since(since)}&per_page=100", etags, pending):
            events.append(('comment', c['id'], c['updated_at'], {**c['user'], 'assoc': c.get('author_association')}, c['html_url'], c.get('body') or '', ''))
        if is_pr:
            for c in paged(f"repos/{repo}/pulls/{num}/comments?since={stable_since(since)}&per_page=100", etags, pending):
                events.append(('review-comment', c['id'], c['updated_at'], {**c['user'], 'assoc': c.get('author_association')}, c['html_url'], c.get('body') or '', f"{c.get('path')}:{c.get('line') or c.get('original_line')}"))
            for r in paged(f"repos/{repo}/pulls/{num}/reviews?per_page=100", etags, pending):
                if (r.get('submitted_at') or '') >= since and (r.get('body') or r.get('state') in ('APPROVED', 'CHANGES_REQUESTED')):
                    events.append(('review', r['id'], r['submitted_at'], {**r['user'], 'assoc': r.get('author_association')}, r['html_url'], r.get('body') or '', r.get('state')))
        if not is_pr or pr_state['state'] == 'open':  # nobody is waiting for a reply on a merged or closed PR
            last = fetch_last_comment(repo, num)
    return is_pr, author, events, pr_state, red, last, pending, full, updated


_F = 'state comments(last:2){nodes{databaseId url createdAt author{login}}} participants(first:100){nodes{login}}'
LAST_COMMENT = ('query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issueOrPullRequest(number:$n){'
                '... on Issue{F} ... on PullRequest{F}}}}').replace('F', _F)


def fetch_last_comment(repo, num):
    """The thread's latest issue or PR conversation comment, the one before it, the people in it and whether it is open: one GraphQL call."""
    o, r = repo.split('/')
    t = request('graphql', 'POST', ['-f', f'query={LAST_COMMENT}', '-f', f'o={o}', '-f', f'r={r}', '-F', f'n={num}']).json()['data']['repository']['issueOrPullRequest']
    nodes = t['comments']['nodes']
    return {'open': t['state'] == 'OPEN', 'last': nodes[-1] if nodes else None, 'prev': nodes[0] if len(nodes) > 1 else None,
            'people': [p['login'] for p in t['participants']['nodes']]}


def note_active(state, user, when):
    """The latest time each person (not you, not a bot) acted in a watched thread: a comment, a review, or commits pushed to a PR."""
    login = user.get('login') or ''
    if login and login != ME and user.get('type') != 'Bot' and not login.endswith('[bot]'):
        active = state.setdefault('active', {})
        active[login] = max(active.get(login, ''), when)


def emit_wait_ping(state, key, last, events):
    """mergeworthy:github-threads, the wait ping: your account's comment is the thread's last, and nobody has replied since
    WAIT_PING_HOURS. Once per comment id; a newer comment by anyone makes a different comment the last, so it starts over.
    Once per wait: when the comment before yours is also yours, yours already nudged them. And never while they're mid-review:
    the hours count from the last time anyone else in the thread acted in any watched thread, if that is later than your comment."""
    login = lambda c: ((c or {}).get('author') or {}).get('login')
    if not last or not last['open'] or login(last['last']) != ME or login(last.get('prev')) == ME:
        return
    c = last['last']
    if any(user.get('login') != ME and upd > c['createdAt'] for _, _, upd, user, *_ in events):
        return  # a review comment or review from someone else, newer than ours (the call above sees only conversation comments)
    active = state.get('active', {})
    quiet = max([c['createdAt']] + [active.get(p, '') for p in last.get('people', []) if p != ME])
    since = lambda t: (datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.strptime(t, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)).total_seconds() / 3600
    hours = since(c['createdAt'])
    done = state.setdefault('wait_ping', {}).setdefault(key, [])
    if since(quiet) < WAIT_PING_HOURS or c['databaseId'] in done:
        return
    done[:] = [c['databaseId']]  # only the latest comment matters
    emit(f"### WAIT PING DUE {key}: no reply for {int(hours)} h since {c['url']}; nudge whoever it waits on with the open question (mergeworthy:github-threads)")
    append_owed(f"{key} wait-ping {c['databaseId']} since {c['url']}: no reply for {int(hours)} h; nudge whoever it waits on")  # the Stop hook holds the turn until it's done


# ---------- How often a thread is read ----------
# A look at a thread is a "check" (its PR or issue and, for an open PR, its CI: one or two requests, 304 answers counted) or a "full"
# read (that, the comment lists, the last comment and the reactions: up to nine). A check that finds the thread changed becomes a
# full read, and so does a notification or an issue-list change (repo_feeds) that names the thread: those are read at once.
CHECK = {'recent': 300, 'open': 1800, 'closed': 21600}  # seconds between looks, by what the thread is now: open and changed in the last day, other open, merged or closed
FULL = {'recent': 3600, 'open': 86400, 'closed': 86400}  # seconds after which a look is a full read anyway (reactions, edited comments: nothing else shows them)
RECENT = 86400


def thread_kind(state, key, now):
    if state['prs'].get(key, {}).get('state') in ('merged', 'closed') or state.get('open', {}).get(key) is False:
        return 'closed'
    upd = state.get('upd', {}).get(key)
    return 'recent' if upd is not None and now - upd < RECENT else 'open'


def spread(key, every):
    """When a thread is next looked at: `every` seconds, give or take a tenth fixed per thread, so threads first read together drift apart."""
    return every * (0.9 + 0.2 * int(hashlib.sha256(key.encode()).hexdigest()[:6], 16) / 0xffffff)


def plan(state, threads, lvl=OK, everything=False):
    """-> [(repo, num, mode, activity)]: what a round reads. A thread never read here is read in full; one whose notification or
    issue-list activity is newer than the last time it was read is read in full; otherwise it is looked at when its turn comes
    (not at all while the budget is LOW). After an update the turn is worked out from the thread's last scan, so nothing is read at once."""
    now, act, sched, out = time.time(), shared_read()['activity'], state.setdefault('sched', {}), []
    for repo, num in threads:
        key = f"{repo}#{num}"
        s, a = sched.get(key), act.get(key, 0)
        if s is None and key in state['since_by']:
            t = iso_epoch(state['since_by'][key])
            s = sched[key] = {'full': t, 'act': 0, 'next': t + spread(key, CHECK[thread_kind(state, key, now)])}  # act 0: what was published since that scan is unread
        if s and now < s.get('retry', 0):
            continue
        if s is None and (lvl <= RESERVE or a) or s and a > s.get('act', 0):
            out.append((repo, num, 'full', a))
        elif s and lvl <= RESERVE and (everything or now >= s['next']):
            out.append((repo, num, 'full' if everything or now - s['full'] >= FULL[thread_kind(state, key, now)] else 'check', a))
    return out


def scan(state, jobs):
    """Read the given (repo, num, mode, activity) jobs in parallel; apply results in this thread. -> (all fine, the (repo, num) read in full)"""
    started = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    def since(key):  # each thread keeps its own position, so one failing thread doesn't hold back the others
        dt = datetime.datetime.strptime(state['since_by'].get(key, state['since']), '%Y-%m-%dT%H:%M:%SZ') - datetime.timedelta(minutes=10)
        return dt.strftime('%Y-%m-%dT%H:%M:%SZ')
    ok, fulls, pings, now = True, [], [], time.time()
    state.setdefault('upd', {})
    sched = state.setdefault('sched', {})
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(fetch_thread, repo, num, since(f"{repo}#{num}"), state['is_pr'].get(f"{repo}#{num}"), state.setdefault('author', {}).get(f"{repo}#{num}"), state['prs'].get(f"{repo}#{num}"),
                          state['etag'], mode, f"{repo}#{num}" in state['upd']): (repo, num, a) for repo, num, mode, a in jobs}
        for fut, (repo, num, a) in futs.items():
            key = f"{repo}#{num}"
            try:
                is_pr, author, events, pr_state, red, last, validators, full, updated = fut.result()
            except Exception as e:
                ok = False
                fail(key, e)
                s = sched.setdefault(key, {'full': 0, 'act': 0})
                s['next'] = s['retry'] = now + 300  # not again at once, whatever names it: a thread GitHub keeps failing would be asked for every round
                continue
            state['etag'].update(validators)
            state['is_pr'][key] = is_pr
            state['author'][key] = author
            if updated:
                state['upd'][key] = iso_epoch(updated)
            if last:
                state.setdefault('open', {})[key] = last['open']
            state['since_by'][key] = started
            if pr_state:
                prev = state['prs'].get(key)
                if prev and prev != pr_state:
                    emit(f"### PR CHANGED {key}: {prev} -> {pr_state}")
                    if pr_state['state'] == 'merged' and prev.get('state') != 'merged':
                        emit_dependents(key)
                    if pr_state['state'] in ('merged', 'closed') and prev.get('state') != pr_state['state']:
                        emit_tracker_stale(key, pr_state['state'])
                    if prev.get('head') != pr_state['head']:
                        emit_maintainer_commits(state, repo, key, prev['head'], pr_state['head'])
                        emit_refactor_stale(repo, key, pr_state['head'])
                state['prs'][key] = pr_state
            if red is not None:
                if red != state['ci'].get(key, []):
                    emit(f"### CI {key}: red={red}: fix it, or if it is not this PR's doing, say why on the PR now with the evidence (mergeworthy:github-threads)" if red else f"### CI {key}: no longer red")
                state['ci'][key] = red
            agent_hashes = agent_post_hashes()  # read after the fetch: a post gated while it ran is the agent's
            for kind, cid, upd, user, url, body, extra in events:
                note_active(state, user, upd)
                if answerable(user, body, agent_hashes, kind, own=author == ME):
                    handle_comment(state, repo, key, kind, cid, upd, user['login'], url, body, extra)
            pings.append((key, last, events))
            s = sched.setdefault(key, {'full': 0})
            s['act'] = a
            if full:
                s['full'] = now
                fulls.append((repo, num))
            s['next'] = now + spread(key, CHECK[thread_kind(state, key, now)])
    for key, last, events in pings:  # after every thread's activity is noted: someone busy in another thread is mid-review
        emit_wait_ping(state, key, last, events)
    state['since'] = started  # only the default for threads added to threads.txt later
    return ok, fulls


def notifications_changed(state):
    """Cheap fast path: a conditional request GitHub answers with 304 (not rate-limited) until something changes.
    Returns None (no change) or the set of changed thread keys ("owner/repo#N")."""
    try:
        resp = request('notifications?all=true&per_page=50', store=state['etag'])
    except Budget:
        raise
    except Exception:
        return None
    if resp.status == 304:
        return None
    body = resp.body
    keys = set()
    prev = state.get('notif_upd', '')
    try:
        for n in json.loads(body):
            if n.get('updated_at', '') <= prev:
                continue
            state['notif_upd'] = max(state.get('notif_upd', ''), n.get('updated_at', ''))
            url = (n.get('subject') or {}).get('url') or ''
            parts = url.split('/repos/')[-1].split('/')
            if len(parts) >= 4:
                keys.add(f"{parts[0]}/{parts[1]}#{parts[3]}")
    except Exception:
        pass
    return keys


def publish(keys):
    """Threads ("owner/repo#N") something happened on, for every daemon on the machine: each reads such a thread at once (see plan)."""
    if not keys:
        return
    now = time.time()
    def put(s):
        for k in keys:
            s['activity'][k] = max(now, s['activity'].get(k, 0) + 0.001)  # strictly rising, so a second event is never mistaken for the first
        for k in [k for k, t in s['activity'].items() if t < now - 2 * 86400]:
            del s['activity'][k]
    shared_update(put)


def poll_account(state, lvl):
    """The notifications and your events feed are the account's, the same for every daemon: the daemon of main_dir polls them once per
    poll interval and publishes the threads they name. (The notifications also tell of comments on closed threads.)"""
    if main_dir() not in (HERE, None) or time.time() - state.get('account_at', 0) < poll_interval():  # no live dir (a daemon started by hand) polls for itself
        return
    state['account_at'] = time.time()
    keys = notifications_changed(state) or set()
    if lvl <= RESERVE:
        keys |= own_events_changed(state)
    publish(keys)


def feed_repos():
    """The repos that need a feed of their own: those with a thread a live watch dir lists that isn't known to be merged or closed and
    isn't yours, and the whole-repo lines of repos.txt. Your own threads are all in one feed (OWN_FEED); a repo of only finished
    threads is reached through the notifications."""
    repos, now = set(), time.time()
    for d in dict.fromkeys(live_dirs() + [HERE]):
        try:
            st = json.load(open(os.path.join(d, 'gh-watch-state.json')))
            st.setdefault('prs', {})
        except (OSError, ValueError):
            st = {'prs': {}}
        repos |= {k.rsplit('#', 1)[0] for k in listed_threads(d) if thread_kind(st, k, now) != 'closed' and st.get('author', {}).get(k) != ME}
        try:
            repos |= github_repo_lines(d)
        except OSError:
            pass
    return repos


OWN_FEED = 'issues?filter=created&state=all&sort=updated&direction=desc&per_page=50'  # every issue and PR you opened, in every repo (50 a page)


FEED_PAGES = 4  # pages one poll of an issue list reads at most; what is behind them is found by the thread's next check


def poll_feed(url, repo_of, watched, size):
    """One issue list, most recently updated first, with its validator. A watched thread whose update time moved since the last poll is
    published as activity, and its repo is marked for discovery (see discover_agent_commands). The first poll of a list only records.
    More pages are read while the page just read still shows moved threads: it ends on one the last poll saw changed, newer than the oldest
    it saw, and FEED_PAGES isn't reached."""
    pending, before = {}, shared_read()['feeds'].get(url)
    key = lambda i: f"{repo_of(i)}#{i['number']}"
    resp = request(url, store=shared_read()['etags'], pending=pending, newest_first=True)
    if resp.status == 304:
        return
    page = items = resp.json()
    oldest, pages = min(before.values()) if before else '', 1
    while resp.next() and pages < FEED_PAGES and page and before and page[-1]['updated_at'] > oldest and before.get(key(page[-1])) != page[-1]['updated_at']:
        resp = request(resp.next())
        page = resp.json()
        items, pages = items + page, pages + 1
    seen = {key(i): i['updated_at'] for i in items}
    moved = set() if before is None else {k for k, u in seen.items() if before.get(k) != u}
    now = time.time()
    def put(s):
        s['feeds'][url] = dict(list(seen.items())[:size])  # one page's worth: the next poll reads back to its oldest
        s['etags'].update(pending)
        s['dirty'].update({k.rsplit('#', 1)[0]: now for k in moved})
    shared_update(put)
    publish(moved & watched)


def repo_feeds():
    """A shared job (shared_pass): once per poll interval for the whole machine, your own threads in all repos (one request) and the
    threads of others you watch, repo by repo. The notifications lag GitHub by 20-30 s and only name threads you are subscribed to;
    these name every watched thread at once, whoever wrote and whatever happened (a comment, a review, a push, a merge)."""
    watched = set().union(*(listed_threads(d) for d in live_dirs() + [HERE]))
    poll_feed(OWN_FEED, lambda i: i['repository']['full_name'], watched, 50)
    for repo in sorted(feed_repos()):
        poll_feed(f"repos/{repo}/issues?state=all&sort=updated&direction=desc&per_page=30", lambda i, repo=repo: repo, watched, 30)


AGENT_CMD = re.compile(r'\s*/agent\b(?:[ \t]+([\w.-]+))?', re.I)  # a comment that starts with /agent, then maybe a watch dir's name
THREAD_REF = re.compile(r'(?<![\w/.-])([\w.-]+/[\w.-]+)#(\d+)|github\.com/([\w.-]+/[\w.-]+)/(?:issues|pull)/(\d+)')
AGENT_CLAIMS = os.path.expanduser('~/.mergeworthy/agent-commands.seen')  # shared by every daemon: each command is emitted once


def live_dirs():
    return [d for d in dict.fromkeys(watch_dirs()) if live(d)]


def github_repo_lines(d):
    """The GitHub whole-repo lines of d's repos.txt."""
    return {r for r in (l.split('#', 1)[0].strip() for l in open(os.path.join(d, 'repos.txt'))) if r and not r.startswith(gl_watch.HOST)}


def listed_threads(d):
    """The threads watch dir d scans: its threads.txt and the PRs its waiting-on.txt waits on."""
    try:
        listed = {f"{w[0]}#{w[1]}" for w in (l.split('#', 1)[0].split() for l in open(os.path.join(d, 'threads.txt'))) if len(w) == 2 and not w[0].startswith(gl_watch.HOST)}
    except OSError:
        listed = set()
    return listed | {key for _, key in waiting_keys(d)}


def thread_links(repo, num):
    """Threads this one links to (its body and comments) or that link to it (GitHub's cross-references)."""
    links = set()
    def read(text):
        links.update(f"{m[1] or m[3]}#{m[2] or m[4]}" for m in THREAD_REF.finditer(text or ''))
    read(request(f"repos/{repo}/issues/{num}").json().get('body'))
    for e in paged(f"repos/{repo}/issues/{num}/timeline?per_page=100"):
        if e.get('event') == 'commented':
            read(e.get('body'))
        elif e.get('event') == 'cross-referenced' and ((e.get('source') or {}).get('issue') or {}).get('number'):
            i = e['source']['issue']
            links.add(f"{i['repository_url'].split('/repos/')[-1]}#{i['number']}")
    links.discard(f"{repo}#{num}")
    return links


def route_agent_command(repo, num, name):
    """-> (watch dir, routed). The dir named `name` (its folder's name); else the dir listing most of the threads this one
    links to or is linked from (a tie goes to main_dir); else main_dir, unrouted."""
    dirs = live_dirs()
    for d in dirs:
        if name and os.path.basename(d.rstrip('/')).lower() == name.lower():
            return d, True
    links = thread_links(repo, num)
    score = {d: len(links & listed_threads(d)) for d in dirs}
    best = max(score.values(), default=0)
    if best:
        top = [d for d in dirs if score[d] == best]
        return (main_dir() if main_dir() in top else top[0]), True
    return main_dir(), False


def claim(sk, record=True):
    """True if no daemon has taken this command yet (and, with record, takes it): the claim file is locked, so two daemons can't both."""
    os.makedirs(os.path.dirname(AGENT_CLAIMS), exist_ok=True)
    with open(AGENT_CLAIMS, 'a+') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.seek(0)
        if sk in f.read().split():
            return False
        if record:
            f.write(sk + '\n')
        return True


def agent_command(repo, num, kind, c):
    """Your comment starting with /agent on a thread no live watch dir lists (a listed thread's own scan reports it) goes to
    one dir's events.log, once: `/agent <name>` to the dir of that name, else the dir that lists a thread this one links to
    or is linked from, else main_dir (UNROUTED). You and the agent post as one account: a gated post is not a command."""
    key, body, cid = f"{repo}#{num}", c.get('body') or '', c.get('id')
    sk = f"{kind}:{cid}"
    if not cid or not AGENT_CMD.match(body) or (c.get('user') or {}).get('login', ME) != ME or _norm(body) in agent_post_hashes() \
            or any(key in listed_threads(d) for d in live_dirs()) or not claim(sk, record=False):
        return
    target, routed = route_agent_command(repo, num, AGENT_CMD.match(body)[1])
    upd, url = c.get('updated_at') or c.get('created_at', ''), c.get('html_url', '')
    indented = '\n'.join('    ' + l for l in body.splitlines())  # no body line can start with ### and pass as an event
    event = f"### {'AGENT COMMAND' if routed else 'UNROUTED /agent'} {key} {kind} {cid} by {ME} {upd}  {url}\n{indented}\n"
    if ONCE:
        return emit(event)
    if not target or not claim(sk):
        return
    line = key.replace('#', ' ')
    if routed and line not in open(os.path.join(target, 'threads.txt')).read().splitlines():
        open(os.path.join(target, 'threads.txt'), 'a').write(line + '\n')  # its follow-ups are watched
    append_owed(f"{key} {kind} {cid} by {ME} {url} — {body.strip().splitlines()[0][:80]}", target)
    react_eyes(repo, kind, cid)
    with open(os.path.join(target, 'events.log'), 'a') as f:  # last: the event wakes that session, which finds the rest in place
        f.write(event)


def watched_repos():
    """Every repo a live watch dir lists a thread or a whole-repo line for (and this dir's own)."""
    repos = set()
    for d in dict.fromkeys(live_dirs() + [HERE]):
        repos |= {t.rsplit('#', 1)[0] for t in listed_threads(d)}
        try:
            repos |= github_repo_lines(d)
        except OSError:
            pass
    return repos


def discover_agent_commands():
    """Your /agent comments on threads no watcher lists reach no one: you comment as the agent's own account, which GitHub
    doesn't notify you of, and the search and events indexes lag by many minutes. So each pass lists the recent issue
    and review comments of every watched repo (the comments feeds are live) and hands each /agent comment to agent_command.
    A repo is read when repo_feeds saw something move in it, else every IDLE_DISCOVERY seconds (a thread of someone else's that
    you don't watch doesn't show in the feeds). A search of the threads you commented on, minus those repos, backs it up for repos no
    one lists. A feed is read with its ETag, newest first, only back to where the last read of that repo stopped. A failed call leaves
    the position, so it is retried."""
    started = iso(time.time())
    first = iso_epoch(shared_read()['agent_since'] or iso(time.time() - 3600))
    etags, ok = shared_read()['etags'], True
    repos, dirty, disc = watched_repos(), shared_read()['dirty'], shared_read()['disc']
    for repo in sorted(repos):
        if dirty.get(repo, 0) <= disc.get(repo, 0) and time.time() - disc.get(repo, 0) < IDLE_DISCOVERY:
            continue
        since = iso((disc.get(repo) or first) - 600)  # reads overlap by 10 minutes
        day, pending = stable_since(since), {}
        old = lambda page: page[-1].get('updated_at', '') < since
        try:
            for kind, path in (('comment', 'issues'), ('review-comment', 'pulls')):
                for c in paged(f"repos/{repo}/{path}/comments?since={day}&sort=updated&direction=desc&per_page=100", etags, pending, newest_first=True, until=old):
                    agent_command(repo, (c.get('issue_url') or c.get('pull_request_url') or '').rsplit('/', 1)[-1], kind, c)
            shared_update(lambda s: (s['etags'].update(pending), s['disc'].__setitem__(repo, iso_epoch(started))))
        except (Budget, PassSpent):
            raise
        except Exception as e:
            ok = False
            fail(f"agent commands {repo}", e)
    if time.time() - disc.get('search', 0) >= IDLE_DISCOVERY:
        since = iso((disc.get('search') or first) - 600)
        day = stable_since(since)
        try:
            pending = {}
            query = urllib.parse.quote(f'commenter:{ME} updated:>={day}', safe='')
            found = request(f"search/issues?q={query}&sort=updated&order=desc&per_page=50", store=etags, pending=pending, newest_first=True)
            for i in ([] if found.status == 304 else found.json()['items']):
                repo, num = i['repository_url'].split('/repos/')[-1], i['number']
                if repo in repos:
                    continue
                try:
                    found = [('comment', c) for c in paged(f"repos/{repo}/issues/{num}/comments?since={day}&per_page=100", etags, pending)]
                    if 'pull_request' in i:
                        found += [('review-comment', c) for c in paged(f"repos/{repo}/pulls/{num}/comments?since={day}&per_page=100", etags, pending)]
                    for kind, c in found:
                        agent_command(repo, num, kind, c)
                except (Budget, PassSpent):
                    raise
                except Exception as e:
                    ok = False
                    fail(f"agent commands {repo}#{num}", e)
            if ok:
                shared_update(lambda s: (s['etags'].update(pending), s['disc'].__setitem__('search', iso_epoch(started))))
        except (Budget, PassSpent):
            raise
        except Exception as e:
            ok = False
            fail("agent command search", e)
    if ok:
        shared_update(lambda s: s.__setitem__('agent_since', started))


def ai_call_elsewhere(state, repo, num, etype, c):
    """Your /ai or /agent comment on a thread no live watcher watches goes to main_dir's watcher, so one session gets it."""
    key, body = f"{repo}#{num}", c.get('body') or ''
    if not c.get('id') or not AI_CALL.search(body) or _norm(body) in agent_post_hashes():
        return
    if AGENT_CMD.match(body):  # routed to the right dir, from any daemon
        kind = 'review-comment' if etype == 'PullRequestReviewCommentEvent' else 'comment'
        try:
            agent_command(repo, num, kind, {**c, 'user': c.get('user') or {'login': ME}})
        except Exception as e:
            emit(f"WATCH ERROR agent command {key}: {e}")
        return
    if main_dir() != HERE:
        return
    watched = any(f"{repo} {num}" in (l.strip() for l in open(os.path.join(d, 'threads.txt')))
                  for d in watch_dirs() if live(d) and os.path.exists(os.path.join(d, 'threads.txt')))
    if not watched:  # a watched thread's own scan handles it
        kind = 'review-comment' if etype == 'PullRequestReviewCommentEvent' else 'comment'
        handle_comment(state, repo, key, kind, c['id'], c.get('updated_at') or c.get('created_at', ''), ME, c.get('html_url', ''), body)


def own_events_changed(state):
    """GitHub doesn't notify you of your own comments, so the notifications fast path misses the user's (same account).
    Their public events feed, polled with If-None-Match (a 304 isn't rate-limited), catches them.
    Returns the set of thread keys ("owner/repo#N") with new comments or reviews."""
    try:
        resp = request(f'users/{ME}/events?per_page=30', store=state['etag'])
    except Budget:
        raise
    except Exception:
        return set()
    if resp.status == 304:
        return set()
    body = resp.body
    keys = set()
    prev = state.get('events_seen', '')
    try:
        for e in json.loads(body):
            if e.get('created_at', '') <= prev or e.get('type') not in ('IssueCommentEvent', 'PullRequestReviewCommentEvent', 'PullRequestReviewEvent'):
                continue
            p = e.get('payload') or {}
            num = (p.get('issue') or p.get('pull_request') or {}).get('number')
            if num:
                keys.add(f"{e['repo']['name']}#{num}")
                ai_call_elsewhere(state, e['repo']['name'], num, e['type'], p.get('comment') or {})
        state['events_seen'] = max([prev] + [e.get('created_at', '') for e in json.loads(body)])
    except Exception:
        pass
    return keys


FOLLOWUP_DAYS, SLACK = 60, 3  # how long a merged PR is followed; lines of slack around its lines
LOCKFILES = ('pnpm-lock.yaml', 'package-lock.json', 'yarn.lock')
# a package.json line that only gives a dependency (or the package) a version: "name": "<alias target, workspace: or nothing><version>"; in a lockfile, semver numbers and integrity hashes
DEP_LINE = re.compile(r'^\s*"([^"]+)":\s*"((?:npm:.+@|workspace:)?)(?:[\^~<>=v ]*\d[^"]*|\*|latest)"(,?)\s*$')
SEMVER = re.compile(r'\d+\.\d+\.\d+[\w.+-]*|(?:sha\d+|md5)-[\w+/=]+|\b[0-9a-f]{40}\b')


def version_only(base, lines):
    """A hunk of package.json or a lockfile whose removed lines equal its added lines once versions are blanked: a dependency
    bump, which says nothing about your PR's lines (the dependency PRs of the repo are the noise in a follow-up report)."""
    if base != 'package.json' and base not in LOCKFILES:
        return False
    def norm(l):
        m = DEP_LINE.match(l[1:])
        return f'"{m[1]}":"{m[2]}"{m[3]}' if m else SEMVER.sub('V', l[1:]).strip()
    return sorted(norm(l) for l in lines if l[0] == '-') == sorted(norm(l) for l in lines if l[0] == '+')


def patch_lines(patch, path=''):
    """-> (old-side, new-side) line numbers a unified-diff patch changes; a pure insertion or deletion counts at its position.
    Hunks that only bump dependency versions (version_only) are left out."""
    old, new = [], []
    for hunk in re.split(r'(?m)^(?=@@)', patch or ''):
        lines = hunk.splitlines()
        if not lines or not lines[0].startswith('@@') or version_only(path.rsplit('/', 1)[-1], [l for l in lines[1:] if l[:1] in ('+', '-')]):
            continue
        m = re.match(r'@@ -(\d+)(?:,\d+)? \+(\d+)', lines[0])
        o, n = int(m[1]), int(m[2])
        for l in lines[1:]:
            if l.startswith('-'):
                old.append(o); new.append(n); o += 1
            elif l.startswith('+'):
                old.append(o); new.append(n); n += 1
            elif not l.startswith('\\'):
                o += 1; n += 1
    return old, new


def spans(nums):
    out = []
    for x in sorted(set(nums)):
        if out and x <= out[-1][1] + 1:
            out[-1][1] = x
        else:
            out.append([x, x])
    return out


def follow_record(key):
    """A merged PR of yours: its merge commit and the lines it changed, to compare later commits against."""
    repo, num = key.rsplit('#', 1)
    pr = request(f"repos/{repo}/pulls/{num}").json()
    files = {f['filename']: spans(patch_lines(f['patch'])[1]) if f.get('patch') else [[1, 10**9]]  # no patch: the whole file
             for f in paged(f"repos/{repo}/pulls/{num}/files?per_page=100") if f.get('status') != 'removed'}
    until = iso_epoch(pr['merged_at']) + FOLLOWUP_DAYS * 86400
    return {'merge_sha': pr['merge_commit_sha'], 'base': pr['base']['ref'], 'merged': pr['merged_at'], 'scanned': pr['merged_at'], 'checked': 0,
            'until': until, 'files': files if until > time.time() else {}}


def summarize(files):
    """What a commit did to each file, small enough to keep for good: the old-side line spans it changed, or None when
    GitHub shows no patch. A file that changed no line that counts (a dependency bump) is left out."""
    out = []
    for f in files:
        base = f['filename'].rsplit('/', 1)[-1]
        if f.get('status') == 'modified' and not f.get('patch') and base in LOCKFILES:
            continue  # a lockfile too large for GitHub to show: a dependency change, not your lines
        e = {'f': f['filename'], 's': f.get('status'), 'o': spans(patch_lines(f['patch'], f['filename'])[0]) if f.get('patch') else None}
        if f.get('previous_filename'):
            e['p'] = f['previous_filename']
        if e['o'] != [] or e['s'] in ('removed', 'renamed') or e.get('p'):
            out.append(e)
    return out


def touches(e, files):
    """Does a commit's summary (see summarize) change lines of the PR (within SLACK lines), or rename or remove one of its files? A rename is followed."""
    hit, renames = False, []
    for f in files:
        old = f.get('p') or f['f']
        ranges = e['files'].get(old)
        if ranges is None:
            continue
        if old != f['f']:
            renames.append((old, f['f']))
        if old != f['f'] or f['s'] == 'removed' or f['o'] is None:
            hit = True
        else:
            hit = hit or any(a <= hi + SLACK and b >= lo - SLACK for a, b in f['o'] for lo, hi in ranges)
    for old, new in renames:
        e['files'][new] = e['files'].pop(old)
    return hit


def commit_files(repo, sha):
    """A commit's summary, read from GitHub once ever: the answer is the same every time, so it is kept in the shared state."""
    k = f"{repo}@{sha}"
    if k not in shared_read()['commits']:
        files = summarize(request(f"repos/{repo}/commits/{sha}").json().get('files') or [])
        shared_update(lambda s: s['commits'].__setitem__(k, files))
    return shared_read()['commits'][k]


def emit_to(d, line):
    """An event for the session that owns watch dir d: its events.log, which that dir's daemon also writes to."""
    if ONCE:
        return emit(line)
    with open(os.path.join(d, 'events.log'), 'a') as f:
        f.write(line + '\n')


def follow_emit(sk, dirs, line):
    if claim(sk, record=not ONCE):  # once across restarts and daemons; a manual --once check records nothing
        for d in dirs:
            emit_to(d, line)


def followed_prs():
    """-> {key: [watch dirs]}: your merged PRs in the threads of every live watch dir (and this one)."""
    out = {}
    for d in dict.fromkeys(live_dirs() + [HERE]):
        try:
            st = json.load(open(os.path.join(d, 'gh-watch-state.json')))
        except (OSError, ValueError):
            continue
        for key in listed_threads(d):
            if st.get('prs', {}).get(key, {}).get('state') == 'merged' and st.get('author', {}).get(key) == ME:
                out.setdefault(key, []).append(d)
                old = st.get('followups', {}).get(key)  # kept by a watcher from before the shared state: its cursors save the backfill
                if old and key not in shared_read()['followups']:
                    old.setdefault('merged', iso(old['until'] - FOLLOWUP_DAYS * 86400))
                    shared_update(lambda s: s['followups'].setdefault(key, old))
    return out


def follow_ups():
    """After a PR of yours merges, later commits to its lines by others and PRs that reference it are a review you didn't get
    (mergeworthy:core, Learning from follow-ups). A shared job (shared_pass): each merged PR of yours in any live watch dir is
    followed for FOLLOWUP_DAYS. `### FOLLOW-UP` goes once, to the dirs that list the PR, per commit (not yours, not a bot's,
    not a merge) that touches its recorded lines, and once per other person's PR that references it.
    The commits of a repo are listed once per pass, newest first and with an ETag, and read oldest first, so a pass that
    runs out of calls (PASS_CALLS) resumes where it stopped, a list of more pages than a pass included (the backlog in the shared state);
    PRs not checked for longest go first."""
    prs, now = followed_prs(), time.time()
    fu = shared_read()['followups']
    for key in sorted(prs.keys() - fu.keys()):
        try:
            record = follow_record(key)
        except (Budget, PassSpent):
            raise
        except Exception as e:
            fail(f"follow-up record {key}", e)
            continue
        shared_update(lambda s: s['followups'].__setitem__(key, record))
    fu = shared_read()['followups']
    groups = {}
    for key in sorted((k for k in prs if k in fu and fu[k]['until'] > now), key=lambda k: fu[k]['checked']):
        groups.setdefault((key.rsplit('#', 1)[0], fu[key]['base']), []).append(key)
    for k in prs:
        if k in fu and fu[k]['until'] <= now and fu[k]['files']:
            shared_update(lambda s: s['followups'][k].update(files={}))  # past the window: kept as a marker so the PR isn't recorded again
    for (repo, base), keys in groups.items():
        entries = {k: json.loads(json.dumps(fu[k])) for k in keys}  # worked on here, written back when the group is done or stops
        gk, pending, done = f"{repo}@{base}", {}, False
        floor, since = min(e['scanned'] for e in entries.values()), min(e['merged'] for e in entries.values())
        url = f"repos/{repo}/commits?sha={base}&since={since}&per_page=100"
        bk = shared_read()['backlog'].get(gk)  # a commit list longer than a pass, kept page by page: this pass continues it
        if not bk or bk['since'] > since or bk['floor'] > floor:
            bk = {'since': since, 'floor': floor, 'started': iso(now - 600), 'next': url, 'queue': [],  # overlap: claims dedupe
                  'fresh': any(e['checked'] == 0 for e in entries.values())}  # a PR never read can't use a 304 for a list others have read
        try:
            while bk['next']:  # newest first, down to what was already read
                first = bk['next'] == url
                resp = request(bk['next'], store=shared_read()['etags'] if first else None, pending=pending if first else None, fresh=bk['fresh'], newest_first=True)
                page = [] if resp.status == 304 else resp.json()
                bk['queue'] += [{'sha': c['sha'], 'html_url': c['html_url'], 'parents': [0] * len(c.get('parents') or []), 'author': c.get('author') and {k: c['author'].get(k) for k in ('login', 'type')},
                                 'commit': {'committer': {'date': c['commit']['committer']['date']}, 'author': {k: c['commit']['author'].get(k) for k in ('name', 'email')}}} for c in page]
                bk['next'] = None if not page or not resp.next() or page[-1]['commit']['committer']['date'] < bk['floor'] else resp.next()
            while bk['queue']:  # oldest first
                c = bk['queue'][-1]
                sha, author, when = c['sha'], c.get('author') or {}, c['commit']['committer']['date']
                who = author.get('login') or c['commit']['author'].get('name')  # no GitHub account is linked to the commit's email: its git name
                mine = author.get('login') == ME or re.fullmatch(rf"(\d+\+)?{re.escape(ME)}@users\.noreply\.github\.com", c['commit']['author'].get('email') or '', re.I)
                if not is_bot({**author, 'login': who}) and not mine and len(c.get('parents') or []) <= 1:
                    wanted = [k for k, e in entries.items() if when >= e['scanned'] and sha != e['merge_sha'] and claim(f"followup:{k}:{sha}", record=False)]
                    if wanted:
                        files = commit_files(repo, sha)
                        for k in wanted:
                            if touches(entries[k], files):
                                follow_emit(f"followup:{k}:{sha}", prs[k], f"### FOLLOW-UP {k}: {sha[:10]} by {who} changes lines from your PR  {c['html_url']}")
                for e in entries.values():
                    e['scanned'] = max(e['scanned'], when)
                bk['queue'].pop()
            for k, e in entries.items():
                tpending = {}
                for t in paged(f"repos/{repo}/issues/{k.rsplit('#', 1)[1]}/timeline?per_page=100", shared_read()['etags'], tpending, fresh=bk['fresh']):
                    i = (t.get('source') or {}).get('issue') or {}
                    if t.get('event') == 'cross-referenced' and 'pull_request' in i and not is_bot(i.get('user')) and (i.get('user') or {}).get('login') != ME:
                        follow_emit(f"followup-ref:{k}:{i['html_url']}", prs[k], f"### FOLLOW-UP {k}: {i['html_url']} by {i['user']['login']} references your PR")
                pending.update(tpending)
                e['scanned'] = bk['started']
            done = True
        except (Budget, PassSpent):
            raise
        except Exception as ex:
            fail(f"follow-up {repo}", ex)
        finally:
            for e in entries.values():
                e['checked'] = now  # done or not, the group goes to the back of the line: a long backlog doesn't hold up the other repos
            shared_update(lambda s: (s['followups'].update(entries), s['etags'].update(pending if done else {}), s['backlog'].pop(gk, None) if done else s['backlog'].__setitem__(gk, bk)))


def locked():
    """One scan at a time across processes (daemon and manual runs), so state updates aren't lost."""
    f = open(STATE + '.lock', 'w')
    fcntl.flock(f, fcntl.LOCK_EX)
    return f


def run_scan(everything=False):
    """Read what is due now (everything: every listed thread, in full); the reactions of what was read in full."""
    with locked():
        state = load_state()
        ok, fulls = scan(state, plan(state, read_threads(), OK, everything))
        save_state(state)
    read_reactions(fulls)


def read_reactions(fulls):
    if fulls:
        with locked():
            state = load_state()
            scan_reactions(state, fulls)
            save_state(state)


JOBS = (('feeds', poll_interval, repo_feeds), ('discovery', 300, discover_agent_commands), ('followups', 1800, follow_ups))  # machine-wide work: name, seconds between passes (or a function of it), job
RESERVE_JOBS = ('feeds',)  # the jobs that run below RESERVE_AT calls left too: they are what names the threads to read


def shared_pass(force=False):
    """The machine-wide jobs, for every live watch dir, by the one daemon that holds the lease; the others skip them. Each job
    is due every so many seconds across all daemons (its last_run is in the shared state, so a restart doesn't make it due
    again), makes at most PASS_CALLS calls per pass, and runs only while the budget is healthy."""
    if level() > RESERVE and not force:
        return
    with lease() as mine:
        if not mine:
            return
        for name, every, job in JOBS:
            if level() > (RESERVE if name in RESERVE_JOBS else OK) and not force:
                continue
            if not force and time.time() - (shared_read()['jobs'].get(name) or {}).get('last_run', 0) < (every() if callable(every) else every):
                continue
            shared_update(lambda s: s['jobs'].__setitem__(name, {'last_run': time.time()}))  # at the start: a failing job waits its turn too
            _pass['left'] = PASS_CALLS
            try:
                job()
            except PassSpent:
                pass  # the rest waits for the next pass
            except Budget:
                return
            except Exception as e:
                fail(name, e)
            finally:
                _pass['left'] = None


def retire_if_done():
    """A watcher whose every thread is merged or closed (and that covers no whole repo) has nothing left to watch: it
    disables its service, so it doesn't come back after a reboot, or stops its daemon."""
    repos = os.path.join(HERE, 'repos.txt')
    if os.path.exists(repos) and open(repos).read().strip():
        return
    threads, gl = read_threads(), gl_watch.threads(THREADS)
    if not threads and not gl:
        return
    with locked():
        state = load_state()
    if not all(gl_watch.done(state, key) for key, *_ in gl):
        return
    fu = shared_read()['followups']  # a merged PR of yours still being followed, or not yet recorded by the shared job, keeps the watcher
    if any(state['prs'].get(k, {}).get('state') == 'merged' and state.get('author', {}).get(k) == ME and fu.get(k, {'until': float('inf')})['until'] > time.time()
           for k in (f"{r}#{n}" for r, n in threads)):
        return
    prs = state['prs']
    for repo, num in threads:
        key = f"{repo}#{num}"
        if key in prs:
            done = prs[key].get('state') in ('merged', 'closed')
        elif key in state.get('open', {}):  # an issue: as the last scan found it
            done = not state['open'][key]
        else:
            try:
                done = request(f"repos/{repo}/issues/{num}").json()['state'] == 'closed'
            except Exception:
                return  # unknown: keep watching
        if not done:
            return
    print(f"WATCHER RETIRED at {datetime.datetime.now(datetime.timezone.utc):%Y-%m-%dT%H:%M:%SZ}: every watched thread is merged or closed", flush=True)
    # each supervisor gh-watch-start may have used, so the watcher doesn't come back after a reboot
    supervisor = os.environ.get('GH_WATCH_SUPERVISOR', '')  # set by the unit or the launchd agent gh-watch-start wrote
    if supervisor == 'systemd':
        unit = 'gh-watch@' + subprocess.run(['systemd-escape', '--path', HERE], capture_output=True, text=True).stdout.strip() + '.service'
        subprocess.run(['systemctl', '--user', 'disable', '--now', unit])
        return
    label = os.environ.get('XPC_SERVICE_NAME', '')
    if supervisor == 'launchd':
        subprocess.run(['rm', '-f', os.path.expanduser(f'~/Library/LaunchAgents/{label}.plist')])
        subprocess.run(['launchctl', 'bootout', f'gui/{os.getuid()}/{label}'])
        return
    tab = subprocess.run(['crontab', '-l'], capture_output=True, text=True)
    if tab.returncode == 0 and f'# gh-watch {HERE}' in tab.stdout:  # cron
        kept = ''.join(l + '\n' for l in tab.stdout.splitlines() if not l.endswith(f'# gh-watch {HERE}'))
        subprocess.run(['crontab', '-'], input=kept, text=True)
    try:
        os.kill(int(open(os.path.join(HERE, 'gh-watch.pid')).read().strip()), 15)  # the daemon's trap stops this watcher too
    except (OSError, ValueError):
        sys.exit(0)


# the version this process runs, resolved at start: ~/.mergeworthy/current may be repointed while it runs
RUNNING_ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


def installed_root():
    """The plugin version Claude Code has installed now (it changes on every update), or None outside the plugin."""
    try:
        with open(os.path.expanduser('~/.claude/plugins/installed_plugins.json')) as f:
            root = json.load(f)['plugins']['mergeworthy@mergeworthy'][0]['installPath']
        return root if os.path.isdir(root) else None
    except Exception:
        return None


def follow_update():
    """After a plugin update, point ~/.mergeworthy/current at the new version and exit 75: the daemon restarts this
    script on the new code. A watcher run from a checkout (not the plugin's cache) never follows."""
    if '/plugins/cache/' not in RUNNING_ROOT:
        return
    root = installed_root()
    link = os.path.join(HERE, 'gh-watch.py')
    if root and os.path.islink(link) and '/plugins/cache/' in os.readlink(link):  # pinned to one version by an old gh-watch-start
        os.remove(link)
        os.symlink(os.path.expanduser('~/.mergeworthy/current/watcher/gh-watch.py'), link)
    if root and os.path.realpath(root) != RUNNING_ROOT:
        cur = os.path.expanduser('~/.mergeworthy/current')
        tmp = cur + '.tmp'
        if os.path.lexists(tmp): os.remove(tmp)
        os.symlink(root, tmp)
        os.replace(tmp, cur)
        sys.exit(75)


def announce():
    """Tell this daemon's log about a pause that began since it last did (see announce_pause)."""
    if shared_read()['pause_until'] > time.time():
        with locked():
            state = load_state()
            announce_pause(state)
            save_state(state)


def tick():
    """One round of a daemon. What each budget level allows: OK everything; RESERVE (below RESERVE_AT calls left) not discovery and
    follow-ups; LOW (below LOW_AT) only the notifications and the threads they name; PAUSED nothing."""
    follow_update()
    lvl = level()
    if lvl < PAUSED:
        try:
            with locked():
                state = load_state()
                poll_account(state, lvl)
                ok, fulls = scan(state, plan(state, read_threads(), lvl))
                log_stats(state)
                save_state(state)
            read_reactions(fulls)
            if lvl <= RESERVE and time.time() - _retire_at[0] > 300:
                _retire_at[0] = time.time()
                retire_if_done()
            shared_pass()
        except Budget:
            pass
    scan_gitlab()
    agent_jobs_pass()
    announce()


def scan_gitlab():
    """GitLab threads (gl_watch): outside GitHub's budget levels, which they don't spend."""
    threads = gl_watch.threads(THREADS)
    if threads:
        with locked():
            state = load_state()
            gl_watch.scan(state, threads, handle_comment, emit, lambda body: _norm(body) in agent_post_hashes(), CHECK)
            save_state(state)


_retire_at = [0]
_jobs_at, _routed = [0], {}


def agent_jobs_pass():
    """Once a minute: `### AGENT DONE` for each job whose agent finished, once per finish, in the watch dir of the session that
    launched it: the one its `session` file names, else the one whose events.log the launcher's transcript names most (a
    transcript also names other watchers, in a `ps` listing say). A job an older hook registered without them has its
    launcher found by agent_jobs.launchers."""
    if time.time() - _jobs_at[0] < 60:
        return
    _jobs_at[0] = time.time()
    try:
        mine = open(os.path.join(HERE, 'session')).read().strip()
    except OSError:
        mine = ''
    ready = [(f, j, done) for f, j in agent_jobs.jobs() for done in [agent_jobs.finished(j)] if done and not agent_jobs.reported(f, done[1])]
    found = agent_jobs.launchers([(f, j, done[0]) for f, j, done in ready if f not in _routed and not j.get('transcript')])
    for f, j, done in ready:
        if f not in _routed:
            try:
                tr = j.get('transcript') or found.get(f)
                log = open(tr or '', 'rb').read() if not (mine and j.get('session') == mine) else b''
            except OSError:
                log = b''
            named = [os.path.expanduser(w.decode()) for w in re.findall(rb'(?<![\w.-])([~/][\w./-]*)/events\.log', log)]
            _routed[f] = bool(mine and j.get('session') == mine) or bool(named) and max(set(named), key=named.count) == HERE
        if _routed[f] and agent_jobs.claim(f, done[1]):
            k = shlex.quote(j['key'])
            emit(f"### AGENT DONE {j['key']}: read its result (task_status / its report), then agent-job done {k}")


def main():
    if '--stats' in sys.argv:
        print(stats_text())
        return
    if ONCE:
        run_scan(everything=True)
        shared_pass(force=True)
        return
    while True:
        tick()
        time.sleep(10)


if __name__ == '__main__':
    main()
