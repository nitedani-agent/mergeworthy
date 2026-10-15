"""A stand-in GitHub, for tests of the watcher's API budget (tests/watch-budget.py).

FakeGitHub answers what the watcher asks, with ETags, 304s, rate-limit headers and the limit itself, and logs every request.
Shim() puts it under `subprocess.run` (the `gh` commands) and `http.client.HTTPSConnection` (the kept-alive GETs), and starts
no process for `subprocess.Popen` (the hourly disk-sweep), so the same watcher code runs on it unchanged. Sim is a clock and a scheduler: each daemon runs main() in a thread that is
parked in time.sleep, and the sim wakes one at a time in order of simulated time, so a run is deterministic.
"""
import datetime, hashlib, heapq, json, random, re, subprocess, threading, traceback, types, urllib.parse
import http.client

T0 = datetime.datetime(2026, 10, 9, 12, 0, 0, tzinfo=datetime.timezone.utc).timestamp()
DAY = 86400


def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def sha_of(*parts):
    return hashlib.sha1('/'.join(map(str, parts)).encode()).hexdigest()


class Stop(BaseException):
    """Raised inside a daemon that the sim stops (a restart)."""


class Sim:
    def __init__(self):
        self.now, self.heap, self.seq = T0, [], 0
        self.main = threading.Semaphore(0)
        self.stopping, self.errors, self.daemons = False, [], []
        self.timers = []  # (time, fn): world events

    def spawn(self, name, fn):
        d = types.SimpleNamespace(name=name, sem=threading.Semaphore(0), thread=None)
        def body():
            d.sem.acquire()
            try:
                if not self.stopping:
                    fn(d)
            except Stop:
                pass
            except BaseException:
                self.errors.append((name, traceback.format_exc()))
            finally:
                d.done = True
                self.main.release()
        d.done = False
        d.thread = threading.Thread(target=body, daemon=True)
        d.thread.start()
        self.daemons.append(d)
        self.wake_at(d, self.now)
        return d

    def wake_at(self, d, t):
        self.seq += 1
        heapq.heappush(self.heap, (t, self.seq, d))

    def sleeper(self, d):
        def sleep(secs):
            self.wake_at(d, self.now + secs)
            self.main.release()
            d.sem.acquire()
            if self.stopping:
                raise Stop()
        return sleep

    def run_until(self, end):
        while self.heap and self.heap[0][0] <= end:
            t, _, d = heapq.heappop(self.heap)
            while self.timers and self.timers[0][0] <= t:
                self.timers.pop(0)[1]()
            self.now = max(self.now, t)
            if d.done:
                continue
            d.sem.release()
            self.main.acquire()
        while self.timers and self.timers[0][0] <= end:
            self.now = max(self.now, self.timers[0][0])
            self.timers.pop(0)[1]()
        self.now = end

    def at(self, t, fn):
        self.timers.append((t, fn))
        self.timers.sort(key=lambda x: x[0])

    def stop_all(self):
        """A restart: every daemon unwinds out of its sleep, as if its process were killed between two rounds."""
        self.stopping = True
        for _, _, d in sorted(self.heap):
            if not d.done:
                d.sem.release()
                self.main.acquire()
        self.heap.clear()
        self.daemons.clear()
        self.stopping = False


