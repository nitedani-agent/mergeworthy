import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { fill } from '../lib/briefs.mjs'
import { classify } from '../lib/classify.mjs'
import { memoryLedger, openLedger } from '../lib/ledger.mjs'
import { plan } from '../lib/planner.mjs'
import { nextReplyStep } from '../lib/reply.mjs'

const T0 = Date.parse('2026-10-13T19:00:00Z')
const iso = (min) => new Date(T0 + min * 60e3).toISOString()
const config = { root: '/r', projects: '/p', voice: '/v/voice.md' }
const comment = (over = {}) => ({ kind: 'comment', at: iso(0), repo: 'vikejs/vike', number: 3594, id: 61, author: 'brillout', url: 'https://github.com/vikejs/vike/pull/3594#issuecomment-61', body: 'Why is this async?', onIssue: false, ...over })

test('classify: each class from real comments', () => {
  const cases = [
    ['Why is this async?', {}, 'question'],
    ['Document the sandwich approach in the root README.md', {}, 'instruction'],
    ["Let's define a function e.g. setHeadersWithMultipleCookies", {}, 'instruction'],
    ['merge origin/main', {}, 'instruction'],
    ['=> feel free to squash-merge', {}, 'merge-ask'],
    ['Wait, I sent my reply too early. Wait until I send my full reply (ETA 10mn).', {}, 'wait'],
    ['Ah, I see, nevermind. Yes keep it.', {}, 'ack'],
    ['LGTM', {}, 'ack'],
    ['cfb1f91e7ace1bc23c6bc17d0cc53234a4740a9a', {}, 'none'],
    ['`@nitedani` Thanks for the fix. The unconditional assignment clears it', { author: 'coderabbitai[bot]' }, 'none'],
    ['**Major** the header is dropped on rebuild', { author: 'coderabbitai[bot]' }, 'bot-finding'],
    ['My concern with server entry wrapping is that it only works with +server, what if the user has their own server and calls renderPage() directly from it?', { onIssue: true }, 'design'],
  ]
  for (const [body, over, cls] of cases) assert.equal(classify({ author: 'brillout', body, ...over }).cls, cls, body)
})

test('reply: a question goes to the drafter, then approval; a holding reply comes due after 15 minutes', () => {
  const c = comment()
  assert.equal(nextReplyStep(c, { done: new Set(), now: T0 }).step, 'draft')
  const late = nextReplyStep(c, { done: new Set(), now: T0 + 16 * 60e3 })
  assert.equal(late.step, 'holding')
  assert.equal(late.deadline, T0 + 30 * 60e3)
  assert.equal(nextReplyStep(c, { done: new Set(['holding']), now: T0 + 16 * 60e3 }).step, 'draft')
  assert.equal(nextReplyStep(c, { done: new Set(['draft']), now: T0 + 16 * 60e3 }).step, 'approve')
  assert.equal(nextReplyStep(c, { done: new Set(['draft', 'approve']), now: T0 }), null)
})

test('reply: a design point gets the debate before the draft; an instruction gets the implementer first', () => {
  assert.equal(nextReplyStep(comment({ body: 'x'.repeat(200) + '?', onIssue: true }), { done: new Set(), now: T0 }).step, 'debate')
  assert.equal(nextReplyStep(comment({ body: 'Remove the HatTip adapter' }), { done: new Set(), now: T0 }).step, 'implement')
})

test('reply: a wait with an ETA yields nothing until then', () => {
  const c = comment({ body: 'Wait until I send my full reply (ETA 10mn).' })
  assert.equal(nextReplyStep(c, { done: new Set(), now: T0 + 5 * 60e3 }).step, 'wait')
  assert.equal(nextReplyStep(c, { done: new Set(), now: T0 + 11 * 60e3 }), null)
})

test('planner: the user, then red CI, then the maintainer, whatever arrived first', () => {
  const ledger = memoryLedger([
    comment(),
    { kind: 'ci', at: iso(1), repo: 'vikejs/vike', number: 3600, red: true, checks: 'e2e' },
    { kind: 'user', at: iso(2), id: 'u1', text: 'status?' },
    { kind: 'take', at: iso(3), id: '1', text: 'side quest', lane: 'side' },
  ])
  const ids = plan(ledger, T0 + 3 * 60e3, config).actions.map((a) => a.item.split('/')[0])
  assert.deepEqual(ids, ['user', 'ci', 'vikejs', 'take'])
})

