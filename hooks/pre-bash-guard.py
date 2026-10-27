#!/usr/bin/env python3
"""Claude Code PreToolUse hook (matcher: Bash). Exit 2 blocks the command; stderr goes to the agent.
Checks each simple command separately (shellcmd.parse: chains, substitutions, `bash -c`; heredoc bodies and quoted text are data).
It fails closed: a command it can't parse, a record it can't find or a state gh can't read blocks what it guards.
MERGEWORTHY_MERGE=reviewer blocks every `gh pr merge`."""
import json, re, sys, os, hashlib, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import failclosed
from shellcmd import parse, segments, prog, opt, api_call, new_post_drafts, branch_record, no_preflight, git_argv, operands, GUARDED
import steward, post_words, work_folder
def missing_steps(d):
    head = subprocess.run(['git', '-C', d, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
    rec = os.path.expanduser(f'~/.claude/pr-steps/{head}')
    # A maintainer's commits on top carry the last converged head's records, whatever their size: they get
    # reply §Maintainer commits' review, and the pipeline runs again only once the maintainer says they're done.
    # Only non-merge commits without the agent's Co-Authored-By: Claude trailer are skipped back over.
    for c in subprocess.run(['git', '-C', d, 'rev-list', '--first-parent', '--max-count=100', 'HEAD'], capture_output=True, text=True).stdout.split():
        if os.path.exists(os.path.expanduser(f'~/.claude/pr-steps/{c}')):
            rec = os.path.expanduser(f'~/.claude/pr-steps/{c}'); break
        parents, _, body = subprocess.run(['git', '-C', d, 'log', '-1', '--format=%P%x00%B', c], capture_output=True, text=True).stdout.partition('\0')
        if len(parents.split()) != 1 or re.search(r'^Co-Authored-By: Claude', body, re.M | re.I): break
    kinds = {l.split()[0] for l in open(rec)} if head and os.path.exists(rec) else set()
    kinds |= {'fresh'} if 'review' in kinds else set()  # records made before the six steps
    kinds |= {'shape'} if {'loopb', 'refactor'} <= kinds else set()  # records made before the shape pass
    missing = [k for k in ('verify', 'shape', 'reverify', 'fresh', 'gates') if k not in kinds]
    # the approach is chosen once per PR: recorded per repo and branch
    if head and not os.path.exists(branch_record(d, 'approach')):
        missing.insert(0, 'approach')
    return head, missing

def setting(name, default):
    """MERGEWORTHY_<name> from the environment, else from ~/.mergeworthy/settings.env (written at session start from the plugin's options)."""
    f = os.path.expanduser('~/.mergeworthy/settings.env')
    saved = dict(l.strip().split('=', 1) for l in open(f) if '=' in l) if os.path.exists(f) else {}
    return os.environ.get(f'MERGEWORTHY_{name}') or saved.get(f'MERGEWORTHY_{name}', default)
d = json.load(sys.stdin)
cmd = d.get('tool_input', {}).get('command', '')
cwd = d.get('cwd') or os.getcwd()
def block(msg):
    print(f"BLOCKED by pre-bash-guard: {msg}", file=sys.stderr); sys.exit(2)

def short_has(t, letter):  # -f, -9f, -fu ...
    return re.match(r'^-[A-Za-z0-9]*' + letter + r'[A-Za-z0-9]*$', t) is not None

def gated_file(p, has_cd, create=False):
    p = os.path.expandvars(os.path.expanduser(p))
    if not os.path.isabs(p):
        if has_cd:
            block(f"relative draft path {p} after a cd: use an absolute path")
        p = os.path.join(cwd, p)
    gate = p + '.gate'
    if not os.path.exists(p) or not os.path.exists(gate):
        block(f"no gate record for {p}: run post-lint + the review until CLEAN, then `gate-pass {p} <review-output>`")
    sha = hashlib.sha256(open(p, 'rb').read()).hexdigest()
    if sha != open(gate).read().split('\n')[0].strip():
        block(f"{p} changed after its gate: review it again and re-run gate-pass")
    if create:  # a new comment/issue/PR from this exact draft: only once (edits may repeat); post-bash-register writes .posted once it succeeded
        posted = p + '.posted'
        if os.path.exists(posted) and open(posted).read().strip() == sha:
            block(f"{p} was already posted: edit that post instead (PATCH / gh … edit)")

def gh_login():
    """[login, id] of the account gh pushes as, kept in ~/.claude/gh-user.txt for when gh can't answer; None when never read."""
    cache = os.path.expanduser('~/.claude/gh-user.txt')
    try:
        r = subprocess.run(['gh', 'api', 'user', '--jq', '.login + " " + (.id|tostring)'], capture_output=True, text=True, timeout=20)
        if r.returncode == 0 and len(r.stdout.split()) == 2:
            open(cache, 'w').write(r.stdout)
            return r.stdout.split()
    except (OSError, subprocess.TimeoutExpired):
        pass
    try: return open(cache).read().split()[:2] or None
    except OSError: return None

def check_commit_identity(overrides, git_dir):
    """Commits are authored as the GitHub account that pushes them, never the global git identity (a user checkout's worktrees share its config)."""
    name = overrides.get('user.name') or subprocess.run(['git', '-C', git_dir, 'config', 'user.name'], capture_output=True, text=True).stdout.strip()
    who = gh_login()
    if not who:
        block("gh can't say which account pushes (`gh auth status`), so the commit's author can't be checked: fix gh's login, then commit")
    login, uid = who
    email = overrides.get('user.email') or subprocess.run(['git', '-C', git_dir, 'config', 'user.email'], capture_output=True, text=True).stdout.strip()
    if name != login or email != f'{uid}+{login}@users.noreply.github.com':
        block(f"commit author would be {name!r} <{email}>: commit as the pushing account, `git -c user.name={login} -c user.email={uid}+{login}@users.noreply.github.com commit ...`")


def watch_dirs():
    """Watch dirs (gh-watch-start) whose daemon is alive."""
    reg = os.path.expanduser('~/.claude/gh-watch-dirs.txt')
    live = []
    for d in (l.strip() for l in open(reg)) if os.path.exists(reg) else ():
        try:
            pid = open(os.path.join(d, 'gh-watch.pid')).read().strip()
            if 'gh-watch-daemon' in subprocess.run(['ps', '-p', pid, '-o', 'command='], capture_output=True, text=True).stdout: live.append(d)
        except (OSError, ValueError):
            pass
    return live

def need_watch(repo):
    """Opening an issue or PR starts the live loop (mergeworthy:task step 5): a running watcher must cover the repo (post-bash-register adds
    the new thread). A comment on an existing thread isn't blocked here: post-bash-register adds that thread, and stop-lint requires a watcher's Monitor after any post."""
    if setting('WATCHER', 'on') != 'on': return
    repos = [repo] if isinstance(repo, str) else [r for r in repo if r]
    if not repos:
        block("can't tell which repo this acts on, so the watcher check can't run: pass -R <owner/repo>")
    def lines(d, f):
        return [l.strip() for l in open(os.path.join(d, f))] if os.path.exists(os.path.join(d, f)) else []
    covering = [d for d in watch_dirs() if any(l.split()[:1] in ([r] for r in repos) for l in lines(d, 'repos.txt') + lines(d, 'threads.txt'))]
    if not covering:
        block(f"no running watcher covers {' or '.join(repos)}: `gh-watch-start <your work folder> {repos[0]}`, arm the Monitor it prints, then retry (mergeworthy:task step 5)")

def check_turn(repo, num, args=()):
    """post §Thread rules: at most two comments in a row: while your last two comments on a thread have no reply after them and the last
    is under 3 hours old, a third stacks on them: edit the last one instead. After 3 hours, the third is the wait ping. The agent and the user may
    share one login, so a comment is the agent's only when its body was gated (gate-pass writes ~/.claude/gated-posts.txt)."""
    if '--help' in args or '-h' in args:
        return
    def api(path, jq, issue_404=False):
        """gh's answer; an issue's 404 on a pulls endpoint is none. Anything else gh can't read blocks: the rule can't be checked."""
        try: r = subprocess.run(['gh', 'api', path, '--jq', jq], capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.TimeoutExpired) as e: r = subprocess.CompletedProcess([], 1, '', str(e))
        if r.returncode == 0: return r.stdout
        if issue_404 and 'HTTP 404' in r.stderr: return ''
        block(f"gh couldn't read {repo}#{num} ({path}: {r.stderr.strip()[:160]}), so post §Thread rules (two comments in a row) can't be checked: retry once gh answers")
    n = int(api(f'repos/{repo}/issues/{num}', '.comments').strip() or 0)
    if n < 2: return
    page = lambda p: json.loads(api(f'repos/{repo}/issues/{num}/comments?per_page=100&page={p}', '[.[] | {body, created: .created_at, url: .html_url, user: .user.login}]') or '[]')
    p = (n - 1) // 100 + 1
    last = page(p)
    if len(last) < 2 and p > 1: last = page(p - 1) + last
    last = last[-2:]
    reviews = api(f'repos/{repo}/pulls/{num}/reviews?per_page=100', '.[].submitted_at', issue_404=True).split()
    me = api('user', '.login').strip()
    # a maintainer's push after your comments answers them too (their commits deserve a review comment)
    reviews += [d for l in api(f'repos/{repo}/pulls/{num}/commits?per_page=100', '.[] | "\\(.author.login) \\(.commit.committer.date)"', issue_404=True).splitlines()
                for who, d in [l.split(' ', 1)] if who != me and who != 'null']
    f = os.path.expanduser(os.environ.get('GATED_POSTS', '~/.claude/gated-posts.txt'))
    gated = set(open(f).read().split()) if os.path.exists(f) else set()
    norm = lambda b: hashlib.sha256((b or '').replace('\r\n', '\n').strip().encode()).hexdigest()
    # someone else's comment is a reply, even when its text matches a gated draft (e.g. a quoted parent)
    if len(last) < 2 or not all(c.get('user') == me and norm(c['body']) in gated for c in last):
        return
    import datetime
    when = lambda t: datetime.datetime.fromisoformat(t.replace('Z', '+00:00'))
    if (datetime.datetime.now(datetime.timezone.utc) - when(last[-1]['created'])).total_seconds() >= 3 * 3600 or any(when(r) > when(last[-1]['created']) for r in reviews if r != 'null'):
        return
    block(f"your last two comments on {repo}#{num} have no reply yet ({last[-1]['url']}): edit the last one instead of posting a third; "
          "at most two comments in a row; after 3 hours without a reply, the wait ping may follow (mergeworthy:post §Thread rules)")


def check_finality(repo, num, files):
    """A design thread that has had two proposal rounds needs the finality pass's thread map before the third (mergeworthy:finality).
    post-bash-register counts posted `--kind proposal` drafts per thread in ~/.claude/proposal-rounds.txt; the map is
    <work folder>/maps/<owner>-<repo>-<number>.md (the root holds drafts/), and must be newer than the last proposal."""
    if not repo or not str(num).isdigit(): return
    log = os.path.expanduser('~/.claude/proposal-rounds.txt')
    rounds = [int(l.split()[1]) for l in open(log) if l.split()[:1] == [f'{repo}#{num}']] if os.path.exists(log) else []
    if len(rounds) < 2: return
    for f in files:
        f = os.path.expandvars(os.path.expanduser(f[5:] if f.startswith('body=') else f)).lstrip('@')
        f = f if os.path.isabs(f) else os.path.join(cwd, f)
        try: flags = open(f + '.lint').read().split()
        except OSError: continue
        if flags[flags.index('--kind') + 1:][:1] != ['proposal']: continue
        root = f
        while root != '/' and os.path.basename(root) != 'drafts': root = os.path.dirname(root)
        root = os.path.dirname(root) if root != '/' else os.path.dirname(os.path.dirname(f))
        m = os.path.join(root, 'maps', f"{repo.replace('/', '-')}-{num}.md")
        if os.path.exists(m) and os.path.getmtime(m) > rounds[-1]: continue
        block(f"{repo}#{num} has had {len(rounds)} proposal rounds: run the finality pass (mergeworthy:finality step 1, a drifted design thread) before this reply, "
              f"write its thread map with the invariants list to {m} (newer than your last proposal), update the thread's WIP comment (Agreed with permalinks, Open; mergeworthy:design §WIP comment) from it, and let this reply say 'I updated the [WIP comment](link)' instead of restating the design")

def thread_of_ref(repo, ref):
    """owner/repo#N from a gh issue/pr argument (number or URL) or None."""
    m = re.search(r'github\.com/([\w.-]+/[\w.-]+)/(?:issues|pull)/(\d+)', ref or '')
    if m: return f'{m.group(1)}#{m.group(2)}'
    return f'{repo}#{ref}' if repo and str(ref).isdigit() else None

# gh issue/pr options that take a value: the word after one is not the command's target
VALUED = {'-R', '--repo', '-F', '--body-file', '-b', '--body', '-t', '--title', '-B', '--base', '-H', '--head', '-l', '--label', '-a', '--assignee',
          '-r', '--reviewer', '-p', '--project', '-m', '--milestone', '-c', '--comment', '-T', '--template', '-s', '--state', '-q', '--jq',
          '--add-label', '--remove-label', '--add-assignee', '--remove-assignee', '--add-reviewer', '--remove-reviewer', '--add-project', '--remove-project'}
def post_target(group, rest, run_dir):
    """(owner/repo, N) a `gh issue|pr <sub> <rest>` command acts on: its number or URL argument, or for gh pr its branch argument or the current
    branch's PR (`gh pr view`). Every check of a post on a thread reads its target here; one it can't tell blocks, as no check could run."""
    repo = re.sub(r'^(?:https?://)?github\.com/', '', (opt(rest, ['--repo', '-R']) or [None])[-1] or '') or cwd_repo(run_dir)  # gh takes [HOST/]OWNER/REPO
    ref = next((x for i, x in enumerate(rest) if not x.startswith('-') and (i == 0 or rest[i - 1] not in VALUED)), None)
    if t := thread_of_ref(repo, ref): return tuple(t.split('#'))
    n = ''
    if group == 'pr':
        try:
            r = subprocess.run(['gh', 'pr', 'view', *([ref] if ref else []), *(['-R', repo] if ref and repo else []), '--json', 'number', '--jq', '.number'],
                               cwd=run_dir, capture_output=True, text=True, timeout=20)
            n = r.stdout.strip() if r.returncode == 0 else ''
        except (OSError, subprocess.TimeoutExpired): pass
    if not (repo and n.isdigit()):
        block(f"can't tell which thread this `gh {group}` command acts on, so its checks can't run: pass the number or URL, and -R <owner/repo>")
    return repo, n

def check_context(thread, files):
    """post step 1: a post on a thread is drafted from its whole record: <draft dir>/thread-context.md, made by `thread-context <repo#N> --out <dir>/thread-context.md`,
    for this thread and recording its latest human comment (the tool's --verify). Tracker drafts are exempt; a thread gh can't read blocks."""
    if not thread: return
    tc = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'bin', 'thread-context')
    for f in files:
        f = os.path.expandvars(os.path.expanduser(f[5:] if f.startswith('body=') else f)).lstrip('@')
        f = f if os.path.isabs(f) else os.path.join(cwd, f)
        try: flags = open(f + '.lint').read().split()
        except OSError: flags = []
        if '--kind' in flags and flags[flags.index('--kind') + 1:][:1] == ['tracker']: continue
        parent = re.sub(r'\.md$', '', f) + '.parent.md'
        tcf = os.path.join(os.path.dirname(f), 'thread-context.md')
        # the gate record names the thread context the draft was written and reviewed from (gate-pass); one made later is not it
        recorded = [l[3:].strip() for l in (open(f + '.gate').read().splitlines() if os.path.exists(f + '.gate') else []) if l.startswith('tc ')]
        if os.path.exists(tcf) and recorded != [hashlib.sha256(open(tcf, 'rb').read()).hexdigest()]:
            block(f"{tcf} isn't the one {f} was gated with: draft from thread-context.md before the review, then gate-pass (mergeworthy:post step 1)")
        cmd = [tc, '--verify', tcf, '--target', thread] + (['--parent', parent] if os.path.exists(parent) else [])
        try: r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        except (OSError, subprocess.TimeoutExpired) as e: r = subprocess.CompletedProcess(cmd, 1, '', f"thread-context --verify couldn't run: {e}")
        if r.returncode != 0:
            block(f"{r.stderr.strip() or f'thread-context --verify exited {r.returncode}'} (mergeworthy:post step 1: draft from thread-context.md, give the reviewer the same file)")

def gh_json(path):
    """`gh api <path>` parsed, or None when gh can't read it."""
    try:
        r = subprocess.run(['gh', 'api', path], capture_output=True, text=True, timeout=20)
        return json.loads(r.stdout) if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, ValueError): return None