class FakeGitHub:
    LIMIT = 5000

    def __init__(self, sim):
        self.sim, self.lock = sim, threading.RLock()
        self.log = []  # (time, method, path without query, status, resource)
        self.remaining = None  # a test forces the remaining calls GitHub reports
        self.limited_until = 0  # a test makes every call a rate-limit answer until then
        self.secondary = False  # ... a secondary one (403 with Retry-After, the remaining count still positive)
        self.used = {'core': 0, 'graphql': 0}
        self.reset = int(T0) + 3600
        self.issues, self.comments, self.pr_comments, self.reviews = {}, {}, {}, {}  # by (repo, n); the comment feeds by repo
        self.prs, self.commits, self.details, self.timeline, self.files = {}, {}, {}, {}, {}
        self.notifications, self.events = [], []
        self.hold = None  # a threading.Event the next request waits for
        self.version = 0  # bumped by any change a feed shows
        self.poll = 60  # the X-Poll-Interval of the notifications and the events feed

    # ----- data -----
    def comment(self, repo, n, user, body, kind='comment', at=None):
        at = iso(self.sim.now if at is None else at)
        store = self.comments if kind == 'comment' else self.pr_comments
        feed = store.setdefault(repo, [])
        c = {'id': 1000 + sum(len(v) for v in self.comments.values()) + sum(len(v) for v in self.pr_comments.values()), 'user': {'login': user}, 'body': body,
             'created_at': at, 'updated_at': at, 'html_url': f'https://github.com/{repo}/issues/{n}#c', 'author_association': 'OWNER',
             ('issue_url' if kind == 'comment' else 'pull_request_url'): f'https://api.github.com/repos/{repo}/{"issues" if kind == "comment" else "pulls"}/{n}'}
        feed.append(c)
        self.touch(repo, n, at)
        return c

    def touch(self, repo, n, at=None):
        """Anything that happens on a thread (a comment, a push) moves its updated_at, which the PR/issue bodies and the repo's issue list show."""
        if (repo, n) in self.issues:
            self.issues[(repo, n)]['updated_at'] = at or iso(self.sim.now)
        self.version += 1

    def commit(self, repo, author, files, when=None, parents=1):
        when = self.sim.now if when is None else when
        sha = sha_of(repo, author, when, len(self.commits.get(repo, [])))
        self.commits.setdefault(repo, []).append({'sha': sha, 'html_url': f'https://github.com/{repo}/commit/{sha}', 'parents': [{}] * parents,
            'author': {'login': author, 'type': 'Bot' if author.endswith('[bot]') else 'User'}, 'commit': {'committer': {'date': iso(when)}, 'author': {'name': author}}})
        self.commits[repo].sort(key=lambda c: c['commit']['committer']['date'], reverse=True)
        self.details[(repo, sha)] = files
        self.version += 1
        return sha

    def count(self, resource='core', upto=None):
        return sum(1 for t, m, p, s, r in self.log if r == resource and s != 304 and (upto is None or t <= upto))

    def hits(self, needle):
        return [e for e in self.log if needle in e[2] and e[3] != 304]

    # ----- requests -----
    def serve(self, method, path, headers=None, fields=()):
        headers = {k.lower(): v for k, v in (headers or {}).items()}
        with self.lock:
            if self.hold is not None:
                hold, self.hold = self.hold, None
                self.lock.release()
                try:
                    hold.wait(5)
                finally:
                    self.lock.acquire()
            url, _, qs = path.partition('?')
            q = dict(urllib.parse.parse_qsl(qs))
            q.update(dict(fields) if method == 'GET' else {})
            resource = 'graphql' if url == 'graphql' else 'search' if url.startswith('search/') else 'core'
            now = self.sim.now
            if self.limited_until > now and self.secondary:
                status, hdr, body = 403, {'Retry-After': str(int(self.limited_until - now))}, json.dumps({'message': 'You have exceeded a secondary rate limit.'})
                left, reset = self.LIMIT - self.used['core'], self.reset
            elif self.limited_until > now:
                status, hdr, body = 403, {}, json.dumps({'message': 'API rate limit exceeded for user ID 1.'})
                left, reset = 0, int(self.limited_until)
            else:
                status, hdr, body = self.route(method, url, q, fields)
                left = self.remaining if self.remaining is not None else self.LIMIT - self.used.get(resource, 0)
                reset = self.reset
            if status == 200 and method == 'GET':
                etag = hashlib.sha256(body.encode()).hexdigest()
                lm = hdr.get('Last-Modified')
                if headers.get('if-none-match', '').replace('W/', '') == f'"{etag}"' or (lm and headers.get('if-modified-since') == lm):
                    status, body = 304, ''
                    hdr = {'Etag': f'"{etag}"'}
                else:
                    hdr['Etag'] = f'W/"{etag}"'
            if status != 304 and status != 403 and resource in self.used:
                self.used[resource] += 1
                left = self.remaining if self.remaining is not None else self.LIMIT - self.used[resource]
            hdr.update({'X-Ratelimit-Limit': '5000', 'X-Ratelimit-Remaining': str(left), 'X-Ratelimit-Reset': str(reset), 'X-Ratelimit-Resource': resource})
            self.log.append((now, method, url, status, resource))
            return status, hdr, body

    def page(self, items, q, url):
        per, n = int(q.get('per_page', 30)), int(q.get('page', 1))
        out = items[(n - 1) * per:n * per]
        hdr = {}
        if n * per < len(items):
            nq = dict(q, page=n + 1)
            hdr['Link'] = f'<https://api.github.com/{url}?{urllib.parse.urlencode(nq)}>; rel="next"'
        return json.dumps(out, sort_keys=True), hdr

    def feed(self, store, repo, q, url):
        items = [c for c in store.get(repo, []) if c['updated_at'] >= q.get('since', '')]
        items.sort(key=lambda c: c[q.get('sort', 'created') + '_at'], reverse=q.get('direction', 'desc') == 'desc')
        body, hdr = self.page(items, q, url)
        return 200, hdr, body

    def route(self, method, url, q, fields):
        if method == 'POST':
            if url == 'graphql':
                f = dict(fields)
                n = int(f['n'])
                repo = f"{f['o']}/{f['r']}"
                pr = self.prs.get((repo, n))
                mine = [c for c in self.comments.get(repo, []) if c['issue_url'].endswith(f'/{n}')]
                nodes = [{'databaseId': c['id'], 'url': c['html_url'], 'createdAt': c['created_at'], 'author': c['user']} for c in mine[-2:]]
                people = [{'login': u} for u in dict.fromkeys(c['user']['login'] for c in mine)]
                state = 'OPEN' if not pr or pr['state'] == 'open' else 'MERGED' if pr['merged'] else 'CLOSED'
                return 200, {}, json.dumps({'data': {'repository': {'issueOrPullRequest': {'state': state, 'comments': {'nodes': nodes}, 'participants': {'nodes': people}, 'timelineItems': {'nodes': []}}}}})
            return 201, {}, '[]'  # a reaction
        if url == 'user':
            return 200, {}, json.dumps({'login': 'me'})
        if url.startswith('notifications'):
            body = json.dumps(self.notifications, sort_keys=True)
            return 200, {'Last-Modified': f'v{len(self.notifications)}', 'X-Poll-Interval': str(self.poll)}, body
        if url == 'users/me/events':
            return 200, {'X-Poll-Interval': str(self.poll)}, json.dumps(self.events, sort_keys=True)
        m = re.fullmatch(r'repos/([^/]+/[^/]+)/issues', url) or (url == 'issues' and q.get('filter') == 'created' and [None, None])
        if m:  # the repo's issues and PRs (or all you opened, in every repo), as the list shows them
            items = [{'number': k[1], 'updated_at': v.get('updated_at', iso(T0 - 3 * DAY)), 'state': v['state'], 'user': v['user'], 'repository': {'full_name': k[0]}, **({'pull_request': {}} if k in self.prs else {})}
                     for k, v in self.issues.items() if (k[0] == m[1] if m[1] else v['user']['login'] == 'me')]
            items.sort(key=lambda i: i['updated_at'], reverse=q.get('direction', 'desc') == 'desc')
            body, hdr = self.page(items, q, url)
            return 200, hdr, body
        if url.startswith('search/issues'):
            return 200, {}, json.dumps({'items': []})
        m = re.fullmatch(r'repos/([^/]+/[^/]+)/(issues|pulls)/comments', url)
        if m:
            return self.feed(self.comments if m[2] == 'issues' else self.pr_comments, m[1], q, url)
        m = re.fullmatch(r'repos/([^/]+/[^/]+)/commits', url)
        if m:
            items = [c for c in self.commits.get(m[1], []) if c['commit']['committer']['date'] >= q.get('since', '')]
            body, hdr = self.page(items, q, url)
            return 200, hdr, body
        m = re.fullmatch(r'repos/([^/]+/[^/]+)/commits/(\w+)', url)
        if m:
            return 200, {}, json.dumps({'files': self.details[(m[1], m[2])]}, sort_keys=True)
        m = re.fullmatch(r'repos/([^/]+/[^/]+)/(issues|pulls)/(\d+)(?:/(comments|reviews|files|timeline|reactions))?', url)
        if not m:
            return 404, {}, json.dumps({'message': 'Not Found: ' + url})
        repo, kind, n, sub = m[1], m[2], int(m[3]), m[4]
        key = (repo, n)
        if sub is None:
            if kind == 'issues':
                issue = dict(self.issues[key])
                if key in self.prs:
                    issue['pull_request'] = {}
                return 200, {}, json.dumps(issue, sort_keys=True)
            pr = self.prs[key]
            return 200, {}, json.dumps({'head': {'sha': pr['head']}, 'state': pr['state'], 'merged': pr['merged'], 'merged_at': pr.get('merged_at'),
                'merge_commit_sha': pr.get('merge_commit_sha'), 'base': {'ref': 'main'}, 'user': {'login': 'me'}, 'mergeable_state': 'clean',
                'updated_at': self.issues[key].get('updated_at')}, sort_keys=True)
        if sub == 'comments':
            store = self.comments if kind == 'issues' else self.pr_comments
            items = [c for c in store.get(repo, []) if (c.get('issue_url') or c.get('pull_request_url')).endswith(f'/{n}') and c['updated_at'] >= q.get('since', '')]
            body, hdr = self.page(items, q, url)
            return 200, hdr, body
        if sub == 'reviews':
            return 200, {}, json.dumps(self.reviews.get(key, []))
        if sub == 'files':
            return 200, {}, json.dumps(self.files[key], sort_keys=True)
        if sub == 'timeline':
            body, hdr = self.page(self.timeline.get(key, []), q, url)
            return 200, hdr, body
        return 200, {}, '[]'


