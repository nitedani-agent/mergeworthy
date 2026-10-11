---
name: pull-request
description: "Any change you'll open a PR for, from an issue or not: already fixed?, reproduce, approach rating, build and gate, seeing it in the app, converging it, the PR body."
---

# Implementing a change

From an issue or a problem to one merge-ready PR. Open PRs within the task’s publishing authority and give every found defect a disposition (`core` 1.1.7); start the body with the user’s problem (`writing`). Steps 1 to 5 build the change, step 6 converges it with `converge`'s pipeline, and step 7 is the PR. Open it as a draft (`gh pr create --draft`) with the branch's first push after step 3 passes, its body the problem on `main` through the fast gate, so CI runs while it converges; the fresh reader's `CLEAN` gates step 7's final body. A Tier ≥ M change (`core` 1.0) runs this once per PR.

**The repo's `AGENTS.md` / `CLAUDE.md` governs how the code is written;** everything else particular to the repo is in its project file (`core` 1.3).

**A repo’s own `.claude/skills/pull-request/SKILL.md` governs implementation steps.** Read it on `origin/<base>` first; `core`, `github-threads`, `merging`, `converge`, `review`, and `writing` retain ownership of their rules.

**Work in a worktree off `<base>`** (the project file names it): `git fetch origin && git worktree add -b <branch> <artifact root>/<branch> origin/<base>`. `origin` here is the repository the PR targets; in a fork clone, fetch the upstream repository and branch from its `<base>`, never from the fork's, which may be stale. In CI, read the project file’s Gates section and the repository’s CI configuration first.

**Check you can finish before you start**, both halves up front:
- **Browser control** (UI or runtime work), set up and tried per `evidence`.
- **The rest of the machine**: `gh` and its login, and whatever the app needs (containers, the hostname, the secrets, the data). The project file's preflight checks all of it in one pass and prints every failure together.

**Install whatever doesn't need root** (a browser, the MCP server, the stack, the data; the project file has the commands). For anything that needs root, stop: the first thing in your reply is the exact steps, in order, with the commands to run.

**Gate every post and edit from this procedure** (`github-threads` 1.6).

### 1. Check it is not already fixed

Two minutes, before a stack, before reading code.

```bash
git log --oneline origin/<base> -- <the files this would touch>
gh issue view <N> --json assignees,comments        # someone already on it?
gh pr list --state all --search "<keyword>"        # an open or merged PR
```

