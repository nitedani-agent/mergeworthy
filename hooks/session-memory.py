#!/usr/bin/env python3
"""SessionStart hook: in an orchestrator's checkout, the order to refresh memory.md when it is behind, then its Standing
digest (core 1.2). A hook command of its own: Claude Code shows the model only a 2 KB preview of an output over 10,000
characters, so the always-on rules (session-start) and this stay under it separately."""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import memory_file as mf
try: cwd = json.load(sys.stdin).get('cwd') or os.getcwd()
except ValueError: cwd = os.getcwd()
try: root = mf.for_cwd(cwd)
except (OSError, ValueError): root = None  # a broken memory.source never fails the session's start
if root:
    if mf.behind(root):
        print(mf.order(root) + ' Until then, the digest below is the last one.\n')
    print(f"The standing memory of this program ({mf.path(root)}, core 1.2): rulings in force, what is ruled out, what was superseded, "
          "what is still intended. They hold over this conversation's summary: never retry what is ruled out or resume what was superseded.\n")
    print(mf.digest(root))
