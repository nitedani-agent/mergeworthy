#!/usr/bin/env python3
"""Claude Code PreToolUse hook (matcher: Bash, the agent launchers, the file editors). Exit 2 blocks; stderr goes to the agent.
Always-on rule 1, run the skill, don't recall it: an action waits until every skill its always-on row names was opened
with the Skill tool (or typed as /mergeworthy:<name>) in this session since the last compaction. The transcript
(transcript_path, a subagent's own file for a subagent) is read back to its last compact_boundary. Read-only actions pass."""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shellcmd import segments, prog, opt, api_call

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WRITE = ('post', 'writing')
# The one table of actions and the skills they need. Every skill named here is a row of always-on.md, and every row
# no action can be told by is in UNGATED; tests/hooks.sh fails when the two disagree.
ACTIONS = {
    'gh-watch-start':        ('task',),                     # task step 5, the first command of a GitHub task
    'gh pr create':          ('pull-request',) + WRITE,     # pull-request step 7
    'gh pr edit':            ('pull-request',) + WRITE,     # pull-request step 10
    'gh pr ready':           ('pull-request', 'merging'),   # merging step 3
    'gh pr merge':           ('merging',),                  # merging step 4
    'git push':              ('merging',),                  # merging step 1
    'gh issue create':       ('open-issue',) + WRITE,       # open-issue step 4
    'gh pr review':          ('review',) + WRITE,           # review step 4
    'a post in a thread':    WRITE,                         # comments, replies, body edits, gh api writes
    'thread-context':        ('post',),                     # post step 1
    'post-lint reply':       ('reply',) + WRITE,            # --kind reply or inline
    'post-lint proposal':    ('design',) + WRITE,           # design step 8
    'post-lint pr':          ('pull-request',) + WRITE,
    'post-lint issue':       ('open-issue',) + WRITE,
    'post-lint tracker':     ('task',) + WRITE,             # task step 7
    'gate-pass':             WRITE,
    'an upload':             ('evidence',),                 # a gh command with --attach, evidence step 5
    'pr-steps approach':     ('pull-request',),
    'pr-steps verify':       ('converge',),
    'pr-steps reverify':     ('converge',),
    'pr-steps shape':        ('converge',),
    'pr-steps fresh':        ('converge',),
    'pr-steps gates':        ('converge',),
    'starting an agent':     ('delegate',),
    'editing a brief or prompt file': ('delegate',),
    'editing a skill or rules file':  ('rules',),
}
TEXT = ('--body', '-b', '--body-file', '-F', '--title', '-t')  # an issue edit that changes what a person reads
UNGATED = {'code', 'finality', 'docs'}  # code reaches agents by path in briefs; finality has pre-bash-guard's third-proposal block; no tool call tells docs apart


def rows():
    """{skill: its When cell} from always-on.md's table."""
    try:
        text = open(os.path.join(ROOT, 'always-on.md')).read()
    except OSError:
        return {}
    return {m.group(2): m.group(1) for m in re.finditer(r'^\|\s*(.+?)\s*\|\s*`mergeworthy:([\w-]+)`\s*\|', text, re.M)}


def git_sub(t):
    """git's subcommand and its arguments, past -C <dir>, -c <k=v> and other global options."""
    i = 1
    while i < len(t) and t[i].startswith('-'):
        i += 2 if t[i] in ('-C', '-c', '--git-dir', '--work-tree', '--namespace') else 1
    return t[i:i + 1] + t[i + 1:]