class Reply:  # what subprocess.run and http responses look like
    def __init__(self, **kw):
        self.__dict__.update(kw)


def gh_cli(gh, argv):
    """The `gh` commands the watcher runs, answered from FakeGitHub (output as the real gh prints it, 304 exits 1)."""
    a = argv[1:]
    if a[:2] == ['auth', 'token']:
        return Reply(returncode=0, stdout='tok\n', stderr='')
    if a[:2] == ['pr', 'checks']:
        with gh.lock:
            if gh.limited_until > gh.sim.now:
                return Reply(returncode=1, stdout='', stderr='GraphQL: API rate limit already exceeded for user ID 1.')
            gh.used['graphql'] += 1
            gh.log.append((gh.sim.now, 'POST', 'pr checks', 200, 'graphql'))
        return Reply(returncode=0, stdout='ci\tpass\t1m\turl\n', stderr='')
    if a[0] != 'api':
        return Reply(returncode=0, stdout='', stderr='')
    include, method, hdrs, paginate, fields, path, i = False, None, {}, False, [], None, 1
    while i < len(a):
        x = a[i]
        if x in ('-i', '--include'):
            include = True
        elif x in ('-X', '--method'):
            method = a[i + 1]; i += 1
        elif x in ('-H', '--header'):
            k, _, v = a[i + 1].partition(':'); hdrs[k.strip()] = v.strip(); i += 1
        elif x == '--paginate':
            paginate = True
        elif x in ('--jq', '-q'):
            i += 1
        elif x in ('-f', '-F', '--raw-field', '--field'):
            k, _, v = a[i + 1].partition('='); fields.append((k, v)); i += 1
        elif x != '--slurp':
            path = x
        i += 1
    method = method or ('POST' if fields else 'GET')
    if paginate:
        pages, n = [], 1
        while True:
            sep = '&' if '?' in path else '?'
            status, hdr, body = gh.serve(method, f'{path}{sep}page={n}', hdrs, fields)
            if status >= 300:
                return Reply(returncode=1, stdout='', stderr=f'gh: HTTP {status}')
            pages.append(json.loads(body))
            if 'rel="next"' not in hdr.get('Link', ''):
                return Reply(returncode=0, stdout=json.dumps(pages), stderr='')
            n += 1
    status, hdr, body = gh.serve(method, path, hdrs, fields)
    out = ''
    if include:
        out = f'HTTP/2.0 {status} X\r\n' + ''.join(f'{k}: {v}\r\n' for k, v in hdr.items()) + '\r\n'
    out += body
    return Reply(returncode=0 if status < 300 else 1, stdout=out if include or status < 300 else '', stderr='' if status < 300 else f'gh: HTTP {status}')


