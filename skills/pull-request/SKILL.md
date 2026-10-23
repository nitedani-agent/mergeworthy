---
name: pull-request
description: "A change that will land in a PR, from an issue or not, until it merges: worktree, already fixed?, reproduce, approach rating, build, the draft PR, seeing it in the app, converging it, the body, ready."
---

# Pull request

Run `task` first. A Tier M or L change runs these steps once per PR.

## Steps

1. **Worktree off the target repo's base** (the project file names it). `origin` here is the repository the PR targets; in a fork clone, fetch the upstream repository and branch from its base, never from the fork's, which may be stale. Read the repo's `AGENTS.md` / `CLAUDE.md` and its own `.claude/skills/pull-request/SKILL.md` on `origin/<base>`: they govern how the code is written and the implementation steps.
   Run: `git fetch origin && git worktree add -b <branch> <work folder>/<branch> origin/<base>`
2. **Check you can finish before you start.** Start the app (project file, Running the app: Preflight, then Start), then record that a browser loads it; `gh` and its login, and whatever the app needs (containers, the hostname, the secrets, the data). Install whatever doesn't need root. Anything needing root: stop, and your reply starts with the exact commands, in order.
   Run: `pr-steps preflight <its URL>` (or `'none, because <why there is no UI or browser-run code>'`) · Record: the preflight record · Hook: pre-design-gate (edits wait for it), pre-bash-guard (commits wait for it)