If the tracker was migrated, commits cite the old number, which the issue body names (the project file has this repo's form). Then ask what already owns this: a framework, validation layer or type boundary may guarantee the thing you are about to guard.

**A hit is not proof.** Read the commit and confirm the behavior is in today's code. If it is already fixed, comment on the issue with the commit and the current `file:line`, recommend closing, and stop. Otherwise claim the issue before you start: `gh issue edit <N> --add-assignee @me` where you have triage rights; otherwise the repro comment (step 2) is the claim.

### 2. Prove the problem exists

Reproduce it per `evidence` in the running app (use the project file’s Running the app → Preflight and Start before reproducing), then comment it on the issue: what you did and what you saw, with its screenshot or video. If you cannot reproduce it, comment what you tried and what happened, and stop.

**When the cause isn't obvious, build a red loop before a theory:** one fast, repeatable command that goes red on the reported symptom (a failing test, a curl, a script that drives the browser), then probe one change at a time.

For a feature, capture the current state as the before shot and settle what "done" means. For a restructure, capture what the code does now: the behavior you must preserve.

### 3. Find an approach that rates high, or stop

List the distinct problems the change must solve. Then rate each candidate approach 0–10 on how confident you are that it is the obviously right approach (not on implementation quality):
- **Generate two or three before rating any**, peers read first (1.1.5), including *not building it*, from a neutral brief (`delegating` 1.10); for someone else's library or API, use finality's Phase B branches.
- **Rate as the code's owner, for all its users:** fixing a bug they all share is not a cost.
- **Leave the frame:** invert it, or delete what everyone treats as immovable.
- **Shared assumptions count once.** Candidates resting on the same unspoken assumption count as one.
- **Siblings decide the scope.** Before choosing, check the same failure in the mechanism's other cases (the other methods, statuses, adapters, runtimes). One that fails the same way, in the same mechanism and files, with the title still true, is part of this fix: a follow-up PR would only make the maintainer review the same code twice. One that spreads to other modules or needs its own decision gets its own PR, opened now (`core` 1.1.7).

**6 or below is not ready to build.**
- If the work adds a surface, rate the **contract** (the surface, its invariants, its counterexamples) before writing a line.
- If the work reshapes existing code, run Phases A and B of the finality pass (open `finality`: it maps the code and derives the shape it should have), and rate that shape.

**Record the approach once per PR.** Write a table `| Candidate | Rating | Why |` (every candidate, *not building it* included, rated 0–10 with its reason) and a line `Chosen: <candidate>` rated 7 or more; a design the maintainer agreed can be the chosen candidate, with the agreement link in the file and the alternatives still rated. Run `pr-steps approach <file>`; it is kept per repo and branch, so later commits don't need it again. The PR body carries it as an "Approach" evidence block (`converge` step 5).

**If nothing rates high, abort.** Comment what you tried and why each falls short, then stop. An open product question hiding in the issue is asked before building.

### 4. Build and gate

**An implementer builds your plan** (`delegating`) by this step; you read its diff through the guardian's lenses. **The smallest diff that finishes the job:** schema, API, every call site, every locale.
- **The gates are in the project file.** The exit code is the verdict, not your reading of the output.
- Keep permanent tests in existing suites within the repo’s habit and the per-capability limit, including deterministic stream-health probes (`core` 1.1.11 and 1.1.16). Expected values come from outside the implementation: a literal, the issue, or a worked example; never recompute them with the same algorithm or snapshot the code’s own output.

**The implementer writes it with the guardian's lenses and the refactor prompt's questions from the first line.** Before writing, open `guardian` for its charter, `refactor` for its questions and `design-loop` for 1.4.1. Before writing new logic, find what already does it: grep the constants, literals and imports the new code will use. Reuse the existing function; when it needs a fix to be reused, that fix is part of this PR. Build deep modules with clean seams (`design-loop` 1.4.1). Keep speculative surface, unreachable defenses and duplicate intent out (`guardian`, BLOAT). Write terse, literally true comments (`writing`), and give each thing a name that reflects one responsibility. Before the review round, read your own diff through those lenses and fix what they catch.

Write the code to the guardian’s standard before its review (`core` 1.1.17).

**Build the whole interaction, not the happy path.** Someone will finish the task, change their mind, go back, reload, mistype, use the keyboard, leave halfway. Anything that would make them wonder what happened is a defect, whether or not the ticket mentioned it.

**Docs, a README or JSDoc in the diff** are written by `docs` (profile, placement, imitation of a sibling page) before the review round, and their fresh-reader check runs on the final text.

**Converging a subsystem** is built as the finality pass's Phase C: behavior-preserving commits, with the gates after each.

**Independent user-visible fixes are separate PRs** (1.1.16). A larger change whose pieces depend on each other becomes a stack of small PRs only as `converge` (stacked PRs) says; otherwise it is one PR with a commit per item.

### 5. See it in the browser

Run the project file’s Preflight, then its isolated Start command.

**Capture "before" by reverting only your own files** (`git checkout origin/<base> -- <files>`), then restore them (`git checkout HEAD -- <files>`); never amend or force-push to fake it.

**Then use it as a user for five minutes,** around your change, not only the path you fixed, as each role it renders for. Fix what your change caused; anything else you trip over gets a disposition (1.1.7), and an issue is opened per `open-issue`.

Stop the stack’s processes when done or aborted (`core` 1.8).

#### UI and runtime work

- **Show it in the real app, used like a person,** per `evidence`.
- **Before anyone sees a UI change,** check each touched page at a phone, a tablet and a desktop width, in light and dark, with its hover, focus and open states. Any console error fails.

### 6. Converge

Open `converge` and run its pipeline on the diff.

### 7. The PR

```markdown
<What was wrong and what changed, in plain sentences.>

Closes #N

### What you should see

**1.** <what to look at and what it proves>

![alt](/abs/path/01-name.png)
```

`Closes #N` only if the change fixes what the issue reported; otherwise `Refs #N`, leave it open, and comment your findings there.

**Write its prose by `writing` and keep the body’s template form** (`writing`, opening precedence). Show real requests and responses for non-UI changes (`evidence`) and benchmarks for hot paths, transports and streams (`writing`). Close with the caveat when a revert cannot undo the merge (`writing`).

**A PR whose feature code (tests, docs and lockfiles excluded) is over about 300 changed lines carries a table of what makes it up.** Write a map file by reading the hunks, one line per feature and range, the features named in the maintainer’s words, and run `loc-breakdown <base>..<head> <map>` (`mechanisms`); put its table in the body. It is evidence, not counted in the word budget. The tool fails on a changed line that no entry or two entries cover, so fix the map until it passes.

#### The walkthrough

The images are the review, a sequence per `evidence`: open on the defect, close on the fix, and between them show what your change could have broken and didn't.

#### Publishing

```bash
gh pr create --draft --base <base> ...   # + labels per the project file, where you can label
gh pr ready <N>                         # once `merging`'s Ready list holds on the final head
gh pr edit <N> --body-file body.md --attach '/abs/path/01-name.png#alt text'
```

Images and video upload per `evidence`.

**Labels and conventions** follow the project file.

#### Inline comments

**Only where a careful reviewer would want to form their own opinion:**
- a judgment call that could have gone the other way (say what the other way was);
- something the diff cannot show;
- a risk you are handing over.

Not what the code does. No comments at all is the normal outcome for a small fix. Lines must fall inside the diff.

One gated draft per comment (`post-lint --kind inline`):

```bash
gh api repos/<owner>/<repo>/pulls/<N>/comments -F body=@<abs>/drafts/<name>.md -f commit_id=<head sha> -f path=<path> -F line=42 -f side=RIGHT
```

Re-check every body claim and caption against its evidence after each push (`writing`).
