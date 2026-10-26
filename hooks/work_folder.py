#!/usr/bin/env python3
"""The work folders (mergeworthy:task §Files): ~/.mergeworthy/work/<task>/, the task's checkouts inside it; before that layout,
<checkout>-work/ beside a checkout. keep() says what deleting a folder would lose; disk-sweep's w-done rule deletes a retired
folder it finds nothing in."""
import glob, os, re, subprocess

ROOT = os.path.join(os.path.expanduser('~'), '.mergeworthy', 'work')
OTHER_VCS = ('.hg', '.svn', '.jj')
TIMEOUT = 60  # seconds a remote has to answer ls-remote
GITHUB = re.compile(r'(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([\w.-]+/[\w.-]+?)(?:\.git)?/?$')


def git(repo, *args, **kw):
    """git in repo, captured; --no-optional-locks: a refreshed index would reset disk-sweep's idle check; no fsmonitor: a repo's
    own config (an extracted archive's) would run it."""
    return subprocess.run(['git', '--no-optional-locks', '-c', 'core.fsmonitor=false', '-C', repo, *args], capture_output=True, text=True, **kw)


def of(path):
    """The work folder holding path: its ancestor directly under ROOT, else <git toplevel>-work beside path's checkout when it
    exists (the old layout), else None."""
    p, root = os.path.realpath(path), os.path.realpath(ROOT)
    if p.startswith(root + '/'):
        return os.path.join(root, p[len(root) + 1:].split('/')[0])
    top = git(p if os.path.isdir(p) else os.path.dirname(p), 'rev-parse', '--show-toplevel').stdout.strip()
    return top + '-work' if top and os.path.isdir(top + '-work') else None


def inside(p, top):
    return p == top or p.startswith(top + '/')


def trees(folder):
    """(every git work tree under folder, nested and ignored ones too, without following a symlink or leaving its filesystem;
    a reason for each folder it can't read and each other version-control system's data)."""
    dev, found, why, stack = os.lstat(folder).st_dev, [], [], [folder]
    while stack:
        d = stack.pop()
        try:
            entries = list(os.scandir(d))
        except OSError:
            why.append(f'{d}: unreadable')
            continue
        for e in entries:
            if e.is_symlink() or e.stat(follow_symlinks=False).st_dev != dev:
                continue
            if e.name == '.git':
                found.append(d)
            elif e.name in OTHER_VCS:
                why.append(f'{d}: {e.name} data')
            elif e.is_dir():
                stack.append(e.path)
    return found, why


def worktrees(top):
    """[(path, HEAD sha, detached)] of each worktree of top's repo."""
    out = []
    for block in git(top, 'worktree', 'list', '--porcelain').stdout.split('\n\n'):
        f = dict(l.partition(' ')[::2] for l in block.splitlines())
        if 'worktree' in f:
            out.append((f['worktree'], f.get('HEAD', ''), 'detached' in f))
    return out


def remotes(top):
    """{name: URL} of top's remotes as configured, a relative path made absolute."""
    out = {}
    for l in git(top, 'config', '--get-regexp', r'^remote\..*\.url$').stdout.splitlines():
        key, _, url = l.partition(' ')
        out[key[len('remote.'):-len('.url')]] = url if '://' in url or ':' in url.split('/')[0] else os.path.join(top, url)
    return out


def held(top, urls):
    """(the commits of top's repo that its remotes (urls) hold now, as `git ls-remote` lists them; the names of the remotes it can't read).
    ls-remote runs from / on the URL, so the repo's own config (core.sshCommand, credential.helper, insteadOf) isn't read."""
    shas, unread = set(), []
    for name, url in urls.items():
        try:
            r = subprocess.run(['git', '-C', '/', 'ls-remote', url], capture_output=True, text=True, env={**os.environ, 'GIT_TERMINAL_PROMPT': '0'},
                               stdin=subprocess.DEVNULL, timeout=TIMEOUT)
        except (subprocess.TimeoutExpired, OSError):
            r = None
        if r and not r.returncode:
            shas.update(l.split()[0] for l in r.stdout.splitlines() if l.strip())
        else:
            unread.append(name)
    known = git(top, 'cat-file', '--batch-check=%(objectname) %(objecttype)', input=''.join(s + '\n' for s in shas)).stdout
    return [l.split()[0] for l in known.splitlines() if l.endswith(' commit')], unread


