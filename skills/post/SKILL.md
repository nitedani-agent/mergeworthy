---
name: post
description: "Everything that reaches GitHub or another external service (a comment, reply, inline comment, PR or issue body, an edit of any): draft, lint, review to CLEAN, re-check, post."
---

# Post

Everything that reaches an external service passes these steps, with no lighter category: comments, review replies, inline comments, PR and issue bodies, filed issues, and edits of any of these. Reactions are exempt. Only the main session posts; subagents hand it drafts. A reviewed draft isn't permission to publish: the task says what you may open, comment and file. Called by a step of another skill; when done, return to it.

## Steps

1. **Draft** in `<work folder>/drafts/<thread>/<name>.md` (never straight into a `gh` command), with the comment it answers in `<name>.parent.md`. On a thread: build the thread record in the same folder and brief a drafter; you read only its draft and its list of conflicts with past decisions. A PR or issue body: from its template (`pull-request §Body`, `open-issue` step 3). Whoever drafts reads `writing` first and runs `writing §Self-check` before the review.
   Run: `thread-context <owner/repo#N> --out <work folder>/drafts/<thread>/thread-context.md` · Open: `delegate/drafter.md`; `writing` · Record: thread-context.md · Hook: gate-pass and pre-bash-guard (no record, or one without the thread's latest human comment)
2. **Lint until it passes.** gate-pass re-runs it with the same flags.
   Run: `post-lint <draft> --kind <kind> [--repo <owner/repo>] [--draft]` (§Kinds)
3. **Review.** An independent reviewer with the post-review brief. Fix each finding by rewriting the passage in your own words, never patching the reviewer's; lint again (step 2), then re-review until its final message is exactly `CLEAN`. **The fast form,** for a reply of a few claims ("Done in <sha>", a holding reply), a draft PR's first body (`pull-request` step 7) and an edit that changes only a typo or a sha: the same, the reviewer asked only about those claims.
   Open: `delegate §Reviewers`; `delegate/post-review.md` · Record: `<name>.review.out` (the reviewer's final message only) · Hook: gate-pass (review newer than draft)
4. **Right before posting:** `git fetch`, then re-read every claim against the current head and a PR's state. Every commit the draft names exists in the repository its claim or link names: your own PR's commits in its head repository, before the PR exists in the one you push to. A promise ("I'll…", "follow-up PR") first gets its `PROMISED` line in `proposals-open.md` (`task §Files`).
   Run: `git fetch`; `gh api repos/<owner>/<repo>/commits/<sha>` succeeds for each (a PR's head: `gh pr view <N> --json headRepositoryOwner,headRepository`); `gate-pass <abs draft> <abs review output>` · Record: `<name>.md.gate` · Hook: gate-pass, pre-bash-guard
5. **Post in the thread where the person wrote,** from the file, then clear its owed line as `done: <post URL> <what changed>`.
   Run: `--body-file <abs draft>` (API: `-F body=@<abs draft>`) · Open: §Thread rules · Record: the gate file, the owed line · Hook: pre-bash-guard (twice, a third comment, changed after the gate), stop-lint

### Kinds

`post-lint --kind`: `reply` (a comment on a thread; `--parent none` when it answers nobody), `proposal` (a reply that proposes a design or asks agreement to one; counted per thread), `pr` (a PR body; a draft PR's body adds `--draft`), `issue`, `inline` (a review comment on a diff line), `tracker` (the umbrella issue and its Decisions comment; no badge).

### Thread rules

- **At most two comments in a row.** The second is only the answer after its holding reply, a wait ping, a dependency's progress, a 👎 fix, or the review of commits a maintainer pushed after your last comment. Anything else edits your last comment; a would-be third is an edit with an @-mention. pre-bash-guard blocks a third while your last two have no reply from anyone else and the last is under 3 hours old.
- **One reply per person, edits for corrections.** Several comments from one person get one reply. Correct your earlier post in place through these steps.
- **Evidence carries no secret.** In logs, requests, payloads and screenshots, write `<REDACTED>` for every token, cookie, auth header and key, and quote only the lines that show the point (post-lint fails on common token shapes).
- **A maintainer who asks to see how you change this methodology:** write the installed mergeworthy commit (`git -C ~/.mergeworthy/current rev-parse HEAD`) to `~/.mergeworthy/harness-shown/<owner>`; gate-pass then appends to each `reply` or `proposal` a link comparing the commit it names with the installed one.
