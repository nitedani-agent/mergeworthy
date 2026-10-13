// Turns the orchestrator's session log into a timeline the replay reads, one JSON row per line:
// {ts, type: 'notify' | 'user' | 'use' | 'compact', tool?, text}. 'notify' is a Monitor event (the watcher's output),
// 'user' a message the user typed, 'use' a tool call with its full input text.
// usage: node replay/extract-log.mjs <session.jsonl> <out.jsonl>
import { createReadStream, writeFileSync } from 'node:fs'
import { createInterface } from 'node:readline'

const [log, out] = process.argv.slice(2)
const rows = []
const SYSTEM = /^(<|Stop hook|Delegated task |\[Request interrupted|Caveat:|This session is being continued)/
for await (const line of createInterface({ input: createReadStream(log) })) {
  let o
  try { o = JSON.parse(line) } catch { continue }
  const ts = o.timestamp
  if (o.type === 'system' && /compact/.test(String(o.subtype ?? ''))) rows.push({ ts, type: 'compact', text: '' })
  const content = o.message?.content
  const texts = typeof content === 'string' ? [content] : Array.isArray(content) ? content.filter((b) => b?.type === 'text').map((b) => b.text) : []
  if (o.type === 'user' && !o.isMeta) {
    for (const text of texts) {
      if (/Monitor event/.test(text) && /<event>/.test(text)) rows.push({ ts, type: 'notify', text })
      else if (!SYSTEM.test(text.trim()) && !o.isCompactSummary) rows.push({ ts, type: 'user', text })
    }
  }
  if (Array.isArray(content)) {
    for (const b of content) {
      if (b?.type !== 'tool_use') continue
      const input = b.input ?? {}
      const text = b.name === 'Bash' ? input.command ?? '' : input.task ?? input.prompt ?? input.message ?? JSON.stringify(input)
      rows.push({ ts, type: 'use', tool: b.name, text })
    }
  }
}
rows.sort((a, b) => (a.ts < b.ts ? -1 : a.ts > b.ts ? 1 : 0))
writeFileSync(out, rows.map((r) => JSON.stringify(r)).join('\n') + '\n')
const count = (t) => rows.filter((r) => r.type === t).length
console.log(`${rows.length} rows: notify ${count('notify')}, user ${count('user')}, use ${count('use')}, compact ${count('compact')}`)