class Headers(dict):
    def get(self, k, d=None):
        return next((v for kk, v in self.items() if kk.lower() == k.lower()), d)


class Shim:
    """Patches subprocess.run and http.client.HTTPSConnection to answer from FakeGitHub, and subprocess.Popen to start nothing; use as a context manager."""
    def __init__(self, gh):
        self.gh = gh

    def __enter__(self):
        gh = self.gh
        self.run, self.conn, self.popen = subprocess.run, http.client.HTTPSConnection, subprocess.Popen
        def run(argv, *a, **k):
            return gh_cli(gh, argv) if argv and argv[0] == 'gh' else Reply(returncode=0, stdout='', stderr='')
        class Conn:
            def __init__(self, host, timeout=None):
                pass
            def request(self, method, path, headers=None):
                self.r = gh.serve(method, path.lstrip('/'), headers or {})
            def getresponse(self):
                status, hdr, body = self.r
                return Reply(status=status, headers=Headers(hdr), getheaders=lambda: list(hdr.items()), read=lambda: body.encode())
        subprocess.run, http.client.HTTPSConnection, subprocess.Popen = run, Conn, lambda *a, **k: Reply(pid=0)
        return self

    def __exit__(self, *e):
        subprocess.run, http.client.HTTPSConnection, subprocess.Popen = self.run, self.conn, self.popen


