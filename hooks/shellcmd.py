"""Shell command parsing shared by the Bash hooks (pre-bash-guard, pre-skill-gate, post-bash-register, stop-lint).
It fails closed: parse() lexes the whole command as bash does (quotes and heredocs spanning lines, $( ) and backticks, chains,
env prefixes, wrappers, `bash -c`, `eval`), and a command it can't lex still yields its words, split roughly, with the error,
so a hook checks what it can and blocks a guarded verb it can't check."""
import hashlib, os, re, subprocess


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


SHELLS = ('bash', 'sh', 'zsh', 'dash', 'ksh')


def _dq(s, j, subs):
    """s[j] is a double quote: (its text with $( ) and backticks kept as written, index after the closing quote)."""
    buf, j, n = [], j + 1, len(s)
    while True:
        if j >= n:
            raise ValueError('unterminated double quote')
        c = s[j]
        if c == '"':
            return ''.join(buf), j + 1
        if c == '\\' and j + 1 < n:
            buf.append('' if s[j + 1] == '\n' else s[j + 1] if s[j + 1] in '$`"\\' else s[j:j + 2]); j += 2
        elif s.startswith('$(', j) or c == '`':
            k = _sub(s, j, subs); buf.append(s[j:k]); j = k
        elif s.startswith('${', j):
            k = _brace(s, j + 1, subs); buf.append(s[j:k]); j = k
        else:
            buf.append(c); j += 1


def _brace(s, j, subs):
    """s[j] is the { of ${...}: index after its }; a command substitution in it (`${x:-$(cmd)}`) goes into subs."""
    depth, n = 0, len(s)
    while j < n:
        if s[j] == '\\': j += 2; continue
        if s[j] == "'":
            k = s.find("'", j + 1)
            if k < 0: raise ValueError('unterminated single quote')
            j = k + 1; continue
        if s[j] == '"':
            j = _dq(s, j, subs)[1]; continue
        if s.startswith('$(', j) or s[j] == '`':
            j = _sub(s, j, subs); continue
        if s[j] == '{': depth += 1
        elif s[j] == '}':
            depth -= 1
            if depth == 0: return j + 1
        j += 1
    raise ValueError('unterminated ${')


def _inner(text, subs):
    """The command substitutions in text that isn't a command (arithmetic, an unquoted heredoc's body) go into subs."""
    j = 0
    while j < len(text):
        if text[j] == '\\': j += 2
        elif text.startswith('$(', j) or text[j] == '`': j = _sub(text, j, subs)
        else: j += 1


def _arith(s, j):
    """s[j:] starts (( : index after its matching ))."""
    depth, k = 0, j
    while k < len(s):
        depth += {'(': 1, ')': -1}.get(s[k], 0)
        if depth == 0: return k + 1
        k += 1
    raise ValueError('unterminated ((')


def _sub(s, j, subs):
    """s[j:] starts a $( ), $(( )) or `...`: lexes a command substitution's commands into subs; index after it."""
    if s[j] == '`':
        k = j + 1
        while k < len(s) and s[k] != '`':
            k += 2 if s[k] == '\\' else 1
        if k >= len(s):
            raise ValueError('unterminated backtick')
        subs.extend(_lex(s[j + 1:k].replace('\\`', '`'), 0, subs)[0])
        return k + 1
    if s.startswith('$((', j):  # arithmetic: only a substitution inside it runs a command
        k = _arith(s, j + 1)
        _inner(s[j + 3:k - 2], subs)
        return k
    segs, k = _lex(s, j + 2, subs, closer=')')
    subs.extend(segs)
    return k + 1


