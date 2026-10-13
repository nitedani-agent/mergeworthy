// Replays the RSC orchestrator's history through the planner. For each maintainer comment in the log's window:
// what `mw next` would have yielded and when, against what the orchestrator did and when.
// usage: node replay/run.mjs <events.log> <replies-owed.md> <timeline.jsonl> <events.tsv> <out.json>
import { writeFileSync } from 'node:fs'
import { memoryLedger } from '../lib/ledger.mjs'
import { render } from '../lib/next.mjs'
import { commentItem, plan } from '../lib/planner.mjs'
import { HOLD_AFTER, replyClass } from '../lib/reply.mjs'
import { NEEDS_REPLY } from '../lib/classify.mjs'
import { loadEvents, loadOwed, loadTimeline } from './load.mjs'
import { readFileSync } from 'node:fs'

const [eventsFile, owedFile, timelineFile, tsvFile, out] = process.argv.slice(2)
const config = { root: '/home/nitedani/rsc-work/convergence', projects: '/home/nitedani/.mergeworthy/projects', voice: '/home/nitedani/.mergeworthy/current/voice.md' }
const events = loadEvents(eventsFile)
const owed = loadOwed(owedFile)
const timeline = loadTimeline(timelineFile)
const uses = timeline.filter((r) => r.type === 'use')
const from = timeline[0].ts
const to = timeline.at(-1).ts
const t = (iso) => Date.parse(iso)
const POST = /gh (pr|issue) comment|gh api [^|]*comments[^|]*(-f|-F|--field|--raw-field) body|mw post|gh-post|post-draft/

