"""GitLab threads for gh-watch.py: threads.txt lines "gitlab.com/<namespace>/<project> N" (an issue) or "... !N" (a merge
request; issues and MRs are numbered separately, so the line says which). Read through `glab api`, every 60 s while open and
changed in the last day, else at the GitHub threads' cadence; GitHub's budget, ETags, notifications and feeds don't see them.
Reported like a GitHub thread: answerable notes (an event, an owed reply and an :eyes: award), MR state changes, pipeline results
and issue closes. Keys are "gitlab.com/<path>#N" and "gitlab.com/<path>!N": no GitHub owner has a dot, so they can't collide."""
import datetime, json, re, subprocess, time, urllib.parse

HOST = 'gitlab.com/'
RECENT_EVERY = 60
BADGE = re.compile(r'\s*<img src="https://github\.com/(claude|openai)\.png"')  # an agent's post starts with it (mergeworthy:writing §Forms); BADGE.match(body)
BOT = re.compile(r'^(project|group)_\d+_bot|[-_]bot$|^(ghost|support-bot|alert-bot)$')
DEVELOPER = 30  # GitLab's access level that can push: GitHub's write access


def threads(path):
    """-> [(key, project, 'issues' or 'merge_requests', iid)] for the GitLab lines of threads.txt."""
    out = []
    for l in open(path):
        w = l.split()
        if len(w) == 2 and w[0].startswith(HOST) and re.fullmatch(r'!?\d+', w[1]):
            iid = w[1].lstrip('!')
            mr = w[1] != iid
            out.append((f"{w[0]}{'!' if mr else '#'}{iid}", w[0][len(HOST):], 'merge_requests' if mr else 'issues', iid))
    return out


def api(path, *args):
    r = subprocess.run(['glab', 'api', '--hostname', 'gitlab.com', path, *args], capture_output=True, text=True, timeout=60)
    if r.returncode:
        raise RuntimeError(f"glab api {path}: {(r.stderr or r.stdout).strip()[:200]}")
    return json.loads(r.stdout) if r.stdout.strip() else None


def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def epoch(t):
    return datetime.datetime.strptime(t[:19], '%Y-%m-%dT%H:%M:%S').replace(tzinfo=datetime.timezone.utc).timestamp()


def maintainer(state, proj, uid):
    """A project member who can push. Cached for a day: roles rarely change."""
    cache, k = state.setdefault('gl_access', {}), f"{proj}:{uid}"
    if time.time() - cache.get(k, [0, 0])[1] > 86400:
        try:
            level = api(f"projects/{proj}/members/all/{uid}")['access_level']
        except RuntimeError as e:
            if '404' not in str(e):
                raise
            level = 0
        cache[k] = [level, time.time()]
    return cache[k][0] >= DEVELOPER


def award_eyes(base, nid, emit):
    try:
        api(f"{base}/notes/{nid}/award_emoji", '--method', 'POST', '-f', 'name=eyes')
    except Exception as e:
        emit(f"WATCH ERROR eyes {base} note {nid}: {e}")


def read(state, t, key, proj, kind, iid, report, emit, agent_post):
    base = f"projects/{proj}/{kind}/{iid}"
    th = api(base)
    me = state.get('gl_me') or state.setdefault('gl_me', api('user')['username'])
    now_state = {'opened': 'open', 'locked': 'open'}.get(th['state'], th['state'])
    if kind == 'merge_requests':
        pr = {'head': (th.get('sha') or '')[:10], 'state': now_state, 'conflict': bool(th.get('has_conflicts'))}
        if t.get('pr') and t['pr'] != pr:
            emit(f"### PR CHANGED {key}: {t['pr']} -> {pr}")
        t['pr'] = pr
        if now_state == 'open':
            p = th.get('head_pipeline') or {}
            red = [f"pipeline {p['id']}"] if p.get('status') == 'failed' else []
            if red != t.get('red', []):
                emit(f"### CI {key}: red={red}: fix it, or if it is not this MR's doing, say why on the MR now with the evidence (mergeworthy:reply §Events)" if red else f"### CI {key}: no longer red")
            t['red'] = red
    elif t.get('state') and t['state'] != now_state:
        emit(f"### ISSUE CHANGED {key}: {t['state']} -> {now_state}")
    t['state'], t['upd'] = now_state, epoch(th['updated_at'])
    floor = iso(epoch(t.get('since') or state['since']) - 600)  # scans overlap by 10 minutes, as GitHub's do
    own, notes = th['author']['username'] == me, []
    for n in api(f"{base}/notes?sort=desc&order_by=updated_at&per_page=100"):
        upd = n['updated_at'][:19] + 'Z'
        if upd < floor:
            break
        who, body = n['author']['username'], n.get('body') or ''
        if n.get('system') or BOT.search(who) or BADGE.match(body) or agent_post(body):
            continue
        if own or who == me or maintainer(state, proj, n['author']['id']):
            notes.append((n['id'], upd, who, body))
    for nid, upd, who, body in reversed(notes):  # oldest first, as they were written
        report(state, key, key, 'note', nid, upd, who, f"{th['web_url']}#note_{nid}", body,
               react=lambda _key, _kind, cid: award_eyes(base, cid, emit))


def scan(state, threads, report, emit, agent_post, every):
    """Read each GitLab thread that is due. report: gh-watch's handle_comment; agent_post(body): a gated post of the agent's;
    every: gh-watch's seconds between looks by 'open' and 'closed'."""
    gl, now = state.setdefault('gl', {}), time.time()
    for key, proj, kind, iid in threads:
        t = gl.setdefault(key, {})
        if now < t.get('next', 0):
            continue
        try:
            read(state, t, key, urllib.parse.quote(proj, safe=''), kind, iid, report, emit, agent_post)
        except Exception as e:
            emit(f"WATCH ERROR {key}: {e}")
            t['next'] = now + 300
            continue
        t['since'] = iso(now)
        t['next'] = now + (every['closed'] if t['state'] != 'open' else RECENT_EVERY if now - t['upd'] < 86400 else every['open'])


def done(state, key):
    """Merged or closed, as the last read found it; unknown keeps the watcher."""
    return state.get('gl', {}).get(key, {}).get('state') in ('merged', 'closed')