def clock_for(sim, daemon=None):
    """The `time` and `datetime` a watcher module sees: the sim's clock."""
    class DT(datetime.datetime):
        @classmethod
        def now(cls, tz=None):
            return datetime.datetime.fromtimestamp(sim.now, tz)
    t = types.SimpleNamespace(time=lambda: sim.now, sleep=sim.sleeper(daemon) if daemon else (lambda s: None))
    d = types.SimpleNamespace(datetime=DT, timezone=datetime.timezone, timedelta=datetime.timedelta)
    return t, d


# ---------- a machine like the user's: seven watch dirs over a handful of repos ----------
PRS = [  # (repo, number, kind, days since merged)
    ('vikejs/vike', 101, 'open', None), ('vikejs/vike', 102, 'open', None), ('vikejs/vike', 103, 'open', None),
    ('vikejs/vike', 50, 'merged', 5), ('vikejs/vike', 51, 'merged', 20), ('vikejs/vike', 52, 'merged', 40), ('vikejs/vike', 53, 'merged', 2),
    ('vikejs/vike-react', 11, 'open', None), ('vikejs/vike-react', 8, 'merged', 3),
    ('vikejs/docpress', 204, 'open', None), ('vikejs/docpress', 190, 'merged', 30),
    ('telefunc/telefunc', 436, 'open', None), ('telefunc/telefunc', 430, 'merged', 10),
    ('nitedani/mergeworthy', 9, 'issue', None), ('brillout/x', 5, 'issue', None),
]
DIRS = {
    'd1': ['vikejs/vike 101', 'vikejs/vike 102', 'vikejs/vike 50', 'vikejs/vike 51', 'vikejs/vike 52'],
    'd2': ['vikejs/vike 103', 'vikejs/vike 53'],
    'd3': ['vikejs/vike-react 11', 'vikejs/vike-react 8'],
    'd4': ['vikejs/docpress 204', 'vikejs/docpress 190'],
    'd5': ['telefunc/telefunc 436', 'telefunc/telefunc 430'],
    'd6': ['nitedani/mergeworthy 9'],
    'd7': ['brillout/x 5'],
}
COMMITS = {'vikejs/vike': 150, 'vikejs/vike-react': 40, 'vikejs/docpress': 40, 'telefunc/telefunc': 30, 'nitedani/mergeworthy': 10, 'brillout/x': 5}
HUNK = '@@ -{a},3 +{a},3 @@\n ctx\n-{old}\n+{new}\n ctx'
DEP = lambda a, v: HUNK.format(a=a, old=f'    "vite": ">=7.0.{v}",', new=f'    "vite": ">=7.1.{v}",')
SCRIPT = lambda a: HUNK.format(a=a, old='    "build": "tsc",', new='    "build": "tsc -b",')
TS = lambda a: HUNK.format(a=a, old='const a = 1', new='const a = 2')
PKG = 'packages/vike/package.json'