def promised(repo, num, drafts):
    """An open `PROMISED <repo>#<num>: …refactor…` line in proposals-open.md of this session's watch dir (gh-watch-dirs.txt, its `session`
    file), or above a draft's folder, as gate-pass finds it. It proves only that the line exists: not that a holding reply was posted, nor
    its time; stop-lint holds the session to a time the line names."""
    sid = d.get('session_id') or os.environ.get('CLAUDE_CODE_SESSION_ID')
    reg = os.path.expanduser('~/.claude/gh-watch-dirs.txt')
    dirs = [w for w in (l.strip() for l in (open(reg) if os.path.exists(reg) else [])) if w and sid and (open(os.path.join(w, 'session')).read().strip()
            if os.path.isfile(os.path.join(w, 'session')) else '') == sid]
    dirs += [os.path.dirname(os.path.dirname(os.path.realpath(os.path.join(cwd, os.path.expanduser(f))))) for f in drafts]
    line = re.compile(rf'^PROMISED\s+(?:{re.escape(repo)})?#{num}\b.*\brefactor', re.I | re.M)
    return any(os.path.isfile(po := os.path.join(w, 'proposals-open.md')) and line.search(open(po).read()) for w in dirs)

ASKS = os.path.expanduser('~/.claude/refactor-asks.txt')  # the watcher's: <time> <PR head the scan saw> <owner/repo#N> <comment URL>
def check_refactor_ask(repo, num, comment, drafts=()):
    """A maintainer's refactor ask (the newest entry for this PR in refactor-asks.txt) is answered by a pass: a non-carry shape record with a
    later time, on the PR's head or a commit on the first page of its commits. Until one exists, a comment goes out only with the session's
    PROMISED line for the result (promised()); `gh pr ready` and a body edit wait for the pass. Only the record is checked: whether the post
    shows that pass's result is the post review's (delegate/post-review.md). A PR gh can't read blocks."""
    if not repo or not str(num).isdigit(): return
    asks = sorted(l.split() for l in (open(ASKS) if os.path.exists(ASKS) else []) if l.split()[2:3] == [f'{repo}#{num}'])
    if not asks: return
    pr = gh_json(f'repos/{repo}/pulls/{num}')
    if not isinstance(pr, dict):
        block(f"gh couldn't read {repo}#{num}, so whether its refactor ask ({asks[-1][3]}) was answered by a pass can't be checked: retry once gh answers")
    t, _, _, url = asks[-1][:4]
    commits = gh_json(f'repos/{repo}/pulls/{num}/commits?per_page=100')
    shas = {c.get('sha') for c in commits if isinstance(c, dict)} if isinstance(commits, list) else set()
    if any(at > t for sha in shas | {(pr.get('head') or {}).get('sha')} for _, _, at in real_passes(sha)): return
    if comment and promised(repo, num, drafts): return  # the post review checks the comment says the result is still to come
    block(f"{url} asks for a refactor pass ({t}) and no pass on this PR was recorded after it: fetch the PR's head, run the pass on it "
          "(converge step 2, delegate/shape.md), then record its report there with `pr-steps shape <report>`, on the unchanged head when the pass changes nothing. " +
          (f"To comment before it (a holding reply, a commit review), first add 'PROMISED {repo}#{num}: the refactor pass's result by <time> (<draft>)' "
           "to proposals-open.md in your watch dir" if comment else "`gh pr ready` and a body edit wait for the recorded pass"))