// What failed on a thread, from the hook blocks in events.tsv: the per-item memory the planner hands out.
const failed = readFileSync(tsvFile, 'utf8').split('\n').map((l) => l.split('\t')).filter((c) => c[1] === 'BLOCK' || c[1] === 'UBLOCK')
  .flatMap(([at, , , text]) => [...new Set([...(text ?? '').matchAll(/([\w.-]+\/[\w.-]+)(?:#|\/pull\/|\/issues\/)(\d+)/g)].map((m) => `${m[1]}#${m[2]}`))].map((thread) => ({ kind: 'failed', at, thread, text: text.replace(/^.*?(BLOCKED|Stop hook feedback: \[[^\]]*\]:?)/, '$1').slice(0, 300) })))

// PRs that are the commenter's own: a fact the live planner has from the items it took. The replay takes it from
// the owed lines that say so ("on his own PR"), which makes this one input ground truth.
const theirPrs = new Set([...owed.values()].filter((o) => /on his own PR/.test(o.line)).map((o) => o.line.match(/(\S+#\d+) (comment|review-comment)/)?.[1]))
const comments = events.filter((r) => r.kind === 'comment').map((c) => (theirPrs.has(`${c.repo}#${c.number}`) ? { ...c, theirPr: true } : c))
const inWindow = comments.filter((c) => c.at >= from && c.at <= to)
const firstUse = (pred, after) => uses.find((u) => u.ts >= after && pred(u.text))
const has = (id) => (text) => text.includes(id)

// The orchestrator's actual handling of each comment.
const actual = new Map()
for (const c of comments) {
  const o = owed.get(c.id)
  const touch = firstUse(has(c.id), c.at)
  const notify = timeline.find((r) => r.type === 'notify' && r.ts >= c.at && r.text.includes(c.id))
  const replyId = o?.reply?.match(/(?:issuecomment-|discussion_r|pullrequestreview-)(\d+)/)?.[1]
  const replyAt = replyId ? firstUse(has(replyId), c.at)?.ts : undefined
  const holdAt = firstUse((x) => x.includes(c.id) && /holding/.test(x) && /(issuecomment|discussion_r)-?\d+/.test(x), c.at)?.ts
  // Without a reply id (no owed line, or a line without the parent's id), the first post on the same thread within 12 h.
  const postAt = !replyAt ? uses.find((u) => u.ts >= c.at && u.ts <= new Date(t(c.at) + 12 * 3600e3).toISOString() && POST.test(u.text) && new RegExp(`(\\b| #|/pull/|/issues/|comments?/)${c.number}\\b`).test(u.text) && u.text.includes(c.repo.split('/')[1]))?.ts : undefined
  const noReply = o ? !o.reply : undefined
  actual.set(c.id, { owed: o, touch: touch?.ts, notify: notify?.ts, replyAt: replyAt ?? (noReply ? undefined : postAt), holdAt: holdAt && (!replyAt || holdAt < replyAt) ? holdAt : undefined, noReply })
}

// The ledger as the planner would have seen it: every event, user message and failure, and each comment's
// steps marked done when the orchestrator actually finished them (so other items queue as they really did).
const base = [...events, ...failed]
for (const r of timeline.filter((r) => r.type === 'user')) {
  base.push({ kind: 'user', at: r.ts, id: r.ts, text: r.text })
  const answered = uses.find((u) => u.ts > r.ts)
  if (answered) base.push({ kind: 'done', at: answered.ts, action: `user/${r.ts}/answer`, item: `user/${r.ts}` })
}
for (const c of comments) {
  const a = actual.get(c.id)
  const end = a.replyAt ?? (a.noReply ? a.touch : undefined)
  const item = commentItem(c)
  if (a.holdAt) base.push({ kind: 'done', at: a.holdAt, action: `${item}/holding`, item })
  if (end) for (const step of ['classify', 'ack', 'merge', 'implement', 'debate', 'draft', 'approve']) base.push({ kind: 'done', at: end, action: `${item}/${step}`, item })
}
base.sort((x, y) => t(x.at) - t(y.at))
const ledger = memoryLedger(base)

const rows = []
for (const c of inWindow) {
  const a = actual.get(c.id)
  const item = commentItem(c)
  const { cls } = replyClass(c)
  // The planner sees a comment when the watcher delivers it: the Monitor notice, else a minute after it was posted,
  // and never later than the orchestrator's own first touch.
  const plannerAt = Math.min(a.notify ? t(a.notify) : t(c.at) + 60e3, a.touch ? t(a.touch) - 1 : Infinity)
  const result = plan(ledger, plannerAt, config)
  const index = result.actions.findIndex((x) => x.item === item)
  const action = result.actions[index]
  const closed = result.closed.find((x) => x.item === item)
  const firstActual = [a.holdAt, a.replyAt].filter(Boolean).sort()[0]
  const needsReply = NEEDS_REPLY.has(cls)
  const plannerHolding = needsReply && cls !== 'bot-finding' && (!firstActual || t(firstActual) > t(c.at) + HOLD_AFTER)
  const plannerFirst = plannerHolding ? t(c.at) + HOLD_AFTER : firstActual ? t(firstActual) : undefined
  rows.push({
    item, url: c.url, author: c.author, at: c.at, body: c.body.slice(0, 160).replace(/\s+/g, ' '), cls,
    yielded: action ? action.id.split('/').pop() : closed ? 'closed' : 'none',
    queue: index, ahead: result.actions.slice(0, Math.max(index, 0)).map((x) => x.id.split('/')[0]).reduce((m, k) => ((m[k] = (m[k] ?? 0) + 1), m), {}),
    printed: action ? render({ actions: [action, ...result.actions.filter((x) => x !== action)], waits: result.waits }) : closed ? `closed: ${closed.why}` : '',
    brief: action?.brief,
    plannerAt: new Date(plannerAt).toISOString(),
    actual: { touch: a.touch, notify: a.notify, holdAt: a.holdAt, replyAt: a.replyAt, owed: a.owed?.line, noReply: a.noReply },
    v1brief: v1Brief(c, a),
    plannerHolding, plannerFirst: plannerFirst && new Date(plannerFirst).toISOString(), firstActual,
  })
}
// The briefs v1 gave subagents for this comment (drafter, reviewer, implementer): which of the four fields each named.
function v1Brief(c, a) {
  const until = a.replyAt ?? new Date(t(c.at) + 6 * 3600e3).toISOString()
  const repo = c.repo.split('/')[1]
  const briefs = uses.filter((u) => u.ts >= c.at && u.ts <= until && (/delegate_task|^Agent$|t3_thread_send/.test(u.tool) || (u.tool === 'Bash' && /cat >[^\n]*(prompt|brief)[^\n]*<<|codex exec|claude -p/.test(u.text))) && (u.text.includes(c.id) || (u.text.includes(repo) && new RegExp(`(#|/pull/|/issues/)${c.number}\\b`).test(u.text))))
  const any = (re) => briefs.some((b) => re.test(b.text))
  return {
    count: briefs.length,
    drafter: briefs.some((b) => /draft/i.test(b.text) && !/review/i.test(b.text.slice(0, 200))),
    notes: any(/\.mergeworthy\/projects\//),
    pin: any(/\b(at|head|HEAD|pinned?|sha|commit)\b[^\n]{0,30}\b[0-9a-f]{7,40}\b/),
    thread: any(/thread-context|mw thread|\.parent\.md|thread\.md|context\.md/),
    voice: any(/voice|mergeworthy:writing|skills\/writing/),
  }
}

writeFileSync(out, JSON.stringify(rows, null, 1))
console.log(`${rows.length} comments replayed (${from} to ${to})`)