def build_world(gh):
    rng, sim = random.Random(7), gh.sim
    for repo, n, kind, ago in PRS:
        gh.issues[(repo, n)] = {'number': n, 'user': {'login': 'me'}, 'state': 'open', 'body': ''}
        if kind == 'issue':
            continue
        merged = kind == 'merged'
        pr = {'head': sha_of(repo, n, 'head'), 'state': 'closed' if merged else 'open', 'merged': merged}
        gh.prs[(repo, n)] = pr
        if merged:
            pr.update(merged_at=iso(T0 - ago * DAY), merge_commit_sha=sha_of(repo, n, 'merge'))
            files = [{'filename': f'packages/{n}/a.ts', 'status': 'modified', 'patch': HUNK.format(a=10, old='x', new='y')}]
            if n in (50, 51):
                files.append({'filename': PKG, 'status': 'modified', 'patch': DEP(30, 0)})  # my dependency line
            gh.files[(repo, n)] = files
            gh.commits.setdefault(repo, []).append({'sha': pr['merge_commit_sha'], 'html_url': 'u', 'parents': [{}], 'author': {'login': 'me', 'type': 'User'},
                'commit': {'committer': {'date': pr['merged_at']}, 'author': {'name': 'me'}}})
            gh.details[(repo, pr['merge_commit_sha'])] = [{'filename': f['filename'], 'status': 'modified', 'patch': f['patch']} for f in files]
        gh.timeline[(repo, n)] = [{'event': 'cross-referenced', 'source': {'issue': {'html_url': f'<bot-pr-{n}>', 'pull_request': {}, 'user': {'login': 'renovate[bot]', 'type': 'Bot'}}}}]
        gh.comment(repo, n, 'alice', 'older note', at=T0 - 3 * DAY)
    for repo, count in COMMITS.items():
        for i in range(count):
            who = rng.choices(['alice', 'bob', 'carol', 'dependabot[bot]', 'renovate[bot]'], [3, 3, 2, 3, 2])[0]
            files = [{'filename': f'src/mod{rng.randrange(30)}.ts', 'status': 'modified', 'patch': TS(rng.randrange(1, 200))}]
            if who.endswith('[bot]') or rng.random() < .15:  # dependency bumps: the noise
                files += [{'filename': PKG, 'status': 'modified', 'patch': DEP(30, i)}, {'filename': 'pnpm-lock.yaml', 'status': 'modified', 'patch': HUNK.format(a=400 + i, old=f'      version: 1.2.{i}', new=f'      version: 1.2.{i + 1}')}]
            gh.commit(repo, who, files, when=T0 - rng.uniform(.01, 59) * DAY, parents=2 if rng.random() < .08 else 1)
    # commits planted among them, each with what a FOLLOW-UP should do with it
    gh.planted = {
        'touch50': gh.commit('vikejs/vike', 'alice', [{'filename': 'packages/50/a.ts', 'status': 'modified', 'patch': TS(11)}], when=T0 - 1 * DAY),
        'bump': gh.commit('vikejs/vike', 'bob', [{'filename': PKG, 'status': 'modified', 'patch': DEP(30, 9)}, {'filename': 'pnpm-lock.yaml', 'status': 'modified', 'patch': DEP(31, 9)}], when=T0 - 3 * DAY),
        'script': gh.commit('vikejs/vike', 'carol', [{'filename': PKG, 'status': 'modified', 'patch': SCRIPT(31)}], when=T0 - 2 * DAY),
        'bot': gh.commit('vikejs/vike', 'dependabot[bot]', [{'filename': 'packages/50/a.ts', 'status': 'modified', 'patch': TS(11)}], when=T0 - 1.5 * DAY),
        'rename8': gh.commit('vikejs/vike-react', 'dave', [{'filename': 'packages/8/b.ts', 'previous_filename': 'packages/8/a.ts', 'status': 'renamed'}], when=T0 - 1 * DAY),
    }
    # events during the hour
    def new_commit(repo, who, fname, key):
        def f():
            gh.planted[key] = gh.commit(repo, who, [{'filename': fname, 'status': 'modified', 'patch': TS(11)}])
        return f
    def human_comment():
        c = gh.comment('vikejs/vike', 101, 'alice', 'Could you look at this?')
        gh.notifications.append({'updated_at': c['created_at'], 'subject': {'url': 'https://api.github.com/repos/vikejs/vike/issues/101'}})
    def agent_comment():
        c = gh.comment('vikejs/vike', 999, 'me', '/agent do it')
        gh.issues[('vikejs/vike', 999)] = {'number': 999, 'user': {'login': 'me'}, 'state': 'open', 'body': ''}
        gh.events.insert(0, {'type': 'IssueCommentEvent', 'created_at': c['created_at'], 'repo': {'name': 'vikejs/vike'}, 'payload': {'issue': {'number': 999}, 'comment': c}})
    def reference():
        gh.timeline[('vikejs/vike', 50)].append({'event': 'cross-referenced', 'source': {'issue': {'html_url': '<frank-pr>', 'pull_request': {}, 'user': {'login': 'frank'}}}})
        gh.version += 1
    sim.at(T0 + 600, human_comment)
    sim.at(T0 + 1200, new_commit('vikejs/docpress', 'erin', 'packages/190/a.ts', 'late190'))
    sim.at(T0 + 2400, new_commit('vikejs/vike', 'gina', 'packages/53/a.ts', 'late53'))
    sim.at(T0 + 2400, agent_comment)
    sim.at(T0 + 3000, reference)
    # the events these produce, per watch dir (the planted commits are listed by their short sha)
    short = lambda k: gh.planted[k][:10]
    return lambda: sorted([
        ('d1', f"### FOLLOW-UP vikejs/vike#50: {short('touch50')}"),
        ('d1', "### FOLLOW-UP vikejs/vike#50, #51:"),  # one line for a commit touching two PRs
        ('d3', f"### FOLLOW-UP vikejs/vike-react#8: {short('rename8')}"),
        ('d4', f"### FOLLOW-UP vikejs/docpress#190: {short('late190')}"),
        ('d2', f"### FOLLOW-UP vikejs/vike#53: {short('late53')}"),
        ('d1', '### FOLLOW-UP vikejs/vike#50: <frank-pr>'),
        ('d1', '### vikejs/vike#101 comment'),
        ('d1', '### UNROUTED /agent vikejs/vike#999'),
    ])