def real_passes(sha):
    """The (step, report, time) shape records of sha whose report is a pass, not a carry."""
    rec = os.path.expanduser(f'~/.claude/pr-steps/{sha}')
    rows = [l.split()[:3] for l in open(rec) if len(l.split()) >= 3] if sha and os.path.isfile(rec) else []
    return [r for r in rows if r[0] == 'shape' and os.path.isfile(r[1]) and 'carries the pass of' not in open(r[1], errors='replace').read()]

def cwd_repo(run_dir):
    import subprocess
    url = subprocess.run(['git', '-C', run_dir, 'remote', 'get-url', 'origin'], capture_output=True, text=True).stdout.strip()
    m = re.search(r'github\.com[:/]([\w.-]+/[\w.-]+?)(\.git)?$', url)
    return m.group(1) if m else None

def gitlab_repo(a, run_dir):
    """`gitlab.com/<namespace>/<project>` a glab command acts on: its -R value (a path or URL), else the cwd's origin."""
    repo = (opt(a, ['--repo', '-R']) or [None])[-1]
    if repo:
        repo = re.sub(r'^(https://)?gitlab\.com/', '', repo)
    else:
        url = subprocess.run(['git', '-C', run_dir, 'remote', 'get-url', 'origin'], capture_output=True, text=True).stdout.strip()
        repo = (re.search(r'gitlab\.com[:/](.+?)(?:\.git)?$', url) or [None, None])[1]
    return 'gitlab.com/' + repo.strip('/') if repo and '://' not in repo else None

