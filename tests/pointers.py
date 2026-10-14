#!/usr/bin/env python3
"""Fails when a pointer in the skills names nothing: `<skill> §<Heading>`, `<skill> step N` or `steps N–M`, and
`delegate/<name>.md` must each resolve to a heading, a numbered step or a file. Usage: tests/pointers.py [repo root]"""
import os, re, sys
R = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..')
S = os.path.join(R, 'skills')
skills = {d for d in os.listdir(S) if os.path.isfile(os.path.join(S, d, 'SKILL.md'))}
heads, steps = {}, {}
for s in skills:
    text = open(os.path.join(S, s, 'SKILL.md')).read()
    heads[s] = set(re.findall(r'^#{2,3} (.+?)\s*$', text, re.M))
    steps[s] = {int(n) for n in re.findall(r'^(\d+)\. ', text.split('\n### ', 1)[0], re.M)}
files = [os.path.join(R, 'always-on.md')] + [os.path.join(S, d, f) for d in sorted(os.listdir(S)) for f in sorted(os.listdir(os.path.join(S, d))) if f.endswith('.md')]
bad = []
for f in files:
    for i, line in enumerate(open(f), 1):
        where = f'{os.path.relpath(f, R)}:{i}'
        for s, h in re.findall(r'`(?:mergeworthy:)?([\w-]+) §([^`]+?)`', line):
            if s in skills and h not in heads[s]:
                bad.append(f'{where}: {s} has no heading "{h}"')
        for s, a, b in re.findall(r'`(?:mergeworthy:)?([\w-]+)` steps? (\d+)(?:[–-](\d+))?', line):
            if s in skills and not {int(a), int(b or a)} <= steps[s]:
                bad.append(f'{where}: {s} has no step {a}{"–" + b if b else ""}')
        for n in re.findall(r'delegate/([\w-]+\.md)', line):
            if not os.path.isfile(os.path.join(S, 'delegate', n)):
                bad.append(f'{where}: no skills/delegate/{n}')
print('\n'.join(bad) or f'pointers: all resolve in {len(files)} files')
sys.exit(1 if bad else 0)
