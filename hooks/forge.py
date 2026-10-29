#!/usr/bin/env python3
"""What GitHub and GitLab say about a PR or MR, for stop-lint's PR checks: each read is (its JSON answer, or None when gh or glab
failed or answered no JSON; their stderr), and a read is made once per stop, however many checks ask for it."""
import functools, json, re, subprocess, urllib.parse


@functools.cache
def _api(*cmd):
    try: r = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as e: return None, str(e)
    try: return (json.loads(r.stdout or 'null') if r.returncode == 0 else None), r.stderr
    except ValueError: return None, 'unreadable answer'


def pull(repo, n): return _api('gh', 'api', f'repos/{repo}/pulls/{n}')
def issue(repo, n): return _api('gh', 'api', f'repos/{repo}/issues/{n}')
def check_runs(repo, sha, per_page=None): return _api('gh', 'api', f'repos/{repo}/commits/{sha}/check-runs' + (f'?per_page={per_page}' if per_page else ''))
def merge_request(host, path, n): return _api('glab', 'api', '--hostname', host, f'projects/{urllib.parse.quote(path, safe="")}/merge_requests/{n}')


@functools.cache
def remotes(cwd):
    """The GitHub repos of the checkout's upstream and origin remotes, in that order."""
    out = []
    for name in ('upstream', 'origin'):
        u = subprocess.run(['git', '-C', cwd, 'remote', 'get-url', name], capture_output=True, text=True).stdout.strip()
        if m := re.search(r'github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?$', u): out.append(m[1])
    return out
