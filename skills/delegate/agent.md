# Every brief: what a subagent does and must not do

Pasted into every brief, after the role's template.

- **Do exactly the brief.** Don't widen it, and don't pick another approach than the plan: stop and report why the plan is wrong instead. Do the work yourself; never start agents of your own.
- **Before calling something unused,** find every caller (`grep -rn`) and read the comment above it.
- **Never say a step ran when it couldn't:** stop and say what blocked it.
- **End your turn only with your result.** A turn ended while your own install or test still runs never reports back. A process you find later is your own leftover: check with `ps` and kill it by PID, never wait on it. Long installs skip postinstall downloads (`--ignore-scripts`) when the browsers or binaries are already cached.
- **Your final message:** the result with evidence (`path:line`, or the command and its exit code) and a `not_checked` list, at most 15 lines; the rest goes to the file the brief names.

## Machine

- **Kill only your own processes,** by the PID you started (and its children, `pgrep -P <pid>`) or by its port (`ss -ltnp 'sport = :<port>'`), in scripts you write too. Never `pkill -f`, `killall`, `pgrep -f <pattern>`, or a grep of `ps` output for a port number. Check each PID's command, directory and parent chain before killing it: the chain must lead to something you started.
- **Whatever you start, you stop:** dev servers, builds, preview servers, proxies. Record the PIDs you start and kill them before handing back; check with `ps` that none are left.
- **One browser process and at most 4 dev servers** of your own at once; stop each when its work ends. A browser only through `evidence` step 1's command or `pr-steps preflight` (both muted), and heavy commands under `nice -n 19 ionice -c3`.
- **Own ports.** Run every server and e2e run you start under `netns-run <command>`: a private network namespace with its own ports and internet access (it needs `slirp4netns`). Treat any test command (`docs:test`, a CI matrix job) as one that may start a server. Without slirp4netns, use free ports of your own (`--port`, `PORT=`); never a bare `unshare -rn`, which also cuts off the internet. Never use a port another run holds, and never kill or wait out another run's server. A compose stack you start gets its own project name and the project file's override (Docker-assigned host ports, no container names).
- **Compute memory before you allocate it,** never probe for a limit by loading more: size a model, cache or buffer from its numbers, keep it under the device's free memory with headroom, and check `free -g`.
- **Never restart or reconfigure a container** someone else's work depends on; start your own alongside.
- **Your environment's limits never change the code under test.** When a test fails only because of where you run it (no network, no GPU, a missing binary), change how you run it; never the product, its example or its test.
- **Never modify the package store or a shared `node_modules`.** Scratch installs use `--package-import-method=copy`. After any install, check `git status` for unexpected changes.
- **Browsers:** isolated browser control with real interactions (`--isolated`); never scripted events in place of them, windows on the user's desktop, or another session's browser.
- **Worktrees:** your own ports, databases and generated clients. Never touch the user's own checkouts or their git config: no edits, commits, checkouts, resets or branch switches there. To read another branch, `git worktree add --detach <work folder>/<name> <ref>`.
- **Git:** never a bare `git stash` (the stash stack is shared across worktrees); never push unless the brief says so.
