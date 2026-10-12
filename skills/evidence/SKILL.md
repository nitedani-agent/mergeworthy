---
name: evidence
description: "Showing a behavior to a reader who wasn't there: browser control, reproducing it in the running app as a person would, a screenshot, a video or the request, and uploading it. Shared by open-issue and pull-request."
---

# Evidence

What lets a newcomer see a behavior for themselves: where it is, what triggers it and what happens. An issue (`open-issue`), a reproduction comment and a PR's walkthrough (`pull-request`) all show it this way.

**Browser control** (UI or runtime work): a [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp), or anything that opens a page, clicks, screenshots and records it. Try it on the app's URL before you start; nothing in a shell can test it. A dev host's bad certificate needs the MCP's `--acceptInsecureCerts` (Chrome: `--ignore-certificate-errors`). Configure the MCP with `--isolated` (e.g. `npx -y chrome-devtools-mcp@latest --headless --isolated`), so parallel sessions don't share one profile. Isolated profiles are temporary: set the cookies and storage the test needs in the page.

### Reproduce it as a person would

- **In the running app, with real mouse, keyboard and touch,** and a screenshot after each action. Scripted events, emulated hover and computed-style diffs don't count. A runtime behavior (a stream, a cancel, a cache) is shown through a real browser, `main` against the head, with the server's logs.
- **From where a newcomer starts:** a fresh login as the role that meets it, the default view, then the steps you will publish. If they don't lead there from a clean start, they aren't the steps.
- **Check the age of the data.** Dev data is often a restored snapshot. If it predates a fix, rows written the old way still make the bug look alive: compare the age of the data with the date of the fix.

### Capture it

- **One screen shows it:** a screenshot of that screen, where a user meets it, not where the code is. A fix to a form is proven only when the thing it configures is on screen behaving differently.
- **Reaching it takes more than one action, or the point is what happens as you act:** a video of the whole flow from the clean start, recorded with real clicks by any tool that records a video. Stills hide layout shift, a flash of stale data, a step that runs twice, a control that enables late. Stills alone are for what is static: formatting, labels, a column's contents.
- **Nothing on a screen shows it:** the evidence that does, in a code block: the request and the response, the command and its output, the payload the service received.
- Caption each image or video with what to inspect and what it proves (`writing`).
- **Disclose anything you did to the page** to get the shot, and whether it reproduces on `<base>`. Redact secrets (1.6).

### Upload it

```bash
gh issue comment <N> --body-file body.md --attach '/abs/path/01-name.png#alt text'   # gh issue create, gh pr edit take it too
```

**`gh` uploads attachments and rewrites matching local paths.** Reference each file by the exact path you pass to `--attach`, then confirm with `gh issue view <N> --json body` (or `gh pr view`) that no local path survived. A video goes in the same way, as `![](<path>.mp4)` alone in its paragraph, and GitHub renders a player. If `gh` lacks `--attach`, upload by hand and link.