# ---------- the user's machine as of 2026-10-09: seven watch dirs, ~200 threads, 70 of them in one dir, most merged ----------
# (dir, repo, open PRs, of them changed in the last day, merged PRs, closed PRs, open issues, of them changed in the last day)
MACHINE = [
    ('conv', 'vikejs/vike', 4, 1, 18, 0, 3, 0), ('conv', 'magne4000/universal-middleware', 2, 1, 14, 1, 2, 1), ('conv', 'nitedani/vike-react-rsc', 3, 1, 9, 0, 2, 0),
    ('conv', 'brillout/react-streaming', 1, 0, 4, 0, 1, 0), ('conv', 'nitedani/mergeworthy', 0, 0, 2, 0, 2, 0), ('conv', 'react/react', 0, 0, 2, 0, 0, 0),
    ('d1', 'vikejs/vike', 5, 2, 20, 1, 2, 0), ('d2', 'vikejs/docpress', 3, 1, 14, 1, 2, 0), ('d3', 'telefunc/telefunc', 4, 1, 14, 1, 1, 0),
    ('d4', 'vikejs/vike-react', 3, 1, 14, 1, 2, 0), ('d5', 'universal-deploy/universal-deploy', 3, 1, 14, 1, 2, 0), ('d6', 'brillout/x', 5, 1, 12, 1, 2, 0),
]


