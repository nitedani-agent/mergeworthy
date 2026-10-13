import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { fill } from './briefs.mjs'
import { nextReplyStep } from './reply.mjs'

// The one priority order: the user's message, red CI on our PR, a maintainer's comment, the critical path, side work.
export const PRIORITY = { user: 1, ci: 2, comment: 3, critical: 4, side: 5 }

// All actions due now across every item, highest priority first. `config` names the paths briefs are filled with.
export function plan(ledger, now, config) {
  const records = ledger.records().filter((r) => Date.parse(r.at) <= now)
  const done = doneByItem(records)
  const actions = []
  const waits = []
  const closed = []
  for (const r of records) {
    if (r.kind === 'user' && !done.get(`user/${r.id}`)?.has('answer')) {
      actions.push({ id: `user/${r.id}/answer`, item: `user/${r.id}`, priority: PRIORITY.user, at: r.at, why: 'the user wrote', do: `answer the user: ${clip(r.text, 160)}` })
    }
    if (r.kind === 'take') {
      const key = `take/${r.id}`
      if (!done.get(key)?.has('work')) actions.push({ id: `${key}/work`, item: key, priority: PRIORITY[r.lane ?? 'side'], at: r.at, why: 'a task you took', do: `work on: ${clip(r.text, 160)} (no generator models free tasks yet)` })
    }
  }
  for (const [thread, ci] of latestCi(records)) {
    const item = `ci/${thread}@${ci.at}`
    if (ci.red && !done.get(item)?.has('fix')) {
      actions.push({ id: `${item}/fix`, item, priority: PRIORITY.ci, at: ci.at, why: `CI is red on ${thread}: ${ci.checks ?? ''}`, do: `delegate a CI fix on ${thread}: fix it, or say on the PR why it is not this PR's doing` })
    }
  }
  for (const c of records.filter((r) => r.kind === 'comment')) {
    const item = commentItem(c)
    const itemDone = done.get(item) ?? new Set()
    const decided = records.findLast((r) => r.kind === 'class' && r.item === item)?.cls
    const step = nextReplyStep(c, { done: itemDone, decided, now })
    if (!step) {
      if (!itemDone.size) closed.push({ item, why: decided ?? 'nothing owed' })
      continue
    }
    if (step.step === 'wait') {
      waits.push({ item, until: step.until, who: c.author })
      continue
    }
    actions.push(commentAction(c, item, step, records, config, now))
  }
  actions.sort((a, b) => a.priority - b.priority || (a.deadline ?? Infinity) - (b.deadline ?? Infinity) || Date.parse(a.at) - Date.parse(b.at))
  return { actions, waits, closed }
}

export function commentItem(c) {
  return `${c.repo}#${c.number}/${c.id}`
}

function commentAction(c, item, step, records, config, now) {
  const thread = `${c.repo}#${c.number}`
  const base = { id: `${item}/${step.step}`, item, priority: PRIORITY.comment, at: c.at, deadline: step.deadline ?? undefined, why: `${c.author} on ${thread} (${step.cls}: ${step.why})` }
  const memory = itemMemory(records, thread, item)
  const fields = briefFields(c, item, records, config, memory)
  switch (step.step) {
    case 'classify':
      return { ...base, do: `decide: what does ${c.url} ask? mw done ${base.id} --class question|instruction|design|ack|none`, memory }
    case 'ack':
      return { ...base, do: `react 👍 to ${c.url}; if the proposal it acknowledges changes code, mw take it`, memory }
    case 'merge':
      return { ...base, do: `approve: merge ${thread} as asked in ${c.url} (the merge gate checks the asked-for merge method)`, memory }
    case 'holding': {
      const text = fill('holding', { waiting_on: WAITING[step.waitingOn], eta: eta(step.waitingOn, now) })
      return { ...base, do: `approve the holding reply ${fields.holding_path} on ${c.url}; mw done posts it`, memory, holdingText: text, files: { [fields.holding_path]: text } }
    }
    case 'debate':
      return withBrief({ ...base, do: `delegate the debater: ${fields.brief_path}`, memory }, fields, fill('debater', fields))
    case 'implement':
      return withBrief({ ...base, do: `delegate an implementer: ${fields.brief_path} (its charter is not in the prototype)`, memory }, fields, fill('implementer', fields))
    case 'draft':
      return withBrief({ ...base, do: `delegate the drafter: ${fields.brief_path}`, memory }, fields, fill('drafter', { ...fields, kind: step.cls }))
    case 'approve':
      return { ...base, do: `read and approve ${fields.draft_path}; mw done posts it through the posting checks`, memory }
  }
  throw new Error(`no action for step ${step.step}`)
}

