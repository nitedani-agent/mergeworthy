"""Shell command parsing and transcript reading shared by the hooks (pre-bash-guard, pre-design-gate, pre-skill-gate, post-bash-register)."""
import hashlib, json, os, re, shlex, subprocess


def branch_record(d, kind):
    """The pr-steps record kept once per repo and branch (preflight, approach; same key as bin/pr-steps), None outside git."""
    git = lambda *a: subprocess.run(['git', '-C', d, *a], capture_output=True, text=True).stdout.strip()
    common = git('rev-parse', '--git-common-dir')
    if not common:
        return None
    root = os.path.realpath(os.path.join(d, common))
    rec = lambda b: os.path.expanduser(f'~/.claude/pr-steps/{kind}.' + hashlib.sha256((root + '\n' + b).encode()).hexdigest()[:40])
    branch = git('symbolic-ref', '--short', '-q', 'HEAD') or 'HEAD'
    # a worktree on its own local branch tracking the PR's branch shares that branch's records
    up = git('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}').split('/', 1)[-1]
    return next((rec(b) for b in (branch, up) if b and os.path.exists(rec(b))), rec(branch))


def no_preflight(d):
    """Why code can't start yet in d's repo and branch, or '' (outside git, nothing to check)."""
    rec = branch_record(d, 'preflight')
    if not rec or os.path.exists(rec):
        return ''
    return ("no `pr-steps preflight` record for this repo and branch. Before any code, start the app, then run "
            "`pr-steps preflight <its URL> [Chrome flags]` (or `<PNG the session's browser MCP just took>`), "
            "or `pr-steps preflight 'none, because <why there is no UI or browser-run code>'`")


def segments(cmd):
    """Token lists of the simple commands in cmd. Heredoc bodies are dropped; quotes are resolved by shlex."""
    cmd = re.sub(r'\\\n', ' ', cmd)
    lines, out, term = cmd.split('\n'), [], None
    for l in lines:
        if term is not None:
            if l.strip() == term: term = None
            continue
        h = re.search(r"<<-?\s*['\"]?(\w+)['\"]?", l)
        if h: term = h.group(1)
        out.append(l)
    segs = []
    for l in out:
        lx = shlex.shlex(l, posix=True, punctuation_chars=';&|<>()')
        lx.whitespace_split = True
        cur = []
        for tok in lx:  # raises ValueError on unbalanced quotes
            if tok and set(tok) <= set(';&|()'):
                if cur: segs.append(cur)
                cur = []
            else:
                cur.append(tok)
        if cur: segs.append(cur)
    return segs

# Wrappers that run the command after them, with the options each takes a value for (`timeout 200`, `nice -n 19`, `env -u X`)
WRAPPERS = {'sudo': (), 'env': ('-u',), 'command': (), 'time': (), 'exec': (), 'nohup': (), 'setsid': (), 'netns-run': (),
            'nice': ('-n',), 'ionice': ('-c', '-n'), 'stdbuf': (), 'timeout': ('-s', '-k', '--signal', '--kill-after')}

def prog(t):
    """Drop env assignments and wrappers (with their options, and timeout's duration); return the command's argv."""
    while t:
        if re.match(r'^\w+=', t[0]):
            t = t[1:]
            continue
        w = os.path.basename(t[0])
        if w not in WRAPPERS:
            return t
        t = t[1:]
        while t and t[0].startswith('-'):
            t = t[2:] if t[0] in WRAPPERS[w] else t[1:]
        if w == 'timeout' and t:
            t = t[1:]
    return t

def opt(t, names):
    """Values of options in names, in --x v, --x=v and -Xv forms."""
    vals = []
    for i, a in enumerate(t):
        for n in names:
            if a == n and i + 1 < len(t): vals.append(t[i + 1])
            elif n.startswith('--') and a.startswith(n + '='): vals.append(a[len(n) + 1:])
            elif not n.startswith('--') and a.startswith(n) and len(a) > len(n): vals.append(a[len(n):])
    return vals

def api_call(rest):
    """(method, endpoint, fields, inputs, posts) of `gh api <rest>`. It posts text when it is a GraphQL mutation, or a POST,
    PATCH or PUT that isn't a reaction, rerun, dispatch, label, assignee or review request."""
    method = (opt(rest, ['-X', '--method']) or [''])[-1].upper()
    fields = opt(rest, ['-f', '--raw-field', '-F', '--field'])
    inputs = opt(rest, ['--input'])
    if not method: method = 'POST' if fields or inputs else 'GET'
    pos = [x for i, x in enumerate(rest) if not x.startswith('-') and (i == 0 or rest[i - 1] not in
           ('-X', '--method', '-f', '--raw-field', '-F', '--field', '--input', '-H', '--header', '-q', '--jq', '-t', '--template', '--hostname', '--cache', '-p', '--preview'))]
    ep = pos[0] if pos else ''
    if ep == 'graphql':
        posts = any(re.search(r'\bmutation\b', v) and re.search(r'\b(?!(?:add|remove)Reaction\b)[a-z]\w*\s*\(input:', v) for v in fields)  # a reaction posts no text
    else:
        posts = method in ('POST', 'PATCH', 'PUT') and not re.search(r'/(reactions|rerun[\w-]*|dispatches|labels|assignees|requested_reviewers)(/|$|\?)', ep)
    return method, ep, fields, inputs, posts