def _lex(s, i, subs, closer=None):
    """(segments, index): the simple commands of s from i, as word lists; with closer=')', up to the unmatched ) and its index.
    Command substitutions go into subs. A heredoc's body is a file's text, except where a shell reads it as its script."""
    segs, cur, word, inword = [], [], [], False
    pending, line_start, depth, case, n = [], 0, 0, 0, len(s)

    def end_word():
        nonlocal word, inword, case
        if inword:
            cur.append(''.join(word))
            case += {'case': 1, 'esac': -1}.get(cur[-1], 0) if len(cur) == 1 or cur[-1] == 'esac' else 0  # its patterns' ) close nothing
        word, inword = [], False

    def end_seg():
        nonlocal cur
        end_word()
        if cur: segs.append(cur)
        cur = []

    while i < n:
        c = s[i]
        if c == '\\':
            if s[i + 1:i + 2] != '\n':
                word.append(s[i + 1:i + 2]); inword = True
            i += 2
        elif c == "'":
            k = s.find("'", i + 1)
            if k < 0: raise ValueError('unterminated single quote')
            word.append(s[i + 1:k]); inword = True; i = k + 1
        elif s.startswith("$'", i):
            k, buf = i + 2, []
            while k < n and s[k] != "'":
                if s[k] == '\\' and k + 1 < n:
                    buf.append({'n': '\n', 't': '\t'}.get(s[k + 1], s[k + 1])); k += 2
                else:
                    buf.append(s[k]); k += 1
            if k >= n: raise ValueError("unterminated $'")
            word.append(''.join(buf)); inword = True; i = k + 1
        elif c == '"':
            text, i = _dq(s, i, subs); word.append(text); inword = True
        elif s.startswith('$(', i) or c == '`':
            k = _sub(s, i, subs); word.append(s[i:k]); inword = True; i = k
        elif s.startswith('${', i):
            k = _brace(s, i + 1, subs); word.append(s[i:k]); inword = True; i = k
        elif s.startswith('((', i) and not inword and not cur:  # (( arithmetic )): its << is a shift, no heredoc
            k = _arith(s, i); _inner(s[i + 2:k - 2], subs); cur.append(s[i:k]); i = k
        elif c == '#' and not inword:
            k = s.find('\n', i); i = n if k < 0 else k
        elif c in ' \t\r':
            end_word(); i += 1
        elif c in '<>' or s.startswith('&>', i):
            fd = ''.join(word) if inword and ''.join(word).isdigit() else ''  # 2>, 2>&1: the fd belongs to the operator
            if fd: word, inword = [], False
            else: end_word()
            op = re.match(r'&>>?|<<<|<<-?|<>|<&|>&|>>|>\||<|>', s[i:]).group(0); i += len(op)
            cur.append(fd + op)
            if op in ('<<', '<<-'):
                m = re.match(r'[ \t]*(\\?)([\'"]?)([^\s;&|<>()\'"]+)\2', s[i:])
                if not m: raise ValueError('heredoc without a delimiter')
                pending.append((m.group(3), not (m.group(1) or m.group(2)))); cur.append(m.group(3)); i += len(m.group(0))
        elif c == ')' and closer and not depth and (end_word() or not case):
            end_seg()
            return segs, i
        elif c == '\n':
            end_seg(); i += 1
            for delim, expands in pending:  # the bodies follow this line, in order
                body, ended = [], False
                while i < n:
                    k = s.find('\n', i); line = s[i:] if k < 0 else s[i:k]; i = n if k < 0 else k + 1
                    if line.strip() == delim: ended = True; break
                    body.append(line)
                if not ended:  # it would swallow every line after it
                    raise ValueError(f'heredoc {delim} has no end line')
                if expands:  # an unquoted delimiter: bash runs the body's $( ) and backticks
                    _inner('\n'.join(body), subs)
                # `bash <<EOF`, `cat <<EOF | sh`: a shell with no script or -c reads the body as its commands
                if any(prog(x)[:1] and os.path.basename(prog(x)[0]) in SHELLS and not [a for a in operands(prog(x)[1:]) if not a.startswith('-')]
                       for x in segs[line_start:]):
                    segs.extend(_lex('\n'.join(body), 0, subs)[0])
            pending, line_start = [], len(segs)
        elif c in ';&|()':
            depth += {'(': 1, ')': 0 if case and not depth else -1}.get(c, 0) if closer else 0
            end_seg(); i += 1
        else:
            word.append(c); inword = True; i += 1
    if closer:
        raise ValueError('unterminated $(')
    end_seg()
    return segs, i


REDIR = re.compile(r'\d*(?:&>>?|<<<|<<-?|<>|<&|>&|>>|>\||<|>)')


def operands(a):
    """An argv's words minus its redirections and their targets."""
    out, skip = [], False
    for w in a:
        if skip: skip = False
        elif REDIR.fullmatch(w): skip = True
        else: out.append(w)
    return out


def _rough(cmd):
    """Words of a command that doesn't lex: quotes dropped, split at every separator; a guarded verb still shows."""
    return [p.split() for p in re.split(r'[;&|()\n]+', re.sub(r'[\'"`\\]', ' ', cmd)) if p.split()]


