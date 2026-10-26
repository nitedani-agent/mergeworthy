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
    a reason for each folder it can't read, each bare repo and each other version-control system's data)."""
    dev, found, why, stack = os.lstat(folder).st_dev, [], [], [folder]
    while stack:
        d = stack.pop()
        try:
            entries = list(os.scandir(d))
        except OSError:
            why.append(f'{d}: unreadable')
            continue
        names = {e.name for e in entries}
        if d != folder and {'HEAD', 'objects', 'refs'} <= names and '.git' not in names:
            why.append(f'{d}: a bare repo; check it by hand')
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


def common_dir(top):
    """The real path of top's git common dir (its repo's git data), or None."""
    c = git(top, 'rev-parse', '--path-format=absolute', '--git-common-dir').stdout.strip()
    return os.path.realpath(c) if c else None


def outside(folder):
    """The git common dirs outside folder whose repos have a worktree under it."""
    folder = os.path.realpath(folder)
    return sorted({c for c in map(common_dir, trees(folder)[0]) if c and not inside(c, folder)})


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


def open_line(path, cleared):
    """Whether the file path has a line that isn't blank, a # comment or cleared (it starts with cleared, in any case)."""
    return os.path.isfile(path) and any((l := s.strip()) and not l.startswith('#') and not l.lower().startswith(cleared) for s in open(path, errors='replace'))


def keep(folder, on_github):
    """Why deleting folder would lose something, one reason each, [] when nothing: its watcher hasn't retired (no `retired` file) or
    still runs; replies-owed.md, waiting-on.txt or questions-owed.md has an open line, or proposals-open.md a PROMISED one; a repo lies below a folder
    its enclosing repo ignores (no git runs in it); a work tree under it has a modified or untracked file (ignored ones aside); a repo whose git data is inside it has a stash or a worktree outside it; a detached
    HEAD of a worktree inside it whose repo is outside is reachable from no branch, tag or remote-tracking ref of that repo; a branch
    tip, tag or worktree HEAD of a repo whose git data is inside it is reachable from no commit its readable remotes hold now, and
    on_github(owner/repo, sha) doesn't answer True for any GitHub remote (the reason names the remotes it couldn't read); a bare repo;
    another version-control system's data."""
    folder = os.path.realpath(folder)
    why = [] if os.path.isfile(os.path.join(folder, 'retired')) else ['its watcher has not retired']
    try:
        os.kill(int(open(os.path.join(folder, 'gh-watch.pid')).read().strip()), 0)
        why.append('its watcher is running')
    except (OSError, ValueError):
        pass
    if open_line(os.path.join(folder, 'replies-owed.md'), 'done:'):
        why.append('replies-owed.md has an open line')
    if open_line(os.path.join(folder, 'waiting-on.txt'), 'done'):
        why.append('waiting-on.txt has an open wait')
    if open_line(os.path.join(folder, 'questions-owed.md'), 'done'):
        why.append('questions-owed.md has an open line')
    if any(l.startswith('PROMISED') for po in glob.glob(os.path.join(folder, 'proposals-open.md')) + glob.glob(os.path.join(folder, '*', 'proposals-open.md'))
           for l in open(po, errors='replace')):
        why.append('proposals-open.md has an undelivered PROMISED line')
    tops, found = trees(folder)
    why += found
    repos, unchecked = {}, []  # git common dir: a work tree of it; work trees git doesn't run in
    for top in sorted(tops):  # a repo before the repos inside it
        outer = max((t for t in tops if t != top and inside(top, t)), key=len, default=None)
        if outer in unchecked:
            unchecked.append(top)
            continue
        if outer and git(outer, 'check-ignore', '-q', os.path.relpath(top, outer)).returncode != 1:  # its config (a filter) may run commands
            why.append(f'{top}: a repo inside an ignored folder; check it by hand')
            unchecked.append(top)
            continue
        st = git(top, 'status', '--porcelain', '-uall')
        if st.returncode:
            why.append(f'{top}: git status failed: {st.stderr.strip()[:120]}')
            continue
        if st.stdout:
            why.append(f'{top}: {len(st.stdout.splitlines())} modified or untracked file(s), e.g. {st.stdout.splitlines()[0][3:]}')
        repos.setdefault(common_dir(top), top)
    for common, top in repos.items():
        wts = worktrees(top)
        if not inside(common, folder):  # the repo outside stays, with what its refs reach (not --all: it counts worktree HEADs)
            why += [f'{top}: commit {h[:12]} is on no branch, tag or remote-tracking ref of {common}' for p, h, detached in wts
                    if detached and inside(os.path.realpath(p), folder) and git(top, 'rev-list', '-n1', h, '--not', '--branches', '--tags', '--remotes').stdout.strip()]
            continue
        if stashes := git(top, 'stash', 'list').stdout.splitlines():
            why.append(f'{top}: {len(stashes)} stash(es)')
        why += [f'{top}: its worktree {p} is outside the folder' for p, _, _ in wts if not inside(os.path.realpath(p), folder) and os.path.exists(p)]
        # an annotated tag counts as the commit it points at
        tips = set(git(top, 'for-each-ref', '--format=%(if)%(*objectname)%(then)%(*objectname)%(else)%(objectname)%(end)', 'refs/heads', 'refs/tags').stdout.split())
        tips |= {h for _, h, _ in wts}
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
