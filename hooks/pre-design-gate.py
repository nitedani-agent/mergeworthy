#!/usr/bin/env python3
"""Claude Code PreToolUse hook (matcher: Write, Edit, MultiEdit, NotebookEdit, delegate_task). Exit 2 blocks; stderr goes to the agent.
An edit inside a git work tree waits for its repo and branch's `pr-steps preflight` record.
At Tier M or L (first line of scope.md in the work folder: ~/.mergeworthy/work/<task>/ holding the checkout, or <repo>-work/ beside it),
code waits for prior art (task step 6) and the design (design step 4): the work folder's prior-art.md and a decisions/*.md must exist
before an edit inside the repo or an implementation agent. In a task's work folder, code waits for scope.md's Tier line (task step 2).
The step records under ~/.claude/pr-steps are pr-steps' to write."""
import glob, json, os, re, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import failclosed
from shellcmd import no_preflight
import work_folder
d = json.load(sys.stdin)
ti = d.get('tool_input', {}) or {}
tool = d.get('tool_name', '')
cwd = d.get('cwd') or os.getcwd()
near = cwd
if 'delegate_task' not in tool:
    target = os.path.realpath(os.path.join(cwd, os.path.expanduser(str(ti.get('file_path') or ti.get('notebook_path') or ''))))
    if target.startswith(os.path.realpath(os.path.expanduser('~/.claude/pr-steps')) + os.sep):
        sys.stderr.write("BLOCKED: the step records in ~/.claude/pr-steps are written by `pr-steps <step> <its output>` alone, which checks the output first\n")
        sys.exit(2)
    near = os.path.dirname(target)
    while not os.path.isdir(near): near = os.path.dirname(near)  # a new file's folder may not exist yet
    if why := no_preflight(near):
        sys.stderr.write(f"BLOCKED: {why}\n")
        sys.exit(2)
# the edited file's repo, else the session's: an edit outside any repo is no code change (the push gate checks what leaves)
top = subprocess.run(['git', '-C', near, 'rev-parse', '--show-toplevel'], capture_output=True, text=True).stdout.strip()
if not top:
    sys.exit(0)
work = work_folder.of(top) or work_folder.of(cwd) or top + '-work'
try:
    tier = open(os.path.join(work, 'scope.md')).readline()
except OSError:
    tier = ''
if not re.match(r'\s*Tier:\s*[0SML]\b', tier):
    if work_folder.of(top):  # a checkout in a task's work folder: the task is triaged before its code (outside one, nothing tells the task)
        sys.stderr.write(f"BLOCKED: {work}/scope.md has no line 1 `Tier: <0|S|M|L>, because <signals>`: triage and scope the task first (mergeworthy:task steps 2-3)\n")
        sys.exit(2)
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
