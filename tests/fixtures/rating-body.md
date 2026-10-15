<img src="https://github.com/claude.png" width="20" height="20" alt="Claude"> *Opus 5.5 (high effort) wrote this and the code; a second Opus 5.5 (medium effort) reviewed this. [WIP](https://github.com/vikejs/vike/issues/3407#issuecomment-6078092828)*

A server that answers some routes itself and calls `vike.fetch()` for the rest skips the `+middleware` of Vike extensions on its own routes (#3608). brillout [asked](https://github.com/vikejs/vike/issues/3608#issuecomment-6134410651) for a deprecation warning pointing to a migration page, instead of removing `vike/fetch` right away.

| Case | Observed on `main` | Expected |
|---|---|---|
| A `+server.js` with `import vike from 'vike/fetch'` | No warning | Works, and warns once with a link to the migration page |
| `+server: true` (Vike's built-in server, which loads the same handler) | No warning | No warning |
| /server "Other" tab, /serverEntry Bun example, /cloudflare Durable Objects | Use `vike/fetch` | Show what to use instead |

`vike/fetch` keeps working and prints, once:

```
[vike][Warning] import vike from 'vike/fetch' is deprecated, see https://vike.dev/migration/vike-fetch
```

The new page /migration/vike-fetch sends a `+server.js` that only exports `vike/fetch` to `+server: true`, and every other server to `vike(app)` (Hono in the example, the other adapters via /server, and /vike(app)#manual-integration for a server without one). It doesn't offer `renderPage()`: since #3594 it throws when the app has a `+middleware`, while `vike/fetch` runs them. For the same reason, the /server "Other" tab now links /vike(app)#manual-integration, and the /serverEntry Bun example and the /cloudflare Durable Objects example use `@vikejs/hono`.

Release it with or after vikejs/vike-server-adapters#10: until then, the published `@vikejs/hono` 0.3.0 warns a migrated app to update to a version that doesn't exist yet.

Refs #3608

### What you should see

Evidence on head 6ae05290fc; the two commits after it change only docs.

**1.** A `vike/fetch` import warns once. This is `test/@cloudflare_vite-plugin_ud`, whose `+server.ts` imports `vike/fetch`, with three requests:

```
GET / -> 200
GET / -> 200
GET /about -> 200
--- server output (dev):
[vike][Warning] import vike from 'vike/fetch' is deprecated, see https://vike.dev/migration/vike-fetch
  VITE v8.0.7  ready in 2690 ms
```

**2.** `+server: true` prints no warning: `examples/react-minimal` with a temporary `server: true` answered `/`, `/` and `/about` with 200 in `vike dev` and in `vike build && vike preview`, without any warning.

**3.** That Cloudflare app's e2e asserts the warning with `expectLog()`, and passes in dev and preview; with the warning removed from the build, it goes red.

**4.** The new /cloudflare snippet works as written: put into that same app as its `+server.ts`, it answered `/`, `/about` and `/todo` (the Durable Object to-do list) with 200 in dev.

<details>
<summary>Files: 16, one changed</summary>

| File | Old ⇒ new | Why |
|---|---|---|
| `docs/headings.ts` | 9 ⇒ 9 | One entry, added at the end like the other recent migrations, titled like its sibling "Migrate `vike-cloudflare`". |
| `docs/pages/cloudflare/+Page.mdx` | 8 ⇒ 8 | The 14-line code block becomes one note that links `/server#server-true`. Its last clause repeats the `/server` note, but it's what makes the instruction believable. |
| `docs/pages/migration/vike-fetch/+Page.mdx` | 8 ⇒ 8 | The reason first, then the common case (delete two lines) with its code, the empty-file case as a note, then `vike(app)` as a diff. The diff repeats the `fetch` key, as `/build-your-own-framework`'s diff repeats `extends`. |
| `docs/pages/server/+Page.mdx` | 9 ⇒ 9 | The "Other" choice links `/vike(app)#manual-integration` instead of showing a deprecated API, both of its code blocks go, and one note under `+server: true` states the new behavior. |
| `docs/pages/serverEntry/+Page.mdx` | 7 ⇒ 7 | The Bun example takes Hono and `vike(app)` only to get a fetch handler. Without them it would compose `globalContext.middlewares` by hand, which is longer and is what `vike/fetch` did, so no change. |
| `docs/public/llms.txt` | 8 ⇒ 8 | Drops `vike/fetch` from both lines and adds a few words to `/server`. It lists no migration page, so none for `/migration/vike-fetch`. |
| `packages/vike/fetch.js` | 9 ⇒ 9 | The root shim only points to the moved file. |
| `packages/vike/package.json` | 6 ⇒ 9 | The `./fetch` target and the `typesVersions` entries were right; the `./__internal/fetch` shape is fixed in [bb020aa0db](https://github.com/vikejs/vike/commit/bb020aa0db). |
| `packages/vike/src/node/vite/plugins/pluginUniversalDeploy/getServerConfig.ts` | 9 ⇒ 9 | Only the specifier and its comment change, and the comment stays true. |
| `packages/vike/src/node/vite/plugins/pluginUniversalDeploy/pluginUnwrapProdOptions.ts` | 8 ⇒ 8 | It's the only place that sees a `+server.js`'s exports when it's bundled, so the fallback belongs here. The generated module grows by two lines and a comment. |
| `packages/vike/src/server/__internal/fetch-deprecated.ts` | 9 ⇒ 9 | Same shape as its sibling `deprecated-export.ts` (re-export, `TO-DO/next-major-release`, a one-time `assertWarning`), and the same message form as the `vike-server` deprecation in `detectDeprecated.ts`. Its `assertEnvServer` import repeats `fetch.ts`'s, but Vike's `lint-assertenv` script requires one in each file under `src/server/`. |
| `packages/vike/src/server/__internal/fetch.ts` | 9 ⇒ 9 | Moved where you [asked](https://github.com/vikejs/vike/pull/3609#issuecomment-6179139693); only its import path changed. |
| `packages/vike/src/server/runtime/fetch.ts` (deleted) | 10 ⇒ 10 | Moved, not lost, and nothing references `runtime/fetch` anymore. |
| `packages/vike/src/types/Server.ts` | 9 ⇒ 9 | `Partial<Fetchable>` is the one-word change the new behavior needs. |
| `test/@cloudflare_vite-plugin_ud/+server.ts` | 8 ⇒ 8 | Now the shape a real app with a Durable Object has, and its comment says what the file relies on. |
| `test/custom-server-entry/.testRun.ts` | 6 ⇒ 6 | It checks a message's text, so it goes in the last commit before the squash-merge. |

</details>

<details>
<summary>Functions: 7, none changed</summary>

| Function | Old ⇒ new | Why |
|---|---|---|
| `getServerConfig()` | 9 ⇒ 9 | One string changed; the rest is `main`'s. |
| `pluginUnwrapProdOptions()` | 7 ⇒ 7 | Its name covers one of its two jobs now, and the comment above `load()` names both; kept for the reason above. |
| `load(id)`, the generated module | 8 ⇒ 8 | Its lines are rated one by one under Logic. |
| `fetch.ts`'s default export, `{ fetch: vikeUniversalMiddleware }` | 9 ⇒ 9 | What both Universal Deploy's entry and the fallback need, with no wrapper. |
| `fetch-deprecated.ts`'s module body | 9 ⇒ 9 | Warns once per process, with the import in cyan and the link underlined, as the `vike-server` deprecation warning does. |
| `testRun()`'s deprecation test | 6 ⇒ 6 | As its file above. Its `fetchHtml('/')` first makes sure the server module loaded. |
| `testRun()`'s other tests | 9 ⇒ 9 | Unchanged. |

</details>

<details>
<summary>Logic: 13 pieces, one changed</summary>

| Logic | Old ⇒ new | Why |
|---|---|---|
| `import * as mod` instead of `import mod` | 9 ⇒ 9 | Rolldown fails the build on a default import from a `+server.js` without a default export, and the namespace import is the only static form that works for both. |
| `const { default: server } = mod` and its comment | 8 ⇒ 8 | Rolldown warns `IMPORT_IS_UNDEFINED` on `{ ...mod.default }` and stays quiet on the destructured form, so the comment is true, and it sits on the line it explains. |
| `{ ...server, ...server?.prod, fetch: server?.fetch ?? vikeFetch.fetch }` | 8 ⇒ 8 | Reading `fetch` through the prototype chain keeps a `fetch` that isn't an own property, as on Elysia's app ([f5ea3cd3b4](https://github.com/vikejs/vike/commit/f5ea3cd3b4)), and `??` falls back only when it's missing. `vikeFetch.fetch` stutters, but a rename buys nothing in a generated module. |
| `import vikeFetch from 'vike/__internal/fetch'`, always | 7 ⇒ 7 | It costs 3.4 kB, only when `+server.js` has its own `fetch` ([measured](https://github.com/vikejs/vike/pull/3609#discussion_r4280145702)). A lazy `import()` doesn't shrink the build, and dropping it needs Vike to know at build time whether the default export has `fetch`. |
| `'vike/__internal/fetch'` in both `getServerConfig.ts` and the generated module | 7 ⇒ 7 | The string is repeated, but a shared constant would add an import to save one copy of a package path. |
| The `./__internal/fetch` export's conditions | 5 ⇒ 9 | `worker`, `workerd` and `node` equal to `default` existed only to win over a `browser` entry that nothing needs; [bb020aa0db](https://github.com/vikejs/vike/commit/bb020aa0db). |
| The `./fetch` export pointing to `fetch-deprecated` | 10 ⇒ 10 | The same conditions as before with a new target, so nothing in it could be simpler. |
| `Server extends Partial<Fetchable>` | 9 ⇒ 9 | Says exactly "`fetch` is optional". |
| The deprecation `assertWarning` at module load | 9 ⇒ 9 | The sibling's pattern, and it fires for anyone who imports `vike/fetch`, re-exporting it included. |
| The order of `/migration/vike-fetch` | 8 ⇒ 8 | Each case follows from the previous one's "if", so it reads top to bottom. |
| `/server`'s new note under `+server: true` | 8 ⇒ 8 | One sentence with two links, where a reader of `+server: true` looks. |
| The Bun example on Hono | 7 ⇒ 7 | As `serverEntry/+Page.mdx` above. |
| `test/custom-server-entry/+server.ts` still importing `vike/fetch` | 8 ⇒ 8 | On purpose: the deprecation test and the `/shared-context` route need it. |

</details>


<details>
<summary>Gates</summary>

CI on 6a1a1f5d8d: all 20 checks pass. Locally: `build`, `format:check`, `lint`, `spellcheck:check`, `docs:lint`, `docs:build`, `test-types`, `vitest --project unit`: exit 0. `test-e2e test/@cloudflare_vite-plugin_ud` and `test-e2e test/custom-server-entry`: dev and preview PASS.
</details>

<details>
<summary>Approach</summary>

| Candidate | Rating | Why |
|---|---|---|
| Public `vike/fetch` points to a module that warns and re-exports; `+server: true` resolves `vike/__internal/fetch` | 8 | Only a user's import reaches the warning; same shape as `vike/universal-middleware`'s `deprecated-export.ts` and the `vike/__internal` entries |
| One module that warns on the first `fetch()` unless Vike's entry set a flag | 3 | Needs state shared between the build-time entry and the runtime, and warns on the first request instead of at startup |
| Vike's entry imports the dist file by absolute path | 4 | Skips the `worker`/`workerd`/`node` export conditions the package specifier gets |
| Remove `vike/fetch` outright | 2 | brillout [asked](https://github.com/vikejs/vike/issues/3608#issuecomment-6134410651) for a deprecation warning instead |

Chosen: the first.
</details>
