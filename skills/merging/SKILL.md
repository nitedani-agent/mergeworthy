---
name: merging
description: "Pushing, saying a PR is ready, merging, stacked PRs' bases."
---

# Merging

Called by `pull-request` steps 7, 11 and 12; when done, return there. Maintainers may push to your branches and may merge them.

## Steps

1. **Push.** Before any push: fetch; rebase unpushed commits onto the remote branch and re-run the quick gates (`code §Gates`); check you're on top; push to the PR's head repository by URL, never by a remote's name (`origin` is upstream in some checkouts, and a push there opens a branch in the maintainer's repo). Never force-push, except on your own unmerged branch with `--force-with-lease=<branch>:<sha you last pushed>`; never push to a merged branch. Implementers commit in their own worktrees; only you push to the PR branch.
   Run: `git -c user.name=<login> -c user.email=<id>+<login>@users.noreply.github.com commit`; `git rebase origin/<branch>`; `git merge-base --is-ancestor <remote> HEAD`; `gh pr view <N> --json headRepositoryOwner,headRefName` · Record: the push · Hook: pre-bash-guard (author, lease, stash), pre-skill-gate
2. **Ready check, on the head.** Re-read the whole thread, inline comments included: each maintainer instruction is a checkbox for its PR; tick or do each. `replies-owed.md` has no line for this PR. CI is green, or only workflow approval is pending (§CI limits). The body is true of the head, and a UI change has a screenshot in it. The five `converge` records and the approach record are checked by the hook.
   Run: `gh pr checks <N>` · Hook: pre-bash-guard (the records, the State line)
3. **Say it.** Edit the body without the State line (through `post`), `gh pr ready <N>`, then say once, in plain words, "Ready for review" with the head SHA and the CI link. "Reply `merge` and I'll squash-merge it" only in the user's own repos, and never when the `merge` option is `reviewer` (`task §Files`).
   Open: `post`; `writing §Reports to the user` · Record: the PR's state · Hook: pre-bash-guard
4. **Merge only after a maintainer asks.** First retarget PRs based on this branch (`gh pr edit <N> --base <its base>`): deleting the branch closes them. After the squash, merge the new base into each, so their diff shows only their own change. If the repo's `AGENTS.md` requires another merge form, ask the user: the hook allows only this one.
   Run: `gh pr merge <N> --squash --delete-branch --subject "<PR title> (#<N>)" --body ""` · Record: the merged PR · Hook: pre-bash-guard (the form, dependents)

### CI limits

`gh run rerun` on an upstream repo needs admin rights: ask a maintainer. Fork PRs get no CI secrets, so those jobs fail on forks. A first-time contributor's fork PR runs no workflow until a maintainer approves it: say ready with "CI waits for workflow approval" and the local gates' exit codes on the head, and tick CI once it ran; it can't merge before.