function withBrief(action, fields, brief) {
  return { ...action, brief, files: { [fields.brief_path]: brief } }
}

// The item's memory delivered with its action: what failed and what was ruled out on this thread.
function itemMemory(records, thread, item) {
  return records
    .filter((r) => (r.kind === 'failed' || r.kind === 'ruled-out' || (r.kind === 'done' && r.no)) && (r.thread === thread || r.item === item))
    .slice(-5)
    .map((r) => `${r.kind === 'done' ? 'rejected' : r.kind} ${r.at.slice(0, 16)}: ${clip(r.text ?? r.no, 200)}`)
}

function briefFields(c, item, records, config, memory) {
  const [owner, repo] = c.repo.split('/')
  const slug = item.replace(/[^a-zA-Z0-9]+/g, '-')
  const dir = join(config.root, 'items', slug)
  const head = records.findLast((r) => r.kind === 'head' && r.repo === c.repo && r.number === c.number)?.sha
  const notes = join(config.projects, owner, `${repo}.md`)
  const results = records.filter((r) => r.kind === 'done' && r.item === item && r.result).map((r) => `- ${r.action.split('/').pop()}: ${r.result}`)
  return {
    comment_url: c.url,
    author: c.author,
    thread: `${c.repo}#${c.number}`,
    thread_url: c.url.replace(/[#?].*$/, ''),
    comment_id: String(c.id),
    thread_record: join(dir, 'thread.md'),
    notes_path: existsSync(notes) ? notes : `${notes} (missing: the repo study is owed; say so in your report)`,
    head: head ? `${head} (the PR head when the comment arrived; re-check with \`git ls-remote\` before citing code)` : `the default branch of ${c.repo}, fetched now; name the sha you read`,
    voice_path: config.voice,
    draft_path: join(dir, 'reply.md'),
    holding_path: join(dir, 'holding.md'),
    brief_path: join(dir, 'brief.md'),
    debate_path: join(dir, 'debate.md'),
    memory: memory.length ? memory.map((m) => `- ${m}`).join('\n') : '- none recorded',
    results: results.length ? results.join('\n') : '- none yet',
    kind: '',
  }
}

// What a holding reply says is running, and a typical time for it (a prototype guess, not measured).
const WAITING = { implement: 'the change you asked for', debate: 'a check of the design options against the thread', draft: 'the answer', classify: 'the answer' }
const TYPICAL = { implement: 120, debate: 60, draft: 30, classify: 30 }
function eta(step, now) {
  return new Date(now + TYPICAL[step] * 60e3).toISOString().slice(11, 16) + ' UTC'
}

function doneByItem(records) {
  const map = new Map()
  for (const r of records) {
    if (r.kind !== 'done' || r.no) continue
    const step = r.action.split('/').pop()
    if (!map.has(r.item)) map.set(r.item, new Set())
    map.get(r.item).add(step)
  }
  return map
}

function latestCi(records) {
  const map = new Map()
  for (const r of records) if (r.kind === 'ci') map.set(`${r.repo}#${r.number}`, r)
  return map
}

function clip(text, n) {
  const one = String(text).replace(/\s+/g, ' ').trim()
  return one.length > n ? one.slice(0, n - 1) + '…' : one
}
