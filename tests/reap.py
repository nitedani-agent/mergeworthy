"""reap.py <command> [args...]: run the command as a child subreaper, so every process it starts, one in a session of its own
included, becomes this process's child once its parent exits; exit with the command's code once all of them have exited.
One still running 60 s after the command exits is killed, and the exit code is then 1 if the command's was 0."""
import ctypes, os, signal, subprocess, sys, time

PR_SET_CHILD_SUBREAPER = 36


def children():
    out = []
    for pid in filter(str.isdigit, os.listdir('/proc')):
        try:
            if int(open(f'/proc/{pid}/stat').read().rsplit(')', 1)[1].split()[1]) == os.getpid():
                out.append(int(pid))
        except (OSError, ValueError, IndexError):
            pass
    return out


if ctypes.CDLL(None, use_errno=True).prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0):
    sys.exit(f'reap.py: prctl(PR_SET_CHILD_SUBREAPER) failed: {os.strerror(ctypes.get_errno())}')
code = 1
try:
    code = subprocess.call(sys.argv[1:])
    deadline = time.time() + 60
    while True:
        try:
            if os.waitpid(-1, os.WNOHANG)[0]:
                continue
        except ChildProcessError:
            break
        if time.time() > deadline:
            left = children()
            print(f'reap.py: {" ".join(sys.argv[1:])} left processes running 60 s after it exited; killed {left}', file=sys.stderr)
            code = code or 1
            for pid in left:
                os.kill(pid, signal.SIGKILL)
        time.sleep(0.1)
finally:
    for pid in children():
        os.kill(pid, signal.SIGKILL)
sys.exit(code)