3. **Already fixed?** Two minutes, before reading code. A hit is not proof: read the commit and confirm the behavior in today's code (the project file says how a migrated tracker's numbers appear in commits). Ask what already owns this: a framework, validation layer or type boundary may guarantee what you are about to guard. Fixed: comment the commit and the current `file:line` on the issue through `post`, recommend closing, and stop. Not fixed: claim it (`gh issue edit <N> --add-assignee @me` where you have triage rights; otherwise step 4's comment is the claim).
   Run: `git log --oneline origin/<base> -- <files>`; `gh issue view <N> --json assignees,comments`; `gh pr list --state all --search "<keyword>"`
4. **Reproduce it** in the running app, then comment on the issue what you did and what you saw, with its screenshot or video, through `post`. Can't reproduce: comment what you tried and what happened, and stop. When the cause isn't obvious, build a red loop before a theory: one fast, repeatable command that goes red on the reported symptom (a failing test, a curl, a script that drives the browser), then probe one change at a time. A feature: capture the current state as the before shot and settle what "done" means. A restructure: capture the behavior to keep.
   Open: `evidence` steps 1–4 · Record: the comment
5. **Approach, at high effort.** List the distinct problems the change must solve. Web-search how others solved each, then generate two or three candidates, *not building it* among them, before rating any, from a neutral brief; rate each 0–10 on how confident you are that it is the obviously right approach (§Rating). A new API, protocol or a Tier M or L design: run `design` first; a design the maintainer agreed can be the chosen candidate, with the agreement link and the alternatives still rated. Reshaping existing code: `finality` steps 2–3, and rate that shape. A new surface: rate its contract (the surface, its invariants, its counterexamples). Write `<work folder>/approach.md`: a line `Root cause: <why it happens, with the path:line that does it>` (a feature or a reshape: `Root cause: none, <what it is>`), the table `| Candidate | Rating | Why |` and a line `Chosen: <candidate>` rated 7 or more. 6 or below: comment what you tried and why each falls short, and stop. An open product question hiding in the issue is asked before building.
   Open: `delegate/designer.md`; §Rating · Run: `pr-steps approach <work folder>/approach.md` · Record: the approach record · Hook: pre-bash-guard (ready, non-draft create)
6. **Build.** Brief an implementer; it reads `code`, the project file and its repo study (`task` step 4) before writing, so what the study says the maintainer asks for, cuts and rewrites is in the work before any review: the smallest diff that finishes the job (schema, API, every call site, every locale). Read its diff against `code §Checklist` and write down each structural decision before landing it. Quick gates after every commit; the exit code is the verdict. Docs, a README or JSDoc in the diff: `docs` steps 1–4 before the review round. Reshaping code: `finality` step 5. Independent user-visible fixes are separate PRs, except one in the code the change edits (`task §Dispositions`); pieces that depend on each other stack only as `converge §Stacked PRs` says, otherwise one PR with a commit per item.
   Open: `delegate/implementer.md`; `code §Gates`; `delegate` step 6 · Record: commits
7. **The draft PR, with the branch's first push.** Title: `<work folder>/drafts/<branch>/title.md`, the squash commit's subject and so the changelog line, in the repo study's merged-title form, in a user's words, linted (`post-lint --kind title`) and reviewed with the body in `post` step 3; a title someone else set stays theirs (the thread record shows who retitled it): change it only after they agree on the PR; otherwise, when the scope changes, the main session rewrites it and applies it with `gh pr edit --title "$(cat <that file>)"` through `post`. Body: the problem on `main` under `**State: draft** (<why it's a draft, in plain words>)`, through `post` in its fast form, so CI runs while it converges. Labels per the project file, where you can label.
   Open: `merging` step 1; `post` steps 1–5 with `--kind pr --draft` · Run: `gh pr create --draft --base <base> --title "$(cat <work folder>/drafts/<branch>/title.md)"` · Record: the PR · Hook: pre-bash-guard (the State line; a `--title` not read from a file), pre-skill-gate
8. **See it in the app.** Capture before by reverting only your own files, then restore them; never amend or force-push to fake it. Use it as a user for five minutes around the change, not only the path you fixed, as each role it renders for; give each thing you trip over its disposition (`task §Dispositions`). UI: each touched page at a phone, a tablet and a desktop width, light and dark, with its hover, focus and open states; any console error fails. Stop what you started.
   Open: `evidence` steps 2–4 · Run: `git checkout origin/<base> -- <files>`, then `git checkout HEAD -- <files>` · Record: screenshots in the work folder
9. **Converge the head.**
   Open: `converge` steps 0–5 · Record: the five records · Hook: pre-bash-guard
10. **The body.** `drafts/<pr>/pr-body.md` from §Body; feature code (tests, docs and lockfiles excluded) over ~300 changed lines adds the `loc-breakdown` table: write a map file by reading the hunks, one line per feature and range, the features named in the maintainer's words, and fix it until the tool passes. Upload images and video. Inline comments only per §Inline comments, each its own draft through `post`.
   Open: §Body; `writing §Forms`; `evidence` step 5; `post` with `--kind pr` and `--kind inline` · Run: `loc-breakdown <base>..<head> <map file>` · Record: the body's gate file · Hook: gate-pass, post-lint
11. **Ready.**
   Open: `merging` steps 2–3 · Record: the PR's state · Hook: pre-bash-guard
12. **Until merged,** each event goes through `reply`; after each push, re-check every body claim and caption against its evidence. Merge only when a maintainer asks.
   Open: `reply`; `merging` step 4 · Hook: the watcher

### Rating

- **Rate as the code's owner, for all its users:** fixing a bug they all share is not a cost.
- **Leave the frame:** invert it, or delete what everyone treats as immovable. For someone else's library or API, generate the candidates as `finality` step 3 does. When a dependency causes the bug, one candidate stops it at its source, citing the line in that dependency's code that allows it; stopping a behavior ranks above undoing it after the fact (vikejs/vike#3611 over #3610).
- **Shared assumptions count once.** Candidates resting on the same unspoken assumption count as one.
- **Siblings decide the scope.** Before choosing, check the same failure in the mechanism's other cases (the other methods, statuses, adapters, runtimes). One that fails the same way, in the same mechanism and files, with the title still true, is part of this fix. One that spreads to other modules or needs its own decision gets its own PR, opened now.

### Body

```markdown
<What was wrong, in plain sentences.>

| Case | Observed | Expected |
|---|---|---|
| <input> | <what happens> | <what should happen> |

<What changed.>

Closes #N

### What you should see

**1.** <what to look at and what it proves>

| What | Before (<base>) | After (this PR) |
|---|---|---|
| <the step> | ![](/abs/path/01-base.png) | ![](/abs/path/01-head.png) |
```

- `Closes #N` only if the change fixes what the issue reported; otherwise `Refs #N`, leave the issue open, and comment your findings there.
- **What you should see** is the review: numbered items, each a before/after pair (`evidence` step 4: screenshots in a table, videos as two paragraphs) or a request and response, outside any `<details>`, in sequence: the defect's pair first, then what your change could have broken and didn't, each showing base and head the same. Non-UI changes show real requests and responses; hot paths, transports and streams a `main`/head benchmark table.
- The evidence blocks of `converge §Evidence blocks` come after it.

### Inline comments

Only where a careful reviewer would want to form their own opinion: a judgment call that could have gone the other way (say what the other way was), something the diff cannot show, a risk you are handing over. Not what the code does; no comments at all is the normal outcome for a small fix. Lines must fall inside the diff.

```bash
gh api repos/<owner>/<repo>/pulls/<N>/comments -F body=@<abs>/drafts/<pr>/<name>.md -f commit_id=<head sha> -f path=<path> -F line=42 -f side=RIGHT
```