def check_compose(env, t):
    """delegate/agent.md §Machine, own ports: a compose stack you start publishes no fixed host port and pins no container name;
    netns-run doesn't isolate what the Docker daemon publishes. A config that can't be read blocks (the stack wouldn't start either)."""
    n = 2 if os.path.basename(t[0]) == 'docker' else 1
    if t[1:n] not in ([], ['compose']) or env.get('MERGEWORTHY_HOST_PORTS') == 'user-asked': return
    keep = ('-f', '--file', '-p', '--project-name', '--profile', '--project-directory', '--env-file')
    a, glob = t[n:], []
    while a and a[0].startswith('-'):
        k = 2 if a[0] in keep + ('--ansi', '--parallel', '--progress') else 1
        if a[0].split('=')[0] in keep: glob += a[:k]
        a = a[k:]
    if not (a[:1] == ['up'] or a[:1] == ['run'] and '--service-ports' in a): return
    try:
        r = subprocess.run(t[:n] + glob + ['config', '--format', 'json'], cwd=run_dir, env={**os.environ, **env}, capture_output=True, text=True, timeout=30)
        svcs = json.loads(r.stdout)['services'] if r.returncode == 0 else {}
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as e:
        block(f"`{' '.join(t[:n] + glob)} config` couldn't be read ({e}), so its ports can't be checked: fix the config, then start it")
    if r.returncode != 0:
        block(f"`{' '.join(t[:n] + glob)} config` failed ({r.stderr.strip()[:200]}), so its ports can't be checked: fix the config, then start it")
    bad = [f"{s} container_name {c['container_name']}" for s, c in svcs.items() if c.get('container_name')] + \
          [f"{s} host port {p['published']}" for s, c in svcs.items() for p in c.get('ports') or [] if p.get('published')]
    if bad:
        block(f"this stack takes what another session's stack needs ({', '.join(bad)}), and netns-run doesn't isolate ports Docker publishes. "
              "Start it with a unique project name (-p or COMPOSE_PROJECT_NAME) and the override the project file's Running the app → Start names "
              "(`ports: !override [\"<container port>\"]` for Docker-assigned ports, found with `docker compose port <svc> <port>`; `ports: !reset []` where the host needs none; "
              "`container_name: !reset null`) (mergeworthy delegate/agent.md, Machine). Only when the user asked for the stack on its usual ports: prefix MERGEWORTHY_HOST_PORTS=user-asked")

def check_steward(repo):
    """A declared steward owns the mergeworthy repo: other sessions report a problem to it instead of committing."""
    st = steward.read()
    if st and re.search(r'github\.com[:/]nitedani/mergeworthy(\.git)?$', subprocess.run(['git', '-C', repo, 'remote', 'get-url', 'origin'],
            capture_output=True, text=True).stdout.strip()) and not steward.is_steward(d.get('session_id'), d.get('cwd')):
        block(f"only the steward session (named in ~/.mergeworthy/steward; mergeworthy:rules step 2) commits to mergeworthy: write the fix you'd make as one line in {st[0]}/inbox.md")

def under_t3():
    """The session's claude process was started by T3 Code with T3's MCP server: its delegate_task runs other providers' agents."""
    pid = os.getppid()
    while pid > 1:
        ppid, _, args = subprocess.run(['ps', '-o', 'ppid=,args=', '-p', str(pid)], capture_output=True, text=True).stdout.strip().partition(' ')
        if os.path.basename(args.split(' ', 1)[0]) == 'claude':
            return '"t3-code"' in args
        pid = int(ppid or 0)
    return False

def title_setter(repo, num):
    """(login, when) of whoever else retitled the PR last, from its timeline; None when it's ours or nobody's. A timeline or
    login gh can't read blocks: whose title it is can't be told."""
    def api(path):
        try:
            r = subprocess.run(['gh', 'api', path, '--paginate'], capture_output=True, text=True, timeout=20)
            return json.loads(r.stdout) if r.returncode == 0 else None
        except (subprocess.TimeoutExpired, ValueError, OSError): return None
    me = os.environ.get('GH_WATCH_ME') or (api('user') or {}).get('login')
    events = api(f'repos/{repo}/issues/{num}/timeline?per_page=100')
    if not me or not isinstance(events, list):
        block(f"gh couldn't read {repo}#{num}'s timeline or your login, so who set its title can't be told: retry once gh answers (mergeworthy:pull-request step 7)")
    renames = [e for e in events if e.get('event') == 'renamed']
    last = renames[-1] if renames else None
    login = ((last or {}).get('actor') or {}).get('login')
    return (login, last.get('created_at')) if login and login != me else None

def by_agent():
    """A subagent's command: Claude Code's (agent_id), or a T3 child's (its thread has a parent)."""
    return bool(d.get('agent_id')) or len(steward.threads(d.get('session_id'))) > 1

RECORDS = os.path.realpath(os.path.expanduser('~/.claude/pr-steps')) + os.sep
push_urls = []  # where this command's pushes go (pushed()), for the watcher check

