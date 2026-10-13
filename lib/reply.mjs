import { classify, NEEDS_REPLY } from './classify.mjs'

// The reply procedure (P2, with P3's debate step): given one GitHub comment and the done records of its item,
// the next step, or null when nothing more is owed. Each class has a fixed list of steps; a holding reply is
// inserted once a maintainer has waited HOLD_AFTER and the answer is not out yet.
export const HOLD_AFTER = 15 * 60e3
export const LIVE_DEADLINE = 30 * 60e3
const WAIT_DEFAULT = 30 * 60e3

const STEPS = {
  none: [],
  ack: ['ack'],
  wait: ['wait'],
  'merge-ask': ['merge'],
  suggestion: ['implement'],
  question: ['draft', 'approve'],
  instruction: ['implement', 'draft', 'approve'],
  'bot-finding': ['implement', 'draft', 'approve'],
  design: ['debate', 'draft', 'approve'],
  unclear: ['classify'],
}

export function replyClass(comment, decided) {
  return decided ? { cls: decided, why: 'decided by the orchestrator' } : classify(comment)
}

export function nextReplyStep(comment, { done, decided, now }) {
  const { cls, why } = replyClass(comment, decided)
  const at = Date.parse(comment.at)
  if (cls === 'wait') {
    const until = at + waitFor(comment.body)
    return done.has('wait') || now >= until ? null : { step: 'wait', cls, why, until }
  }
  const steps = STEPS[cls]
  const pending = steps.filter((step) => !done.has(step))
  if (!pending.length) return null
  const holding = NEEDS_REPLY.has(cls) && cls !== 'bot-finding' && !done.has('holding') && pending.includes('approve') && pending[0] !== 'approve'
  if (holding && now >= at + HOLD_AFTER) return { step: 'holding', cls, why, deadline: at + LIVE_DEADLINE, waitingOn: pending[0] }
  return { step: pending[0], cls, why, deadline: NEEDS_REPLY.has(cls) && cls !== 'bot-finding' ? at + LIVE_DEADLINE : null }
}

function waitFor(body) {
  const m = body.match(/ETA\s*(\d+)\s*(mn|min|m|h)/i)
  if (!m) return WAIT_DEFAULT
  return Number(m[1]) * (m[2].toLowerCase() === 'h' ? 3600e3 : 60e3)
}