def bash_actions(cmd):
    out = []
    try:
        segs = segments(cmd)
    except ValueError:
        segs = [cmd.split()]
    for s in segs:
        t = prog(s)
        if t and t[0] in ('python3', 'python', 'bash', 'sh') and len(t) > 1:
            t = t[1:]
        name = os.path.basename(t[0]) if t else ''
        a = t[1:]
        if '--help' in a or '-h' in a:
            continue
        if name == 'gh' and opt(a, ['--attach']):
            out.append('an upload')
        if name == 'git':
            sub = git_sub(t)
            if sub[:1] == ['push'] and not {'--dry-run', '-n'} & set(sub):
                out.append('git push')
        elif name == 'gh' and len(a) >= 2 and a[0] in ('pr', 'issue'):
            sub, rest = a[1], a[2:]
            text = bool(opt(rest, list(TEXT)))
            if a[0] == 'pr' and sub in ('create', 'edit', 'merge'):
                out.append(f'gh pr {sub}')
            elif a[0] == 'pr' and sub == 'ready' and '--undo' not in rest:
                out.append('gh pr ready')
            elif a[0] == 'issue' and sub == 'create':
                out.append('gh issue create')
            elif a[0] == 'pr' and sub == 'review':
                out.append('gh pr review')
            elif sub == 'comment' or (sub == 'edit' and text) or (sub == 'close' and opt(rest, ['--comment', '-c'])):
                out.append('a post in a thread')
        elif name == 'gh' and a[:1] == ['api']:
            method, ep, fields, inputs, posts = api_call(a[1:])
            if not posts:
                continue
            if ep == 'graphql':
                out.append('a post in a thread')
            elif re.fullmatch(r'/?repos/[\w.-]+/[\w.-]+/issues', ep) and method == 'POST':
                out.append('gh issue create')
            elif re.fullmatch(r'/?repos/[\w.-]+/[\w.-]+/pulls', ep) and method == 'POST':
                out.append('gh pr create')
            elif re.fullmatch(r'/?repos/[\w.-]+/[\w.-]+/(issues|pulls)(/.*)?', ep):
                out.append('a post in a thread')
        elif name == 'post-lint':
            kind = (opt(a, ['--kind']) or ['reply'])[-1]
            out.append(f'post-lint {kind}' if f'post-lint {kind}' in ACTIONS else 'post-lint reply')  # inline and a missing --kind: reply
        elif name in ('gate-pass', 'gh-watch-start'):
            out.append(name)
        elif name == 'thread-context' and not {'--latest', '--verify'} & set(a):
            out.append(name)
        elif name == 'pr-steps' and a and f'pr-steps {a[0]}' in ACTIONS:
            out.append(f'pr-steps {a[0]}')
        elif (name == 'codex' and a[:1] == ['exec']) or (name == 'claude' and {'-p', '--print'} & set(a)):
            out.append('starting an agent')
    return out


def actions(d):
    tool, ti = d.get('tool_name', ''), d.get('tool_input') or {}
    if tool == 'Bash':
        return bash_actions(ti.get('command', ''))
    if tool in ('Agent', 'Task') or re.search(r'(delegate_task|t3_thread_launch|create_threads)$', tool):
        return ['starting an agent']
    path = str(ti.get('file_path') or ti.get('notebook_path') or '')
    parts = os.path.normpath(path).split(os.sep) if path else []
    if parts and ('skills' in parts[:-1] or parts[-1] in ('AGENTS.md', 'CLAUDE.md', 'always-on.md')):
        return ['editing a skill or rules file']
    if parts and re.search(r'(^|[-_.])(prompt|brief)s?([-_.]|$)', parts[-1], re.I):
        return ['editing a brief or prompt file']
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


def opened(path):
    """Skills opened since the transcript's last compaction: Skill tool calls and /<skill> launches."""
    names = set()
    for l in rlines(path):
        if not any(k in l for k in (b'compact_boundary', b'isCompactSummary', b'"Skill"', b'<command-name>')):
            continue
        try:
            e = json.loads(l)
        except ValueError:
            continue
        if e.get('subtype') == 'compact_boundary' or e.get('isCompactSummary'):
            break
        content = (e.get('message') or {}).get('content') if isinstance(e.get('message'), dict) else None
        if e.get('type') == 'assistant' and isinstance(content, list):
            names |= {str((b.get('input') or {}).get('skill', '')) for b in content
                      if isinstance(b, dict) and b.get('type') == 'tool_use' and b.get('name') == 'Skill'}
        elif e.get('type') == 'user':
            text = content if isinstance(content, str) else ' '.join(b.get('text', '') for b in content or [] if isinstance(b, dict))
            names |= set(re.findall(r'<command-name>/([\w:-]+)</command-name>', text))
    return {n.split(':', 1)[1] if n.startswith('mergeworthy:') else n for n in names if ':' not in n or n.startswith('mergeworthy:')}


def transcript(d):
    path = d.get('transcript_path') or ''
    if d.get('agent_id'):  # a subagent's context holds only its own skills
        path = d.get('agent_transcript_path') or os.path.join(os.path.dirname(path), d.get('session_id', ''), 'subagents', f"agent-{d['agent_id']}.jsonl")
    return path if path and os.path.isfile(path) else None


def main():
    d = json.load(sys.stdin)
    acts = actions(d)
    path = transcript(d) if acts else None
    if not path:
        return 0
    have = opened(path)
    need = {}
    for a in acts:
        for s in ACTIONS[a]:
            if s not in have:
                need.setdefault(s, []).append(a)
    if not need:
        return 0
    when = rows()
    lines = '\n'.join(f"- mergeworthy:{s}, for {' and '.join(dict.fromkeys(a))}: {when.get(s, '')}" for s, a in need.items())
    sys.stderr.write("BLOCKED by pre-skill-gate: always-on rule 1, run the skill, don't recall it. Open each of these with the Skill tool "
                     f"(not opened since this session's last compaction), put its steps in your todo list and run them, then retry:\n{lines}\n")
    return 2


if __name__ == '__main__':
    sys.exit(main())