test('planner: two comments order by their live deadline; a closed comment yields nothing', () => {
  const ledger = memoryLedger([comment({ id: 2, at: iso(5) }), comment({ id: 1 }), comment({ id: 3, body: 'LGTM', at: iso(1) }), comment({ id: 4, author: 'coderabbitai[bot]', body: 'Thanks for the fix.' })])
  const { actions, closed } = plan(ledger, T0 + 6 * 60e3, config)
  assert.deepEqual(actions.map((a) => a.id.split('/').slice(-2).join('/')), ['1/draft', '2/draft', '3/ack'])
  assert.deepEqual(closed.map((c) => c.item), ['vikejs/vike#3594/4'])
})

test('planner: the drafter brief names the notes, the pinned head, the thread record and the voice, and carries the item memory', () => {
  const ledger = memoryLedger([
    { kind: 'head', at: iso(-10), repo: 'vikejs/vike', number: 3594, sha: 'bf675aa' },
    { kind: 'failed', at: iso(-5), thread: 'vikejs/vike#3594', text: 'post blocked: the reply ran over the budget' },
    comment(),
  ])
  const [action] = plan(ledger, T0, config).actions
  assert.match(action.brief, /^Notes: \/p\/vikejs\/vike\.md/m)
  assert.match(action.brief, /^Pin: bf675aa/m)
  assert.match(action.brief, /^Thread record: \/r\/items\/vikejs-vike-3594-61\/thread\.md/m)
  assert.match(action.brief, /^Voice: \/v\/voice\.md/m)
  assert.match(action.brief, /ran over the budget/)
  assert.deepEqual(action.memory.length, 1)
})

test('briefs: a missing field throws instead of leaving a hole', () => {
  assert.throws(() => fill('drafter', {}), /no value for \{\{notes_path\}\}/)
})

test('ledger: append-only on disk, read back in order', () => {
  const root = mkdtempSync(join(tmpdir(), 'mw-'))
  openLedger(root).append({ kind: 'user', at: iso(0), id: 'a', text: 'x' })
  openLedger(root).append({ kind: 'user', at: iso(1), id: 'b', text: 'y' })
  assert.deepEqual(openLedger(root).records().map((r) => r.id), ['a', 'b'])
})

test('mw next and mw done: a question runs draft, then approve, then nothing', () => {
  const root = mkdtempSync(join(tmpdir(), 'mw-'))
  openLedger(root).append(comment())
  const env = { ...process.env, MW_ROOT: root, MW_PROJECTS: '/p', MW_VOICE: '/v/voice.md', MW_NOW: iso(1) }
  const mw = (...args) => spawnSync(process.execPath, [new URL('../bin/mw', import.meta.url).pathname, ...args], { env, encoding: 'utf8' })
  const next = mw('next')
  assert.match(next.stdout, /^id: vikejs\/vike#3594\/61\/draft$/m)
  const brief = join(root, 'items', 'vikejs-vike-3594-61', 'brief.md')
  assert.match(readFileSync(brief, 'utf8'), /^Thread record: /m)
  assert.equal(mw('done', 'vikejs/vike#3594/61/draft', join(root, 'nope.md')).status, 1)
  const draft = join(root, 'draft.md')
  writeFileSync(draft, 'answer')
  assert.match(mw('done', 'vikejs/vike#3594/61/draft', draft).stdout, /id: vikejs\/vike#3594\/61\/approve/)
  assert.match(mw('done', 'vikejs/vike#3594/61/approve').stdout, /nothing due/)
})

test('mw done --no keeps the step due and puts the reason in its memory', () => {
  const root = mkdtempSync(join(tmpdir(), 'mw-'))
  openLedger(root).append(comment())
  const env = { ...process.env, MW_ROOT: root, MW_PROJECTS: '/p', MW_VOICE: '/v', MW_NOW: iso(1) }
  const out = spawnSync(process.execPath, [new URL('../bin/mw', import.meta.url).pathname, 'done', 'vikejs/vike#3594/61/draft', '--no', 'the brief misread the question'], { env, encoding: 'utf8' }).stdout
  assert.match(out, /id: vikejs\/vike#3594\/61\/draft/)
  assert.match(out, /rejected .*misread the question/)
})
