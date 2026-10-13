#!/usr/bin/env python3
"""Claude Code PreToolUse hook (matcher: Write, Edit, MultiEdit, NotebookEdit, delegate_task). Exit 2 blocks; stderr goes to the agent.
An edit inside a git work tree waits for its repo and branch's `pr-steps preflight` record.
At Tier M or L (first line of <repo>-work/scope.md), code waits for prior art (task step 6) and the design (design step 4):
<repo>-work/prior-art.md and a <repo>-work/decisions/*.md must exist before an edit inside the repo or an implementation agent."""
import glob, json, os, re, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shellcmd import no_preflight
d = json.load(sys.stdin)
ti = d.get('tool_input', {}) or {}
tool = d.get('tool_name', '')
cwd = d.get('cwd') or os.getcwd()
if 'delegate_task' not in tool:
    near = os.path.dirname(os.path.realpath(os.path.join(cwd, str(ti.get('file_path') or ti.get('notebook_path') or ''))))
    while not os.path.isdir(near): near = os.path.dirname(near)  # a new file's folder may not exist yet
    if why := no_preflight(near):
        sys.stderr.write(f"BLOCKED: {why}\n")
        sys.exit(2)
try:
    top = subprocess.run(['git', '-C', cwd, 'rev-parse', '--show-toplevel'], capture_output=True, text=True).stdout.strip()
except OSError:
    top = ''
if not top:
    sys.exit(0)
work = top + '-work'
try:
    tier = open(os.path.join(work, 'scope.md')).readline()
except OSError:
    sys.exit(0)
if not re.match(r'\s*Tier:\s*[ML]\b', tier):
    sys.exit(0)
if 'delegate_task' in tool:
    if str(ti.get('role') or '') != 'implementation':
        sys.exit(0)
else:
    path = os.path.realpath(str(ti.get('file_path') or ti.get('notebook_path') or ''))
    if not path.startswith(os.path.realpath(top) + os.sep):
        sys.exit(0)
missing = [n for n, ok in (('prior-art.md', os.path.isfile(os.path.join(work, 'prior-art.md'))),
                          ('decisions/*.md', bool(glob.glob(os.path.join(work, 'decisions', '*.md'))))) if not ok]
if missing:
    sys.stderr.write(f"BLOCKED: {tier.strip()} and {work} has no {' or '.join(missing)}. Before code: prior art (mergeworthy:task step 6: the web, "
                     "every project the user names, peers) into prior-art.md, then design it twice (mergeworthy:design step 4) "
                     "into decisions/<name>.md.\n")
    sys.exit(2)
sys.exit(0)