def _nested(t):
    """The script a segment runs as a further command: `bash -c '<script>'`, `eval <words>`; else None."""
    t = prog(t)
    name, a = (os.path.basename(t[0]), t[1:]) if t else ('', [])
    if name == 'eval':
        return ' '.join(a)
    if name in SHELLS:
        i, c = 0, False
        while i < len(a) and a[i][:1] in '-+' and a[i] not in ('-', '--'):
            c = c or re.fullmatch(r'-[a-zA-Z]*c[a-zA-Z]*', a[i]) is not None
            i += 2 if a[i] in ('-o', '+o', '-O', '+O') else 1
        return a[i] if c and i < len(a) else None
    return None


def parse(cmd, depth=0):
    """(segments, error): the token lists of every simple command cmd runs, command substitutions and the scripts of
    `bash -c` and `eval` included; error is '' when it lexed, else why not (the segments are then _rough's)."""
    try:
        subs = []
        segs = _lex(cmd, 0, subs)[0] + subs
        err = ''
    except ValueError as e:
        segs, err = _rough(cmd), str(e)
    for s in list(segs):
        script = _nested(s) if depth < 4 else None
        if script:
            inner, e = parse(script, depth + 1)
            segs += inner
            err = err or e
    return segs, err


def segments(cmd):
    """parse()'s segments."""
    return parse(cmd)[0]


# The verbs the hooks check: a command holding one that doesn't parse is blocked (pre-bash-guard), never let through unchecked
GUARDED = re.compile(r'\b(?:git\b.*?\b(?:push|commit)|gh\s+(?:pr|issue|api|release)|glab\s+(?:issue|mr))\b', re.S)

# Wrappers that run the command after them, with the options each takes a value for (`timeout 200`, `nice -n 19`, `env -u X`)
WRAPPERS = {'sudo': ('-u', '-g', '-h', '-p', '-C', '-D', '-r', '-t', '-U'), 'env': ('-u', '-C', '--unset', '--chdir'), 'command': (),
            'time': (), 'exec': (), 'nohup': (), 'setsid': (), 'netns-run': (), 'builtin': (),
            'nice': ('-n',), 'ionice': ('-c', '-n'), 'stdbuf': (), 'timeout': ('-s', '-k', '--signal', '--kill-after'),
            'xargs': ('-I', '-n', '-P', '-L', '-d', '-a', '-E', '-s', '--max-args', '--max-procs', '--delimiter', '--arg-file')}
KEYWORDS = ('!', '{', 'if', 'then', 'else', 'elif', 'do', 'while', 'until')  # a command after these still runs


def prog(t):
    """Drop env assignments, shell keywords and wrappers (with their options, and timeout's duration); return the command's argv."""
    while t:
        if re.match(r'^\w+=', t[0]) or t[0] in KEYWORDS:
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


def git_argv(t, cwd):
    """(git dir, -c overrides, subcommand, its arguments) of a git argv, past its global options; a configured alias
    (`git config alias.p push`, or `-c alias.p=push`) is expanded, so `git p` is checked as the push it runs."""
    a = t[1:]
    overrides = dict(a[i + 1].split('=', 1) for i in range(len(a) - 1) if a[i] == '-c' and '=' in a[i + 1])
    git_dir = next((a[i + 1] for i in range(len(a) - 1) if a[i] == '-C'), '.')
    git_dir = os.path.join(cwd, os.path.expanduser(git_dir))
    while a and a[0].startswith('-'):
        a = a[2:] if a[0] in ('-C', '-c', '--git-dir', '--work-tree', '--namespace') else a[1:]
    if not a:
        return git_dir, overrides, '', []
    sub, rest = a[0], a[1:]
    alias = overrides.get(f'alias.{sub}') or subprocess.run(['git', '-C', git_dir, 'config', '--get', f'alias.{sub}'],
                                                            capture_output=True, text=True).stdout.strip()
    if alias and not alias.startswith('!'):
        words = alias.split()
        sub, rest = words[0], words[1:] + rest
    elif alias:  # a shell alias: its first command's verb
        inner = prog((segments(alias[1:]) or [['']])[0])
        if inner[:1] == ['git']:
            return git_argv(inner + rest, cwd)
    return git_dir, overrides, sub, rest


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
