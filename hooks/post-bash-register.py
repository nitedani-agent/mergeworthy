#!/usr/bin/env python3
"""Claude Code PostToolUse hook (matcher: Bash). A thread you just posted in (a new issue or PR, a comment, a review)
joins the threads.txt of the posting session's watcher, else of the one that covers its repo, else of the first live
watcher, so maintainer comments on it are answered (mergeworthy:reply). A gated draft it posted as new gets its
.posted marker, which pre-bash-guard reads to refuse posting it as new again."""
import hashlib, json, os, re, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shellcmd import segments, prog, new_post_drafts
d = json.load(sys.stdin)
cmd = d.get('tool_input', {}).get('command', '')
r = d.get('tool_response') or {}
out = r.get('stdout', '') if isinstance(r, dict) else str(r)

def target(t):
    """(repo or None, number or None) a posting gh argv writes to; None when the argv doesn't post.
    Only a real `gh` argv counts: text that merely mentions one (an echo, a grep, a fixture) posts nothing."""
    t = prog(t)
    if t and os.path.basename(t[0]) == 'glab' and t[2:3] in (['create'], ['note']) and t[1] in ('issue', 'mr') and '--help' not in t and '-h' not in t:
        return None, None  # glab prints the thread's URL: that names it
    if not t or os.path.basename(t[0]) != 'gh' or len(t) < 2 or '--help' in t or '-h' in t:
        return None
    a = t[1:]
    if a[0] in ('issue', 'pr') and a[1:2] and a[1] in ('create', 'comment', 'review'):
        repo = next((x.split('=', 1)[1] for x in a if x.startswith('--repo=')), None) or \
            next((a[i + 1] for i in range(len(a) - 1) if a[i] in ('--repo', '-R')), None)
        arg = a[2] if a[2:3] and not a[2].startswith('-') else ''
        m = re.search(r'github\.com/([\w.-]+/[\w.-]+)/(?:issues|pull)/(\d+)', arg)
        if m: return m.group(1), m.group(2)
        return repo, (arg if arg.isdigit() else None)
    if a[0] == 'api':
        m = next((re.match(r'/?repos/([\w.-]+/[\w.-]+)/(?:issues|pulls)\b(?:/(\d+))?', x) for x in a[1:]
                  if re.match(r'/?repos/[\w.-]+/[\w.-]+/(issues|pulls)\b', x)), None)
        method = next((x[2:] for x in a if x.startswith('-X') and len(x) > 2), None) or \
            next((a[i + 1] for i in range(len(a) - 1) if a[i] in ('-X', '--method')), None)
        body = any(x in ('-f', '-F', '--field', '--raw-field', '--input') or re.match(r'^--(field|raw-field|input)=', x) for x in a)
        if m and (method.upper() == 'POST' if method else body):
            return m.group(1), m.group(2)
    return None

try:
    segs = segments(cmd)
except ValueError:
    sys.exit(0)
# Written here, not in pre-bash-guard: PostToolUse runs only after the command succeeded, so a post another hook blocked, or one that failed, can be retried
if isinstance(r, dict) and not r.get('interrupted'):
    for s in segs:
        for f in new_post_drafts(s):
            f = os.path.join(d.get('cwd') or os.getcwd(), os.path.expandvars(os.path.expanduser(f)))
            try:
                sha = hashlib.sha256(open(f, 'rb').read()).hexdigest()
                if open(f + '.gate').read().split('\n')[0].strip() == sha:
                    open(f + '.posted', 'w').write(sha)
            except OSError:
                pass
targets = [x for x in (target(s) for s in segs) if x]
if not targets:
    sys.exit(0)
def posted(repo, num):  # a URL in stdout counts only when it is the thread a posting segment wrote to
    return any((tr is None or tr == repo) and (tn is None or tn == num) for tr, tn in targets)