FOREIGN = {('d3', 'open', True), ('d6', 'issue', False)}  # threads of someone else's that are watched: their repos are polled one by one


def build_machine(gh, seed=11):
    """The threads of MACHINE in a FakeGitHub: -> ({dir: ['owner/repo N', ...]}, {'recent_pr': [keys], 'stale_issue': [keys]}).
    Each repo also has commits (a fifth by bots) over the last 60 days, so the follow-ups of the merged PRs have work to do."""
    rng, dirs, pick = random.Random(seed), {}, {'recent_pr': [], 'stale_issue': [], 'recent_issue': []}
    numbers = {}
    def new(repo):
        numbers[repo] = numbers.get(repo, 100) + 1
        return numbers[repo]
    for d, repo, open_prs, recent_prs, merged, closed, issues, recent_issues in MACHINE:
        lines = dirs.setdefault(d, [])
        kinds = [('open', i < recent_prs) for i in range(open_prs)] + [('merged', False)] * merged + [('closed', False)] * closed + [('issue', i < recent_issues) for i in range(issues)]
        for kind, recent in kinds:
            n = new(repo)
            lines.append(f'{repo} {n}')
            upd = iso(T0 - (rng.uniform(.05, .8) if recent else rng.uniform(2, 40)) * DAY)
            gh.issues[(repo, n)] = {'number': n, 'user': {'login': 'carol' if (d, kind, recent) in FOREIGN else 'me'}, 'state': 'open', 'body': '', 'updated_at': upd}
            if kind == 'issue':
                pick['recent_issue' if recent else 'stale_issue'].append((d, repo, n))
                continue
            merged_ago = rng.uniform(1, 120)
            pr = {'head': sha_of(repo, n, 'head'), 'state': 'open' if kind == 'open' else 'closed', 'merged': kind == 'merged'}
            gh.prs[(repo, n)] = pr
            if kind == 'open' and recent:
                pick['recent_pr'].append((d, repo, n))
            if kind == 'merged':
                pr.update(merged_at=iso(T0 - merged_ago * DAY), merge_commit_sha=sha_of(repo, n, 'merge'))
                gh.issues[(repo, n)].update(state='closed', updated_at=pr['merged_at'])
                gh.files[(repo, n)] = [{'filename': f'packages/{n}/a.ts', 'status': 'modified', 'patch': HUNK.format(a=10, old='x', new='y')}]
                gh.commits.setdefault(repo, []).append({'sha': pr['merge_commit_sha'], 'html_url': 'u', 'parents': [{}], 'author': {'login': 'me', 'type': 'User'},
                    'commit': {'committer': {'date': pr['merged_at']}, 'author': {'name': 'me'}}})
                gh.details[(repo, pr['merge_commit_sha'])] = gh.files[(repo, n)]
            elif kind == 'closed':
                gh.issues[(repo, n)].update(state='closed', updated_at=iso(T0 - rng.uniform(5, 90) * DAY))
            gh.timeline[(repo, n)] = []
    for repo in {r for _, r, *_ in MACHINE}:
        for i in range(40):
            who = rng.choices(['alice', 'bob', 'dependabot[bot]', 'renovate[bot]'], [3, 3, 2, 2])[0]
            files = [{'filename': f'src/mod{rng.randrange(30)}.ts', 'status': 'modified', 'patch': TS(rng.randrange(1, 200))}]
            gh.commit(repo, who, files, when=T0 - rng.uniform(.01, 59) * DAY)
    return dirs, pick
