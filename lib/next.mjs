// The text `mw next` prints: the one action due now, why, what to do, and the item's memory. Under 300 words.
export function render({ actions, waits }, item) {
  const action = item ? actions.find((a) => a.item === item) : actions[0]
  if (!action) {
    const wake = waits.map((w) => w.until).sort((a, b) => a - b)[0]
    return wake ? `nothing due; next: ${waits[0].who} until ${new Date(wake).toISOString()}` : 'nothing due'
  }
  const lines = [`id: ${action.id}`, `why: ${action.why}`, `do: ${action.do}`]
  if (action.deadline) lines.push(`by: ${new Date(action.deadline).toISOString()}`)
  if (action.holdingText) lines.push(`holding reply: ${action.holdingText.trim()}`)
  lines.push('memory:', ...(action.memory?.length ? action.memory.map((m) => `  ${m}`) : ['  none recorded']))
  if (actions.length > 1) lines.push(`also due: ${actions.length - 1} (next: ${actions[1].id})`)
  return lines.join('\n')
}
