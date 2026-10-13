// What a GitHub comment asks of us, decided from its text and where it was posted.
// Classes: question, instruction, design, bot-finding (each needs a reply); ack, wait, merge-ask (an action, no reply);
// none (nothing owed); unclear (the orchestrator decides).
const RESOLVED = /thanks for the (fix|update|clarification)|my recommendation was incorrect|resolved|withdr[ae]w|confirm(ed|s) the fix/i
const ACK = /^(ok(ay)?|lgtm|yes|yep|sounds good|perfect|great|nice|agreed|makes sense|wonderful|that'?s good|that seems perfect|ah,? i see|good|👍|neat|cool|thanks|thank you|i think we agree)\b/i
const IMPERATIVE = /^(let'?s|please|apply|refactor|review|compare|improve|break down|reply|can you|could you|would you|document|add|remove|drop|rename|move|use|make|update|do|merge origin|merge main|rebase|change|fix|revert|define|keep|split|delete|replace|run|write|implement|create|open|close|try|check|double check|simplify|squash|mention|restore|bump|put|go back|ping)\b/i
const MERGE_ASK = /(feel free to|go ahead and|you can|please|ready to|let'?s) (squash[- ])?merge\b(?! origin| main)|^merge it\b|^squash[- ]merge\b/i
const WAIT = /^wait\b|wait until i|wait for my|i sent my reply too early|let me first|i'll (then )?circle back/i
const BADGE = /github\.com\/claude\.png|alt="(Claude|Codex)"/
const PROGRESS = /^(done in [0-9a-f]{7}|done \(re:|implemented |- \*\*[0-9a-f]{7})/i

// theirPr: the PR is the commenter's own (the planner knows which PRs are ours from the items it took).
export function classify({ body, author, isBot, ownBadge, onIssue, theirPr }) {
  const text = stripQuotes(body)
  if (ownBadge || BADGE.test(body)) return { cls: 'none', why: 'our own comment' }
  if (isBot || /\[bot\]$/.test(author)) return RESOLVED.test(text) ? { cls: 'none', why: 'the bot confirmed or withdrew its finding' } : { cls: 'bot-finding', why: 'a review bot reports a finding' }
  if (/^[0-9a-f]{7,40}$/.test(text.trim())) return { cls: 'none', why: 'a bare commit sha (a merge notice)' }
  if (/^@(?!nitedani\b)[\w-]+/.test(text)) return { cls: 'none', why: 'addressed to someone else' }
  if (PROGRESS.test(text)) return { cls: 'none', why: "someone's progress report" }
  if (theirPr) return { cls: 'none', why: "on the commenter's own PR, to their own agent" }
  if (/```suggestion/.test(body)) return { cls: 'suggestion', why: 'a code suggestion to apply' }
  if (WAIT.test(text)) return { cls: 'wait', why: 'asks us to wait' }
  if (MERGE_ASK.test(text)) return { cls: 'merge-ask', why: 'asks us to merge' }
  const first = text.trim().split('\n')[0]
  if (text.length <= 120 && ACK.test(first) && !text.includes('?')) return { cls: 'ack', why: 'acknowledges our last proposal' }
  if (onIssue && text.length > 160) return { cls: 'design', why: 'a design point in an issue thread' }
  if (text.split('\n').some((line) => IMPERATIVE.test(line.replace(/^[-*\s]+/, ''))) || /\b(let'?s|please)\b/i.test(first)) return { cls: 'instruction', why: 'asks for a change' }
  if (text.includes('?')) return onIssue ? { cls: 'design', why: 'a question in an issue thread' } : { cls: 'question', why: 'asks a question' }
  return { cls: 'unclear', why: 'neither a question nor an instruction by its wording' }
}

function stripQuotes(body) {
  return body.split('\n').filter((line) => !line.startsWith('>')).join('\n').trim() || body.trim()
}

export const NEEDS_REPLY = new Set(['question', 'instruction', 'design', 'bot-finding', 'unclear'])