def new_post_drafts(t):
    """Draft files a gh argv posts as something new (an issue, PR, comment or review): each draft is posted as new once, edits may repeat."""
    t = prog(t)
    if not t or os.path.basename(t[0]) != 'gh' or '--help' in t or '-h' in t:
        return []
    a = t[1:]
    if a[:1] in (['issue'], ['pr']) and a[1:2] and a[1] in ('comment', 'create', 'review'):
        return opt(a[2:], ['--body-file', '-F'])
    if a[:1] == ['api']:
        method, _, _, inputs, posts = api_call(a[1:])
        if posts and method == 'POST':
            return [v[len('body=@'):] for v in opt(a[1:], ['-F', '--field']) if v.startswith('body=@')] + inputs
    return []


def rlines(path, chunk=1 << 20):
    """The file's lines, last first."""
    with open(path, 'rb') as f:
        f.seek(0, 2)
        pos, rest = f.tell(), b''
        while pos > 0:
            n = min(chunk, pos); pos -= n; f.seek(pos)
            lines = (f.read(n) + rest).split(b'\n')
            rest = lines.pop(0)
            yield from reversed(lines)
        yield rest


def transcript(d):
    path = d.get('transcript_path') or ''
    if d.get('agent_id'):  # a subagent's context holds only its own skills
        path = d.get('agent_transcript_path') or os.path.join(os.path.dirname(path), d.get('session_id', ''), 'subagents', f"agent-{d['agent_id']}.jsonl")
    return path if path and os.path.isfile(path) else None


def unread_instructions(path, d):
    """The AGENTS.md and CLAUDE.md at the root of the git repo holding path that this session's transcript shows no Read,
    cat or sed of since its last compaction; [] outside git or when the root has neither."""
    near = os.path.dirname(os.path.realpath(path))
    while not os.path.isdir(near): near = os.path.dirname(near)  # a new file's folder may not exist yet
    root = subprocess.run(['git', '-C', near, 'rev-parse', '--show-toplevel'], capture_output=True, text=True).stdout.strip()
    need = [f for f in (os.path.join(root, n) for n in ('AGENTS.md', 'CLAUDE.md')) if root and os.path.isfile(f)]
    if not need:
        return []
    t = transcript(d)
    seen = files_read(t, {os.path.basename(f).encode() for f in need}) if t else set()
    return [f for f in need if os.path.realpath(f) not in seen]


def files_read(path, names):
    """Real paths the transcript's Read calls, and its Bash cat and sed (not sed -i), read since its last compaction;
    only lines naming one of names are parsed."""
    seen = set()
    for l in rlines(path):
        if not any(k in l for k in (b'compact_boundary', b'isCompactSummary', *names)):
            continue
        try:
            e = json.loads(l)
        except ValueError:
            continue
        if e.get('subtype') == 'compact_boundary' or e.get('isCompactSummary'):
            break
        content = (e.get('message') or {}).get('content') if isinstance(e.get('message'), dict) else None
        if e.get('type') != 'assistant' or not isinstance(content, list):
            continue
        for b in content:
            if not isinstance(b, dict) or b.get('type') != 'tool_use':
                continue
            i, cwd = b.get('input') or {}, e.get('cwd') or '/'
            if b.get('name') == 'Read' and i.get('file_path'):
                seen.add(os.path.realpath(os.path.join(cwd, os.path.expanduser(str(i['file_path'])))))
            elif b.get('name') == 'Bash':
                try:
                    segs = segments(str(i.get('command') or ''))
                except ValueError:
                    continue
                for s in segs:  # `cd <dir>` moves where the later commands' relative paths point
                    t = prog(s)
                    p, a = (os.path.basename(t[0]), t[1:]) if t else ('', [])
                    if p in ('cd', 'pushd') and a:
                        cwd = os.path.join(cwd, os.path.expanduser(a[0]))
                    elif p == 'cat' or p == 'sed' and not any(re.fullmatch(r'-\w*i\w*|--in-place(=.*)?', x) for x in a):
                        seen |= {os.path.realpath(os.path.join(cwd, os.path.expanduser(x))) for x in a if not x.startswith('-')}
    return seen
