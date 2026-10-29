# Every brief: what a subagent does and must not do

Pasted into every brief, after the role's template.

- **First read each target repo's `AGENTS.md` and `CLAUDE.md` and their imports, and follow them within the brief.**
- **Do exactly the brief.** Don't widen it, and don't pick another approach than the plan: stop and report why the plan is wrong instead. Do the work yourself; never start agents or watchers of your own.
- **Search before theorizing:** for an error, an API's behavior or how others solved it, search the web and read the sources first, and whenever you're circling.
- **Never say a step ran when it couldn't:** stop and say what blocked it.
- **End your turn only with your result.** A turn ended while your own install or test still runs never reports back. A process you find later is your own leftover: check with `ps` and kill it by PID, never wait on it. Long installs skip postinstall downloads (`--ignore-scripts`) when the browsers or binaries are already cached.
- **Label each review finding:**
  - `blocker`: the case the change exists for behaves wrongly (a post: a false claim, an unanswered question);
  - `should`: a bug or regression ordinary use of the edited code hits, a mechanism the change doesn't need, or any other finding its brief asks for that the nit list doesn't name;
  - `nit`: an equal alternative, a contrived case, a rare one failing mildly, a small cost that is no regression, a request for extra compat.
- **Nits** go under `## Dropped` in your output file; `CLEAN`, `NO BUGS` and `MERGE AS IS: yes` mean no blocker or should.
- **Your final message:** the result with evidence (`path:line`, or the command and its exit code) and a `not_checked` list, at most 15 lines; the rest goes to the file the brief names.

## Code search

- **A semantic code-search MCP first, when the session has one** (e.g. ChunkHound: `search` with type `semantic` or `regex`, `code_research`). How something works across files: `code_research`, worth its few minutes because it reads across files; run it alongside your other reading. Where code doing a thing lives (what already does it, a prior implementation, a bug's siblings): semantic `search`, then `rg` for the names. Read each `path:line` it cites before relying on it. No such MCP: `rg` and reading, never `grep -r`.
- **Only `rg` is exhaustive:** every caller, a rename, a literal. Code only in your worktree (new or uncommitted) may be missing from the MCP's index (in a linked worktree it may search the main checkout's index): find it with `rg`. Before calling something unused, find every caller with `rg -uu` (it also searches ignored files: generated and vendored code) and read the comment above it.
- The MCP builds its index in the background on its first use in a repo: until its status tool (ChunkHound: `daemon_status`) shows it done, results may be partial, so back an empty result with `rg`.

## Machine

- **Kill only your own processes,** by the PID you started (and its children, `pgrep -P <pid>`) or by its port (`ss -ltnp 'sport = :<port>'`), in scripts you write too. Never `pkill -f`, `killall`, `pgrep -f <pattern>`, or a grep of `ps` output for a port number. Check each PID's command, directory and parent chain before killing it: the chain must lead to something you started.
- **Whatever you start, you stop:** dev servers, builds, preview servers, proxies. Record the PIDs you start and kill them before handing back; check with `ps` that none are left.
- **One browser process and at most 4 dev servers** of your own at once. Any browser you start runs headless under `env -u PULSE_SERVER` (plus `--mute-audio` where you pass flags). Run your brief's e2e lanes with their own driver; drive pages by hand only through your session's Chrome DevTools MCP (`evidence` step 1), with real interactions, never scripted events. Without it or its flags, mark hand-driven checks not checked, tell the main session, and do the rest of your brief. Heavy commands run under `nice -n 19 ionice -c3`.
- **Own ports.** Run every server and e2e run you start under `netns-run <command>`: a private network namespace with its own ports and internet access (it needs `slirp4netns`). Treat any test command (`docs:test`, a CI matrix job) as one that may start a server. Without slirp4netns, use free ports of your own (`--port`, `PORT=`); never a bare `unshare -rn`, which also cuts off the internet. Never use a port another run holds, and never kill or wait out another run's server. A compose stack you start gets its own project name and the project file's override (Docker-assigned host ports, no container names).
- **Compute memory before you allocate it,** never probe for a limit by loading more: size a model, cache or buffer from its numbers, keep it under the device's free memory with headroom, and check `free -g`.
- **Never restart or reconfigure a container** someone else's work depends on; start your own alongside.
- **Your environment's limits never change the code under test.** When a test fails only because of where you run it (no network, no GPU, a missing binary), change how you run it; never the product, its example or its test.
- **Never modify the package store or a shared `node_modules`.** Scratch installs use `--package-import-method=copy`. After any install, check `git status` for unexpected changes.
- **Worktrees:** your own ports, databases and generated clients. Never touch the user's own checkouts or their git config: no edits, commits, checkouts, resets or branch switches there. To read another branch, `git worktree add --detach <work folder>/<name> <ref>`.
- **Git:** never `git stash` without `push -u -m <tag>` (the stash stack is shared across worktrees); never push unless the brief says so.