def git_head(d):
    return subprocess.run(['git', '-C', d, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()

def pr_state(d):
    """'ready', 'draft' or 'none' for the PR of d's branch; gh failing any other way blocks: the push gates depend on it."""
    try:
        r = subprocess.run(['gh', 'pr', 'view', '--json', 'isDraft,state', '--jq', 'if .state != "OPEN" then "none" elif .isDraft then "draft" else "ready" end'],
                           cwd=d, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as e:
        r = subprocess.CompletedProcess([], 1, '', str(e))
    if r.returncode == 0 and r.stdout.strip() in ('ready', 'draft', 'none'): return r.stdout.strip()
    if 'no pull requests found' in r.stderr or 'known GitHub host' in r.stderr: return 'none'  # no PR, or a checkout of no GitHub repo
    block(f"gh couldn't read this branch's PR ({r.stderr.strip()[:160]}), so its push gates can't be checked: retry once gh answers")

def pushed(d, rest):
    """The commits a `git push <rest>` from d publishes to a remote that isn't a local path; [] for a delete or tags only."""
    if '--delete' in rest or '-d' in rest: return []
    if {'--all', '--branches', '--mirror'} & set(rest):
        block("push one branch, named (`git push <remote URL> <branch>`): each pushed head's records are checked (mergeworthy:merging step 1)")
    pos, skip = [], False
    for x in operands(rest):
        if skip: skip = False
        elif x in ('-o', '--push-option', '--repo', '--receive-pack', '--exec'): skip = True
        elif not x.startswith('-'): pos.append(x)
    git = lambda *a: subprocess.run(['git', '-C', d, *a], capture_output=True, text=True)
    remote = pos[0] if pos else (git('rev-parse', '--abbrev-ref', '@{push}').stdout.strip().split('/')[0] or 'origin')
    url = git('remote', 'get-url', remote).stdout.strip() or remote
    push_urls.append(url)
    if re.match(r'(?:file://|/|\.{1,2}/|~)', url) and not re.match(r'[\w.-]+@[\w.-]+:', url):
        return []  # a local path publishes nothing a reviewer or CI sees
    specs = pos[1:] or ([] if '--tags' in rest else ['HEAD'])
    out = []
    for spec in specs:
        src = spec.lstrip('+').split(':', 1)[0]
        if not src or git('show-ref', '--verify', '-q', f'refs/tags/{src}').returncode == 0 or src.startswith('refs/tags/'):
            continue  # a delete (:dst), or a tag
        sha = git('rev-parse', '--verify', '-q', f'{src}^{{commit}}').stdout.strip()
        if not sha:
            block(f"`{src}` in this push names no commit here, so what it publishes can't be checked: push a branch or commit of this checkout")
        out.append(sha)
    return out

def task_folder(top):
    """The task's work folder holding checkout top (task §Files): ~/.mergeworthy/work/<task>/, or an older ~/<name>-work/ holding it or beside it."""
    if wf := work_folder.of(top): return wf
    home, p = os.path.realpath(os.path.expanduser('~')), os.path.realpath(top)
    while p not in (home, '/'):
        if os.path.dirname(p) == home and p.endswith('-work'): return p
        p = os.path.dirname(p)
    return top + '-work' if os.path.isdir(top + '-work') else None

def failing_jobs(urls):
    """{job name: PR URL} of every failing CI job on these PRs' heads; a PR whose checks gh can't read blocks."""
    out = {}
    for u in urls:
        try:
            r = subprocess.run(['gh', 'pr', 'checks', u, '--json', 'name,bucket'], capture_output=True, text=True, timeout=30)
            rows = [] if 'no checks reported' in r.stderr else json.loads(r.stdout)
        except (OSError, subprocess.TimeoutExpired, ValueError):
            block(f"gh couldn't read the CI of {u}, so whether this head reproduces its failing jobs can't be checked: retry once gh answers")
        out.update({x.get('name'): u for x in rows if isinstance(x, dict) and x.get('bucket') in ('fail', 'cancel')})
    return out

def check_workflow(what, d, commits):
    """task steps 2-3 and pull-request steps 1 and 6 by their records, before every push of commits and every `gh pr create`,
    draft or not, whichever skills the session opened: the checkout is in the task's work folder, its scope.md opens with the
    Tier line and lists the asks as checkboxes, and each pushed head has a passing `pr-steps quick` (or `gates`) log whose
    lines name every failing CI job of the PRs its open boxes link and of this branch's PR, so a CI fix is reproduced here first."""
    top = subprocess.run(['git', '-C', d, 'rev-parse', '--show-toplevel'], capture_output=True, text=True).stdout.strip()
    if not top:
        if what == 'this push': return  # outside a work tree git itself refuses the push
        block(f"{what} runs from the PR branch's checkout (mergeworthy:pull-request step 7), so its records can be checked")
    wf = task_folder(top)
    if not wf:
        block(f"{top} isn't in a task's work folder: {what} runs from a worktree in ~/.mergeworthy/work/<task>/ (mergeworthy:task §Files, pull-request step 1)")
    scope = os.path.join(wf, 'scope.md')
    text = open(scope, errors='replace').read() if os.path.isfile(scope) else ''
    if not re.match(r'\s*Tier:\s*[0SML]\b', text) or not re.search(r'^\s*[-*] \[[ xX]\] ', text, re.M):
        block(f"{scope} needs line 1 `Tier: <0|S|M|L>, because <signals>` and a checkbox per ask, with its link (mergeworthy:task steps 2-3), before {what}")
    prs = sorted(set(re.findall(r'https://github\.com/[\w.-]+/[\w.-]+/pull/\d+', '\n'.join(re.findall(r'^\s*[-*] \[ \] .*$', text, re.M)))))
    if what == 'this push' and pr_state(top) != 'none':
        prs.append(subprocess.run(['gh', 'pr', 'view', '--json', 'url', '--jq', '.url'], cwd=top, capture_output=True, text=True, timeout=20).stdout.strip())
    jobs = failing_jobs([u for u in dict.fromkeys(prs) if u])
    if what == 'this push':  # the PR this push updates is answered by a watcher on its repo (task step 5): upstream, origin or the fork pushed to
        urls = subprocess.run(['git', '-C', top, 'remote', '-v'], capture_output=True, text=True).stdout + ' ' + ' '.join(push_urls)
        repos = sorted({m[0] or 'gitlab.com/' + m[1] for m in re.findall(r'github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?(?:\s|$)|gitlab\.com[:/]([\w./-]+?)(?:\.git)?(?:\s|$)', urls)})
        if repos: need_watch(repos)  # a host no watcher reads (neither GitHub nor GitLab) has nothing to arm
    for sha in commits:
        rec = os.path.expanduser(f'~/.claude/pr-steps/{sha}')
        logs = [l.split()[1] for l in (open(rec) if os.path.isfile(rec) else []) if l.split()[:1] in (['quick'], ['gates']) and len(l.split()) > 1]
        if not logs:
            block(f"{sha[:10]} has no passing gate record: run the quick gates on it (format, type-check, units, and each failing CI job's command: "
                  f"code §Gates), installing whatever they need, then `pr-steps quick <log>`, before {what}. CI is not where a change is first checked")
        ran = '\n'.join(open(l, errors='replace').read() for l in logs if os.path.isfile(l)).lower()
        missed = [j for j in jobs if not re.search(re.escape(j.lower()) + r'.* -> exit 0\b', ran)]
        if missed:
            block(f"these CI jobs fail ({', '.join(sorted(set(jobs[j] for j in missed)))}) and {sha[:10]}'s gate log has no passing line naming them: "
                  + '; '.join(f'"{j}"' for j in missed) + ". Run each job's command here on this head (its workflow file names it; install what it needs), "
                  "add `<job name>: <command> -> exit 0` to the log, and `pr-steps quick <log>` again (code §Gates)")

NEED_DRAFT ="post from a draft file (--body-file /abs/drafts/<name>.md, -F body=@/abs/drafts/<name>.md or --input) that passed the gate"

def check(t, has_cd):
    env = dict(x.split('=', 1) for x in t[:len(t) - len(prog(t))] if re.match(r'^\w+=', x))
    t = prog(t)
    if not t: return
    p, a = os.path.basename(t[0]), t[1:]
    if p == 'codex' and ('exec' in a or a[:1] == ['e']) and under_t3():
        block("under T3 Code, start Codex through T3, where the user sees it: delegate_task with target {providerInstanceId: codex, "
              "model: <the review model from orchestrator_capabilities>}, the prompt file's path in the task, a new delegate_task per review round (mergeworthy:delegate §Reviewers)")
    if p in ('docker', 'docker-compose'):
        check_compose(env, t)
    # A credential file printed to the tool output lands in the transcript (an npm token, 2026-10-14)
    CRED = r'(?:^|/)(?:\.npmrc|\.netrc|\.pypirc|\.git-credentials|hosts\.yml|credentials(?:\.json)?|id_(?:rsa|ed25519|ecdsa)|\.config/pnpm/(?:config\.yaml|rc))$'
    if p in ('cat', 'head', 'tail', 'less', 'more', 'bat', 'sed', 'awk', 'grep', 'rg', 'cut', 'strings', 'xxd', 'od', 'base64', 'jq', 'yq', 'python3', 'node') and any(
            re.search(CRED, os.path.expanduser(x)) and os.path.isfile(os.path.expanduser(x)) for x in a if not x.startswith('-')) and not (
            p in ('grep', 'rg') and any(re.fullmatch(r'-\w*[clqL]\w*|--count|--quiet|--files-with-matches', x) for x in a)):
        block("that file holds credentials, and printing it puts them in the transcript. Check a setting without its value "
              "(`grep -c '^//registry' <file>`, `npm config get registry`), or ask the user")
    # The posting gate compares draft, parent, thread record and review by their times: setting a time makes a stale record pass
    if p == 'touch' and any(x in ('-d', '-t', '-r') or x.startswith(('--date', '--reference')) or (re.fullmatch(r'-[a-z]+', x) and set(x[1:]) & set('dtr')) for x in a) \
            and ('drafts/' in cmd or any('drafts/' in os.path.abspath(os.path.expanduser(x)) for x in a if not x.startswith('-'))):
        block("never set a draft's file times: the posting gate reads them. Rebuild the record instead (`thread-context <owner/repo#N> --out <its folder>/thread-context.md`), "
              "re-save the draft, and run its review again (mergeworthy:post steps 1-4)")
    if p == 'pgrep' and any(x == '--full' or (not x.startswith('--') and short_has(x, 'f')) for x in a):
        block("never pgrep -f: it matches its own command line and other sessions' processes; wait on the PID you started (`kill -0 <pid>`) or its port")
    if p == 'killall' or (p == 'pkill' and any(x == '--full' or (not x.startswith('--') and short_has(x, 'f')) for x in a)):
        block("never pkill -f / killall: kill your own processes by PID or port")
    if p == 'kill':
        for x in a:
            if x.isdigit():
                try: argv = open(f'/proc/{x}/cmdline', 'rb').read().split(b'\0')
                except OSError: continue
                if any(os.path.basename(v.decode(errors='replace')) == 'claude' for v in argv[:2]) and b'stream-json' in b' '.join(argv):
                    block(f"PID {x} is a running agent (a claude session), not a command: never kill it. Read its task status and latest runs; "
                          "a turn that ended or 'waiting_for_children' is alive. Stop it through its task (interrupt) only after that, "
                          "and when two run the same job keep the one with the most progress")
    if p == 'git':
        repo, overrides, sub, rest = git_argv(t, run_dir)
        if sub in ('commit', 'push'):
            check_steward(repo)
        if sub == 'commit':
            if why := no_preflight(repo):
                block(why)
            check_commit_identity(overrides, repo)
        if sub == 'stash':
            first = rest[0] if rest else ''
            ok = first in ('list', 'show', 'apply', 'branch', 'create', 'store') or \
                 (first == 'drop' and len(rest) > 1) or \
                 (first in ('push', 'save', '') or first.startswith('-')) and bool(opt(rest, ['-m', '--message']) or (first == 'save' and len(rest) > 1))
            if not ok:
                block("never bare git stash / pop / drop / clear: use a WIP commit, or `git stash push -u -m <tag>` + apply <sha>, then drop that entry by its ref")
        if sub == 'push' and '--help' not in rest and '-h' not in rest:
            leases = [x for x in rest if x.startswith('--force-with-lease')]
            force = any(x in ('--force', '--mirror') or (not x.startswith('--') and x.startswith('-') and short_has(x, 'f'))
                        or (x.startswith('+') and len(x) > 1) for x in rest)
            if force or any(not re.match(r'^--force-with-lease=\S+:\S+$', x) for x in leases):
                block("force-push only with --force-with-lease=<branch>:<sha you last pushed>, after checking others' commits")
            commits = pushed(repo, rest)
            if commits:
                check_workflow('this push', repo, commits)
                head, missing = missing_steps(repo)
                if missing and pr_state(repo) == 'ready':
                    block(f"this branch's PR is out of draft and HEAD {head[:10]} has no pr-steps {', '.join(missing)} record (approach: pull-request step 5, once per branch): run converge's pipeline on it first (each step ends with its `pr-steps <step> <output>`), or `gh pr ready --undo` while it converges")
    if p in ('curl', 'wget', 'http', 'https', 'xh') and any(re.search(r'\bapi\.github\.com\b|github\.com/api/', x) for x in a) and \
            any(re.fullmatch(r'-X|--request|-d|--data[\w-]*|-F|--form|--json|-T|--upload-file|--method|POST|PATCH|PUT|DELETE|-\w*[dXFT]', x) or re.match(r'--(?:request|method)=', x) for x in a):
        block("a GitHub write goes through gh, where the posting gate checks it (mergeworthy:post): use `gh api` with the draft file")
    if p == 'gh' and a[:1] == ['pr'] and a[1:2] in (['create'], ['edit']) and '--help' not in a and '-h' not in a:
        # a title typed inline skips every reviewed file: it is drafted in a file, like the body
        if any(not re.fullmatch(r'\$\(cat \S+\)', v) for v in opt(a[2:], ['--title', '-t'])):
            block('the PR title is typed inline: write it to <work folder>/drafts/title.md in the repo\'s form (its last 10 merged titles) '
                  'and pass --title "$(cat <that file>)" (mergeworthy:pull-request step 7)')
        if a[1] == 'edit' and opt(a[2:], ['--title', '-t']) and (who := title_setter(*post_target('pr', a[2:], run_dir))):
            block(f"{who[0]} set this PR's title ({who[1]}): it is their decision. Keep it, or ask them on the PR first (mergeworthy:pull-request step 7)")
    # A review's verdict is the reviewer's final message, which it writes itself (`codex exec -o`, an agent's output file); an agent's stdout is it too
    redirected = [] if p in ('claude', 'codex') else [t[i + 1] for i in range(len(t) - 1) if re.fullmatch(r'\d*>>?|&>>?|>\|', t[i])]
    files = [x for x in a if not x.startswith('-')]
    written = redirected + (files if p == 'tee' or p == 'sed' and any(re.fullmatch(r'-\w*i\w*|--in-place(=.*)?', x) for x in a) else
                            files[-1:] if p in ('cp', 'mv', 'install') else [])
    if any(os.path.realpath(os.path.join(run_dir, os.path.expanduser(x))).startswith(RECORDS) for x in written):
        block("the step records in ~/.claude/pr-steps are written by `pr-steps <step> <its output>` alone, which checks the output first")
    if any(x.endswith('.review.out') for x in written) and not by_agent():
        block("a review's output is the reviewer's final message, written by the reviewer: `codex exec -o <out>`, or the agent writes <out> itself. "
              "Never write a verdict yourself (mergeworthy:delegate §Reviewers, post step 3)")
    if p == 'gh' and a[:2] == ['pr', 'ready'] and '--undo' not in a:
        check_refactor_ask(*post_target('pr', a[2:], run_dir), comment=False)
    if p == 'gh' and a[:2] == ['pr', 'create'] and '--help' not in a and '-h' not in a:
        check_workflow('`gh pr create`', run_dir, [git_head(run_dir)])
    if (p == 'gh' and len(a) >= 2 and a[0] == 'pr' and ((a[1] == 'create' and '--draft' not in a and '-d' not in a) or (a[1] == 'ready' and '--undo' not in a))) or \
       (p == 'glab' and len(a) >= 2 and a[0] == 'mr' and ((a[1] == 'create' and '--draft' not in a and '--wip' not in a) or (a[1] == 'update' and ('--ready' in a or '-r' in a)))):
        head, missing = missing_steps(run_dir)
        if missing:
            block(f"HEAD {head[:10] or '(no git repo in cwd)'} has no pr-steps {', '.join(missing)} record: run those steps of mergeworthy:converge's pipeline on the final HEAD, each ending with `pr-steps <step> <its output>` (again after a base merge); or open it with --draft")
    if p == 'glab' and len(a) >= 2 and a[0] in ('issue', 'mr') and a[1] == 'create' and '--help' not in a and '-h' not in a:
        need_watch(gitlab_repo(a[2:], run_dir))
    if p == 'gh' and len(a) >= 2 and a[0] == 'pr' and a[1] == 'merge':
        if setting('MERGE', 'on-request-squash') == 'reviewer':
            block('never merge: the reviewer merges this repo\'s PRs (MERGEWORTHY_MERGE=reviewer)')
        rest = a[2:]
        subj, body = opt(rest, ['--subject', '-t']), opt(rest, ['--body', '-b'])
        num = next((x for i, x in enumerate(rest) if re.fullmatch(r'\d+', x) and (i == 0 or not rest[i - 1].startswith('-'))), '')
        if not ('--squash' in rest or '-s' in rest) or not subj or not re.search(r' \(#' + (num or r'\d+') + r'\)$', subj[-1]) or body != ['']:
            block('squash-merge as the repo asks, by default `gh pr merge <N> --squash --delete-branch --subject "<exact PR title> (#<N>)" --body ""`; re-read the repo\'s AGENTS.md first')
        # Deleting a branch other open PRs are based on closes them (GitHub doesn't retarget them)
        if num and ('--delete-branch' in rest or '-d' in rest):
            repo = opt(rest, ['-R', '--repo'])
            rargs = ['-R', repo[-1]] if repo else []
            try:
                head = subprocess.run(['gh', 'pr', 'view', num, *rargs, '--json', 'headRefName', '-q', '.headRefName'],
                                      capture_output=True, text=True, timeout=20).stdout.strip()
                deps = subprocess.run(['gh', 'pr', 'list', *rargs, '--base', head, '--json', 'number', '-q', '[.[].number] | join(",")'],
                                      capture_output=True, text=True, timeout=20).stdout.strip() if head else ''
            except Exception:
                deps = ''
            if deps:
                block(f"open PRs #{deps} are based on {head}: retarget them first (`gh pr edit <N> --base <new base>`), or merge without --delete-branch; deleting it closes them")
    if p == 'gh' and len(a) >= 2 and a[0] in ('issue', 'pr'):
        sub, rest = a[1], a[2:]
        if '--help' in rest or '-h' in rest:
            return  # reading gh's help posts nothing
        files = opt(rest, ['--body-file', '-F'])
        texts = [v for v in opt(rest, ['--body', '-b']) + (opt(rest, ['--comment', '-c']) if sub == 'close' else []) if v.strip()]
        if sub in ('comment', 'create', 'review') or (sub in ('edit', 'close', 'merge') and (files or texts)):
            if texts or not files:
                if sub == 'review' and not texts and not files and '--approve' in rest:
                    return  # an approval without a body posts no text
                block(NEED_DRAFT)
            if sub == 'create':
                need_watch((opt(rest, ['--repo', '-R']) or [None])[-1] or cwd_repo(run_dir))
            if a[0] == 'pr' and sub == 'create':  # a draft's body says why on its State line, a ready PR's has none (pull-request step 7)
                draft = '--draft' in rest or '-d' in rest
                w = post_words.words((opt(rest, ['--repo', '-R']) or [None])[-1] or cwd_repo(run_dir))
                for f in files:
                    f = os.path.join(cwd, os.path.expandvars(os.path.expanduser(f)))
                    lines = [l.strip() for l in open(f).read().split('\n') if l.strip()] if os.path.exists(f) else []
                    lead = lines[1:2] if lines[:1] and lines[0].startswith('<img') else lines[:1]  # under the badge
                    if lines and draft != bool(post_words.state_line(w).match((lead or [''])[0])):
                        block(f"{f}: a draft PR's body starts, right under the badge, with '**{w['state'][0]}: {w['state'][1]}** (<why it's a draft, in plain words>)' (post-lint --kind pr --draft)" if draft else
                              f"{f}: this PR isn't a draft: remove the State line, or open it with --draft")
            # a comment or body edit on a PR with a refactor ask: the target post_target resolves (gh issue too: an issue number that is a PR)
            target = post_target(a[0], rest, run_dir) if sub != 'create' else (None, None)
            if sub in ('comment', 'edit') and files:
                check_refactor_ask(*target, comment=sub == 'comment', drafts=files)
            if sub == 'comment' and '--edit-last' not in rest:
                check_turn(*target, rest)
            if sub in ('comment', 'review'):
                check_finality(*target, files)
            if sub != 'create':
                check_context(f'{target[0]}#{target[1]}' if all(target) else None, files)
            for f in files: gated_file(f, has_cd, create=f in new_post_drafts(t))
    if p == 'gh' and a and a[0] == 'api':
        rest = a[1:]
        method, ep, fields, inputs, posts = api_call(rest)
        if not posts:
            return
        bodies = [v[len('body=@'):] for v in opt(rest, ['-F', '--field']) if v.startswith('body=@')]
        literal = [v for v in fields if re.match(r'^(body|query)=', v) and not v.startswith('body=@') and not (ep == 'graphql' and v.startswith('query='))]
        if literal or not (bodies or inputs):
            block(NEED_DRAFT)
        m = re.fullmatch(r'/?repos/([\w.-]+/[\w.-]+)/(?:issues|pulls)', ep)
        if m and method == 'POST': need_watch(m.group(1))
        c = re.fullmatch(r'/?repos/([\w.-]+/[\w.-]+)/issues/(\d+)/comments', ep)
        if c and method == 'POST': check_turn(c.group(1), c.group(2), rest); check_finality(c.group(1), c.group(2), bodies + inputs)
        thread = None
        t_ = re.fullmatch(r'/?repos/([\w.-]+/[\w.-]+)/(?:issues|pulls)/(\d+)(?:/.*)?', ep)
        if t_: thread = f'{t_.group(1)}#{t_.group(2)}'
        else:  # an edit of a comment by id: ask which thread it is on
            c_ = re.fullmatch(r'/?repos/([\w.-]+/[\w.-]+)/(?:issues|pulls)/comments/\d+', ep)
            if c_:
                r_ = subprocess.run(['gh', 'api', ep.lstrip('/'), '--jq', '.issue_url // .pull_request_url'], capture_output=True, text=True, timeout=20)
                n_ = re.search(r'/(\d+)\s*$', r_.stdout) if r_.returncode == 0 else None
                thread = f'{c_.group(1)}#{n_.group(1)}' if n_ else None
        # a comment on a PR, or an edit of its body, as `gh pr comment` and `gh pr edit` are checked
        if thread and method in ('POST', 'PATCH') and re.search(r'/issues/(?:\d+/comments|comments/\d+)$|/(?:issues|pulls)/\d+$', ep):
            check_refactor_ask(*thread.split('#'), comment=not re.search(r'/(?:issues|pulls)/\d+$', ep), drafts=bodies + inputs)
        check_context(thread, bodies + inputs)
        for f in bodies + inputs: gated_file(f, has_cd, create=f in new_post_drafts(t))

segs, err = parse(cmd)
if err and (m := GUARDED.search(cmd)):  # its words are still checked below, but what they don't show can't be
    block(f"this command doesn't parse ({err}), so its `{' '.join(m.group(0).split()[:2])}` can't be checked: split it into simple commands, "
          "a message or body in a file (`git commit -F <file>`, `--body-file`)")
if re.search(r'\b(until|while)\b[^\n]*\bsleep\b', cmd) and not d.get('tool_input', {}).get('run_in_background'):
    block('never wait in the foreground: the main session keeps working while agents and builds run. Rely on the task-completion notification, '
          'or run the wait with run_in_background (one notification when it ends)')
# a Playwright install prunes the browser builds other sessions use from the shared ~/.cache/ms-playwright (agent.md §Machine)
if any('playwright' in ' '.join(prog(x)) and 'install' in prog(x) for x in segs) and 'PLAYWRIGHT_BROWSERS_PATH=' not in cmd:
    block("a Playwright install deletes the browser builds other sessions use from the shared ~/.cache/ms-playwright: "
          "install into a folder of your own, `PLAYWRIGHT_BROWSERS_PATH=<work folder>/.pw <the same command>`, and run the tests with the same variable")
# gate-pass is read on its own: this hook checks the gate record before the command runs, so a post in the same command
# goes out on the old record even when gate-pass then refuses the draft (and a pipe hides that refusal)
if any(prog(x)[:1] and os.path.basename(prog(x)[0]) == 'gate-pass' for x in segs) and \
        any(prog(x)[:1] == ['gh'] and (prog(x)[1:3] and prog(x)[1] in ('issue', 'pr') and prog(x)[2:3] and prog(x)[2] in ('comment', 'create', 'edit', 'review', 'close', 'merge')
                                        or prog(x)[1:2] == ['api'] and any(w.startswith('body=') or w in ('--input',) for w in prog(x))) for x in segs):
    block("run gate-pass as its own command and read its exit code, then post in the next command: this check reads the gate record before the command runs (mergeworthy:post step 4)")
has_cd = False
run_dir = cwd  # where the command's git calls run: follows `cd <dir>` within the command
shell_vars = {}  # NAME=value set by the command itself (`W=~/x; cd $W`), for the cd targets after it
for s in segs:
    if s and all(re.match(r'^\w+=', x) for x in s):
        shell_vars.update(x.split('=', 1) for x in s)
    if not os.path.isdir(run_dir) and GUARDED.search(' '.join(prog(s))):
        block(f"can't tell which folder `{' '.join(prog(s)[:3])}` runs in (a cd to {run_dir}), so it can't be checked: cd to an absolute path first")
    check(s, has_cd)
    if prog(s)[:1] in (['cd'], ['pushd']):
        has_cd = True
        args = [x for x in prog(s)[1:] if x not in ('-P', '-L', '-e', '--')]
        to = re.sub(r'\$\{?(\w+)\}?', lambda m: shell_vars.get(m[1], os.environ.get(m[1], m[0])), args[0]) if args else '~'
        if to == '$(git rev-parse --show-toplevel)':
            to = subprocess.run(['git', '-C', run_dir, 'rev-parse', '--show-toplevel'], capture_output=True, text=True).stdout.strip() or to
        run_dir = os.path.join(run_dir, os.path.expanduser(to))
sys.exit(0)