def keep(folder, on_github):
    """Why deleting folder would lose something, one reason each, [] when nothing: its watcher hasn't retired (no `retired` file) or
    still runs; replies-owed.md has an open line or proposals-open.md a PROMISED one; a work tree under
    it has a modified or untracked file (ignored ones aside); a repo whose git data is inside it has a stash or a worktree outside it;
    a branch tip or worktree HEAD of such a repo, or a detached HEAD of a worktree inside it whose repo is outside, is reachable from
    no commit its readable remotes hold now and on_github(owner/repo, sha) doesn't answer True for any GitHub remote (the reason names
    the remotes it couldn't read); another version-control system's data."""
    folder = os.path.realpath(folder)
    why = [] if os.path.isfile(os.path.join(folder, 'retired')) else ['its watcher has not retired']
    try:
        os.kill(int(open(os.path.join(folder, 'gh-watch.pid')).read().strip()), 0)
        why.append('its watcher is running')
    except (OSError, ValueError):
        pass
    owed = os.path.join(folder, 'replies-owed.md')
    if os.path.isfile(owed) and any(l.strip() and not l.startswith('#') and not l.lower().startswith('done:') for l in open(owed, errors='replace')):
        why.append('replies-owed.md has an open line')
    if any(l.startswith('PROMISED') for po in glob.glob(os.path.join(folder, 'proposals-open.md')) + glob.glob(os.path.join(folder, '*', 'proposals-open.md'))
           for l in open(po, errors='replace')):
        why.append('proposals-open.md has an undelivered PROMISED line')
    tops, found = trees(folder)
    why += found
    repos = {}  # git common dir: a work tree of it
    for top in tops:
        st = git(top, 'status', '--porcelain', '-uall')
        if st.returncode:
            why.append(f'{top}: git status failed: {st.stderr.strip()[:120]}')
            continue
        if st.stdout:
            why.append(f'{top}: {len(st.stdout.splitlines())} modified or untracked file(s), e.g. {st.stdout.splitlines()[0][3:]}')
        repos.setdefault(os.path.realpath(git(top, 'rev-parse', '--path-format=absolute', '--git-common-dir').stdout.strip()), top)
    for common, top in repos.items():
        wts = worktrees(top)
        if inside(common, folder):
            if stashes := git(top, 'stash', 'list').stdout.splitlines():
                why.append(f'{top}: {len(stashes)} stash(es)')
            why += [f'{top}: its worktree {p} is outside the folder' for p, _, _ in wts if not inside(os.path.realpath(p), folder) and os.path.exists(p)]
            tips = set(git(top, 'for-each-ref', '--format=%(objectname)', 'refs/heads').stdout.split()) | {h for _, h, _ in wts}
        else:  # its branches live on in the repo outside
            tips = {h for p, h, detached in wts if detached and inside(os.path.realpath(p), folder)}
        tips -= {'', '0' * 40}  # an unborn HEAD has no commit
        if not tips:
            continue
        urls = remotes(top)
        remote, unread = held(top, urls)
        hub = sorted({m[1] for u in urls.values() if (m := GITHUB.match(u))})
        for sha in sorted(tips):
            if git(top, 'rev-list', '-n1', '--stdin', sha, input=''.join(f'^{s}\n' for s in remote)).stdout.strip() and True not in (on_github(r, sha) for r in hub):
                why.append(f'{top}: commit {sha[:12]} is on no remote' + (', nor confirmed by GitHub' if hub else '')
                           + (f" (not read: {', '.join(unread)})" if unread else ''))
    return why
