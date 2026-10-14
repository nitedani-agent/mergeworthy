---
name: evidence
description: "Showing a behavior to a reader who wasn't there: browser control, reproducing it in the running app as a person would, a screenshot, a video or the request, and uploading it. Called by pull-request and open-issue."
---

# Evidence

What lets a newcomer see a behavior for themselves: where it is, what triggers it and what happens. Called by `pull-request` steps 4, 8 and 10 and `open-issue` steps 2 and 4; when done, return there.

## Steps

1. **Browser control:** only the Chrome DevTools MCP, with `--isolated` so parallel sessions don't share a profile, muted and without WSLg's audio server. Registering it changes the user's global config, so the main session asks the user first (always-on, Every session), giving `claude mcp remove chrome-devtools; claude mcp add chrome-devtools -- env -u PULSE_SERVER npx -y chrome-devtools-mcp@latest --headless --isolated --chrome-arg=--mute-audio`, which takes effect in the next session. An agent whose running MCP lacks those flags stops and reports it to the main session. `pr-steps preflight` only checks that the app loads. A dev host's bad certificate needs `--acceptInsecureCerts`. Isolated profiles are temporary: set the cookies and storage the test needs in the page. Load the app's URL first.
   Run (for a PR's branch only): `pr-steps preflight <URL>` · Record: the preflight record
2. **Reproduce it as a person would,** in the running app, with real mouse, keyboard and touch, and a screenshot after each action. Scripted events, emulated hover and computed-style diffs don't count. Start where a newcomer starts: a fresh login as the role that meets it, the default view, then the steps you will publish; if they don't lead there from a clean start, they aren't the steps. Check the age of the data: dev data is often a restored snapshot, and rows written before a fix still make the bug look alive.
3. **A runtime behavior** (a stream, a cancel, a cache) is shown through a real browser, `main` against the head, with the server's logs; a Node script alone doesn't show it.
4. **Capture it.**
   - One screen shows it: a screenshot of that screen, where a user meets it, not where the code is. A fix to a form is proven only when the thing it configures is on screen behaving differently.
   - Reaching it takes more than one action, or the point is what happens as you act: a video of the whole flow from the clean start, with real clicks. Stills hide layout shift, a flash of stale data, a step that runs twice, a control that enables late; they are for what is static (formatting, labels, a column's contents).
   - Nothing on a screen shows it: the request and the response, the command and its output, or the payload the service received, in a code block.
   - Caption each image or video in one line: what to look at and what it proves, naming the setup (page, date, filter) when the default view doesn't show it; crop so the pixels that matter are findable. Disclose anything you did to the page to get the shot, and whether it reproduces on `<base>`. Redact secrets (`post §Thread rules`).
   Record: the files in the work folder
5. **Upload it.** `gh` uploads attachments and rewrites matching local paths: reference each file by the exact path you pass to `--attach` (`gh issue create`, `gh issue comment` and `gh pr edit` take it). A video goes in as `![](<path>.mp4)` alone in its paragraph. Then confirm no local path survived. If `gh` lacks `--attach`, upload by hand and link.
   Run: `gh issue comment <N> --body-file <abs draft> --attach '/abs/path/01-name.png#alt text'`; `gh issue view <N> --json body` (or `gh pr view`)
