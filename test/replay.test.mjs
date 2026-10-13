import assert from 'node:assert/strict'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { judge } from '../replay/judge.mjs'
import { loadEvents, loadOwed } from '../replay/load.mjs'

const dir = mkdtempSync(join(tmpdir(), 'mw-replay-'))
const log = `### vikejs/vike#3546 comment 5913395311 by brillout 2026-09-30T14:32:08Z  https://github.com/vikejs/vike/pull/3546#issuecomment-5913395311
AFAICT it isn't worth it

### CI vikejs/vike#3546: red=['e2e']
### PR CHANGED vikejs/vike#3546: {'head': 'fd0d934af3', 'state': 'open'} -> {'head': 'abc1234567', 'state': 'open'}
### vikejs/vike#3552 review-comment 4146079944 by brillout 2026-09-30T15:01:17Z packages/a.ts:66 https://github.com/vikejs/vike/pull/3552#discussion_r4146079944
Let's define a function
`
const owed = `# replies owed
done: https://github.com/vikejs/vike/pull/3546#issuecomment-1 answered — vikejs/vike#3546 comment 5913395311 by brillout https://x — AFAICT
done: no reply owed, an FYI — vikejs/vike#3552 review-comment 4146079944 by brillout https://y — Let's
`

test('load: comments with their time and path, CI and head changes timed by the comment before them', () => {
  writeFileSync(join(dir, 'events.log'), log)
  const records = loadEvents(join(dir, 'events.log'))
  assert.deepEqual(records.map((r) => r.kind), ['comment', 'ci', 'head', 'comment'])
  assert.equal(records[1].at, '2026-09-30T14:32:08Z')
  assert.equal(records[2].sha, 'abc1234567')
  assert.equal(records[3].path, 'packages/a.ts:66')
  assert.equal(records[0].body, "AFAICT it isn't worth it")
})

test('load and judge: an owed line keyed by the parent comment decides what v1 did', () => {
  writeFileSync(join(dir, 'owed.md'), owed)
  const map = loadOwed(join(dir, 'owed.md'))
  assert.equal(map.get('5913395311').reply, 'https://github.com/vikejs/vike/pull/3546#issuecomment-1')
  const row = (id, cls) => ({ cls, body: '', actual: { owed: map.get(id).line, noReply: !map.get(id).reply } })
  assert.deepEqual(judge(row('5913395311', 'question')), { actual: 'reply', planned: 'reply', verdict: 'right', unmodeled: false })
  assert.equal(judge(row('4146079944', 'instruction')).verdict, 'wrong')
})
