#!/usr/bin/env python3
"""The program state file (core 1.2): state.md in an artifact root, the watch dirs ~/.claude/gh-watch-dirs.txt lists.
`state_file.py <cwd>` prints the one session-start loads: the state file whose dir holds the cwd or that names a path
holding it, else the most recently modified one."""
import os, re, sys

def candidates():
    reg = os.path.expanduser('~/.claude/gh-watch-dirs.txt')
    dirs = [l.strip() for l in open(reg)] if os.path.exists(reg) else []
    return [p for p in dict.fromkeys(os.path.join(w, 'state.md') for w in dirs if w) if os.path.isfile(p)]

def _under(cwd, p):
    p = os.path.expanduser(p).rstrip('/')
    return bool(cwd and p) and (cwd == p or cwd.startswith(p + '/'))

def for_cwd(cwd):
    """The state file of the program the cwd belongs to: its own dir, or a worktree it lists."""
    for s in candidates():
        paths = [os.path.dirname(s)] + re.findall(r'(?<![\w.])((?:~|/)[^\s`\'"()<>,;]+)', open(s, errors='replace').read())
        if any(_under(cwd, p) and os.path.isdir(os.path.expanduser(p)) for p in paths):
            return s
    return None

def find(cwd):
    return for_cwd(cwd) or max(candidates(), key=os.path.getmtime, default=None)

def used(d):
    """The state file this session works from: matched by its cwd, or named in one of its own tool calls."""
    s = for_cwd(d.get('cwd') or '')
    if s:
        return s
    tp = d.get('transcript_path') or ''
    names = {c: (c, c.replace(os.path.expanduser('~'), '~', 1)) for c in candidates()}
    if not names or not os.path.isfile(tp):
        return None
    for l in open(tp, errors='replace'):
        if '"tool_use"' in l and '"assistant"' in l:
            for c, forms in names.items():
                if any(f in l for f in forms):
                    return c
    return None

def workstreams(path):
    """{name: block text} of the `### <name>` blocks under `## Workstreams`."""
    m = re.search(r'^## Workstreams[^\n]*\n(.*?)(?=^## |\Z)', open(path, errors='replace').read(), re.M | re.S)
    blocks = re.split(r'^### +', m.group(1), flags=re.M)[1:] if m else []
    return {b.split('\n', 1)[0].strip(): b for b in blocks}

def field(block, name):
    m = re.search(r'^\s*- *' + name + r':\s*(.*?)\s*$', block, re.M | re.I)
    return m.group(1) if m else ''

if __name__ == '__main__':
    print(find(sys.argv[1] if len(sys.argv) > 1 else os.getcwd()) or '')
