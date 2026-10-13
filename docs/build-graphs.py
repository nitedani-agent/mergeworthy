#!/usr/bin/env python3
"""Builds docs/graphs.md from the skills themselves, so the graphs can't drift from them.

- Entry points: the index table in always-on.md (When | Open | What it is).
- Steps: each skill's numbered steps (`### 3. Title` headings, or `3. ...` items in a section); a skill without
  numbered steps shows its sections.
- Arrows to other skills: a step that names one (`mergeworthy:post`, `post`, `post step 3`, `post §Kinds`), or a brief
  template (`delegate/verifier.md`, an arrow to `delegate`).

    python3 docs/build-graphs.py           write docs/graphs.md
    python3 docs/build-graphs.py --check   exit 1 if docs/graphs.md is out of date (CI runs this)
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'docs', 'graphs.md')


def read(*p):
    return open(os.path.join(ROOT, *p), encoding='utf-8').read()


def index():
    rows = []
    for line in read('always-on.md').splitlines():
        m = re.match(r'^\|\s*(.+?)\s*\|\s*`mergeworthy:([\w-]+)`\s*\|\s*(.+?)\s*\|$', line)
        if m:
            rows.append(m.groups())
    return rows


def rule_owners(rows):
    """Rule numbers (1.6, 1.1.15 -> 1.1) to the skill that holds them, from the Holds column."""
    owners = {}
    for _, skill, holds in rows:
        for n in re.findall(r'\b\d+\.\d+\b', holds):
            owners[n] = skill
    return owners


def label(text, width=24, words_max=8, whole=False):
    """A node label: the step's bold title, else its first clause, at most 8 words, wrapped into short lines
    (GitHub's Mermaid measures text in one font and draws it in another, so a long line gets cut off)."""
    text = re.sub(r'^\*\*(.+?)\*\*.*', r'\1', text.strip()) if text.strip().startswith('**') else text.strip()
    text = re.sub(r'`([^`]*)`', r'\1', text)
    if not whole:
        text = re.split(r'(?<=[.:;,])\s|\s\(|\s[–-]\s', text, maxsplit=1)[0].rstrip('.:;,')
    words = text.split()
    words = words[:words_max] + (['…'] if len(words) > words_max else [])
    lines, line = [], ''
    for w in words:
        if line and len(line) + 1 + len(w) > width:
            lines.append(line); line = w
        else:
            line = f'{line} {w}'.strip()
    lines.append(line)
    return '<br/>'.join(x.replace('"', "'").replace('<', '‹').replace('>', '›') for x in lines)


def steps(skill):
    """[(section, step label, step text)] in reading order."""
    body = read('skills', skill, 'SKILL.md').split('\n---\n', 1)[-1]
    body = re.sub(r'^(```|~~~).*?^\1[^\n]*$', '', body, flags=re.S | re.M)  # prompts and examples aren't steps
    out, section, current = [], '', None
    for line in body.splitlines():
        h = re.match(r'^(#{2,3}) (.+)', line)
        if h:
            num = re.match(r'(\d+)\. (.+)', h.group(2))
            if num:
                current = [section, f'{num.group(1)}. {label(num.group(2))}', '']
                out.append(current)
            else:
                section, current = label(h.group(2)), None
            continue
        item = re.match(r'^(\d+)\. (.+)', line)
        if item:
            current = [section, f'{item.group(1)}. {label(item.group(2))}', item.group(2)]
            out.append(current)
        elif current is not None:
            current[2] += '\n' + line
    if out:
        return out
    return [[h, h, ''] for h in (label(m) for m in re.findall(r'^#{2,3} (.+)', body, flags=re.M))]


def refs(text, me, skills, owners):
    found = []
    for s in re.findall(r'`(?:mergeworthy:)?([\w-]+)(?: steps? [\d–-]+| §[^`]+|/[\w-]+\.md[^`]*)?`', text) + re.findall(r'mergeworthy:([\w-]+)', text):
        if s in skills and s != me and s not in found:
            found.append(s)
    for n in re.findall(r'(?<![\w.])(\d+\.\d+)(?:\.\d+)?(?![\w.]*\d)', text):
        s = owners.get(n)
        if s and s != me and s not in found:
            found.append(s)
    return found


def build():
    rows = index()
    owners = rule_owners(rows)
    skills = sorted(d for d in os.listdir(os.path.join(ROOT, 'skills')) if os.path.exists(os.path.join(ROOT, 'skills', d, 'SKILL.md')))
    out = ['# How the skills connect', '',
           'Generated from the skills by `docs/build-graphs.py`; edit the skills, then run it. One graph per entry point in `always-on.md`: each section of the skill is a box, its numbered steps run top to bottom, and a dashed arrow marks where a step hands over to another skill.', '',
           '## Which skill hands over to which', '', '| Skill | Hands over to |', '|---|---|']
    for s in skills:
        to = []
        for _, _, text in steps(s):
            to += [r for r in refs(text, s, skills, owners) if r not in to]
        out.append(f'| `{s}` | {", ".join(f"`{t}`" for t in to) or "nothing"} |')
    out += ['']
    for when, skill, holds in rows:
        out += [f'## {when}', '', f'Opens `mergeworthy:{skill}` ({holds}).', '', '```mermaid', 'flowchart TB',
                f'  start(["{label(when, words_max=14, whole=True)}"])']
        groups = []  # [(section, [(name, text)])], in reading order
        for section, name, text in steps(skill):
            if not groups or groups[-1][0] != section:
                groups.append((section, []))
            groups[-1][1].append((name, text))
        n, i, first_nodes = 0, 0, []
        for g, (section, items) in enumerate(groups):
            # a long numbered list is a set of rules to apply, not steps in order: one node
            if len(items) > 8:
                items = [(f'{len(items)} rules: {", ".join(re.sub(r"^\d+\. ", "", x[0]) for x in items[:3])}…', ' '.join(x[1] for x in items))]
            out.append(f'  subgraph g{g}["{section or skill}"]')
            prev = None
            for name, text in items:
                node = f's{i}'; i += 1
                out.append(f'    {node}["{name}"]')
                if prev: out.append(f'    {prev} --> {node}')
                else: first_nodes.append(node)
                prev = node
            out.append('  end')
            for name_text, node in zip(items, range(i - len(items), i)):
                for r in refs(name_text[1], skill, skills, owners):
                    n += 1
                    out.append(f'  s{node} -.-> r{n}[["{r}"]]')
        out.append('  start --> g0')
        for g in range(1, len(groups)):
            out.append(f'  g{g - 1} ~~~ g{g}')  # keeps the sections in reading order without implying a flow
        out += ['```', '']
    return '\n'.join(out)


if __name__ == '__main__':
    text = build()
    if '--check' in sys.argv:
        current = open(OUT, encoding='utf-8').read() if os.path.exists(OUT) else ''
        if current != text:
            sys.exit('docs/graphs.md is out of date with the skills: run python3 docs/build-graphs.py')
    else:
        open(OUT, 'w', encoding='utf-8').write(text)