# The agent and the user may share one login, so the watcher knows a comment is the agent's by its body's hash.
# `gh --attach` rewrites the body as it posts, so register the body that was actually posted, not only the draft's.
import subprocess
def register_posted(out):
    gated = os.path.expanduser(os.environ.get('GATED_POSTS', '~/.claude/gated-posts.txt'))
    for repo, num, kind, cid in re.findall(r'github\.com/([\w.-]+/[\w.-]+)/(?:issues|pull)/(\d+)(?:#(issuecomment|discussion_r)-?(\d+))?', out):
        if not posted(repo, num):
            continue
        path = {'issuecomment': f'repos/{repo}/issues/comments/{cid}', 'discussion_r': f'repos/{repo}/pulls/comments/{cid}'}.get(kind, f'repos/{repo}/issues/{num}')
        try:
            r = subprocess.run(['gh', 'api', path, '--jq', '.body'], capture_output=True, text=True, timeout=20)
        except Exception:
            continue
        if r.returncode == 0 and r.stdout.strip():
            body = r.stdout[:-1] if r.stdout.endswith('\n') else r.stdout
            open(gated, 'a').write(hashlib.sha256(body.replace('\r\n', '\n').strip().encode()).hexdigest() + '\n')
register_posted(out)
# Count a posted design proposal per thread (pre-bash-guard asks for a finality map from the third on)
def body_files(t):
    a = prog(t)
    return [a[i + 1] for i in range(len(a) - 1) if a[i] in ('--body-file', '-F', '--field', '--input')] + \
        [x.split('=', 1)[1] for x in a if x.startswith('--body-file=')]
for s in segs:
    tg = target(s)
    if not tg or not tg[0] or not tg[1]:
        continue
    for f in body_files(s):
        f = os.path.expanduser(f[len('body='):] if f.startswith('body=') else f)
        f = f[1:] if f.startswith('@') else f
        try:
            flags = open(f + '.lint').read().split()
        except OSError:
            continue
        if flags[flags.index('--kind') + 1:][:1] == ['proposal'] and os.path.exists(f + '.posted'):
            open(os.path.expanduser('~/.claude/proposal-rounds.txt'), 'a').write(f'{tg[0]}#{tg[1]} {int(time.time())}\n')
reg = os.path.expanduser('~/.claude/gh-watch-dirs.txt')
dirs = [l.strip() for l in open(reg)] if os.path.exists(reg) else []
def lines(dr, f):
    p = os.path.join(dr, f)
    return [l.strip() for l in open(p)] if os.path.exists(p) else []
def live(dr):
    try:
        os.kill(int(lines(dr, 'gh-watch.pid')[0]), 0)
        return True
    except (IndexError, OSError, ValueError):
        return False
live_dirs = [dr for dr in dirs if live(dr)]
# The posting session's own dirs come first (gh-watch-start records the session): its Monitor tails only those, and an
# older dir can stay live after its session ended, kept by a forgotten repos.txt line
own = [dr for dr in live_dirs if d.get('session_id') and lines(dr, 'session')[:1] == [d['session_id']]]
found = {(repo, num, f'{repo} {num}') for repo, num in re.findall(r'github\.com/([\w.-]+/[\w.-]+)/(?:issues|pull)/(\d+)', out)} | \
    {('gitlab.com/' + repo, num, f"gitlab.com/{repo} {'!' if kind == 'merge_requests' else ''}{num}")  # gh-watch-start's GitLab line
     for repo, kind, num in re.findall(r'gitlab\.com/([\w.-]+(?:/[\w.-]+)+?)/-/(issues|work_items|merge_requests)/(\d+)', out)}  # glab prints new issues as work_items
for repo, num, line in found:
    if not posted(repo, num):
        continue
    home = next((dr for dr in live_dirs if line in lines(dr, 'threads.txt')), None)
    if not home:
        covering = [dr for dr in live_dirs if any(l.split()[:1] == [repo] for l in lines(dr, 'repos.txt') + lines(dr, 'threads.txt'))]
        home = ([dr for dr in own if dr in covering] + own + covering + live_dirs + [None])[0]
        if home:
            open(os.path.join(home, 'threads.txt'), 'a').write(line + '\n')
    # the thread now covers its repo there: a bare repo line left behind would keep the watcher from retiring
    if home and repo in lines(home, 'repos.txt'):
        p = os.path.join(home, 'repos.txt')
        keep = [l for l in open(p) if l.split('#', 1)[0].strip() != repo]
        with open(p + '.tmp', 'w') as f:
            f.writelines(keep)
        os.replace(p + '.tmp', p)
sys.exit(0)
