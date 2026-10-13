import { readFileSync } from 'node:fs'

// The watcher's events.log as records the planner reads. Comment headers carry their GitHub time; CI and PR CHANGED
// lines have none, so they take the time of the comment before them in the log (a lower bound).
export function loadEvents(file) {
  const text = readFileSync(file, 'utf8')
  const records = []
  let last = null
  const blocks = text.split(/\n(?=### |WATCH ERROR)/)
  for (const block of blocks) {
    const [head, ...rest] = block.split('\n')
    const body = rest.join('\n').trim()
    let m
    if ((m = head.match(/^### (\S+)#(\d+) (comment|review-comment|review) (\d+) by (\S+) (\S+Z) (\S*) ?(https:\S+)/))) {
      last = m[6]
      records.push({ kind: 'comment', at: m[6], repo: m[1], number: Number(m[2]), type: m[3], id: m[4], author: m[5], path: m[7] || undefined, url: m[8], body, onIssue: m[8].includes('/issues/') })
    } else if ((m = head.match(/^### CI (\S+)#(\d+): (red=.*|no longer red)/)) && last) {
      records.push({ kind: 'ci', at: last, repo: m[1], number: Number(m[2]), red: m[3].startsWith('red'), checks: m[3] })
    } else if ((m = head.match(/^### PR CHANGED (\S+)#(\d+): .*-> \{'head': '([0-9a-f]+)'/)) && last) {
      records.push({ kind: 'head', at: last, repo: m[1], number: Number(m[2]), sha: m[3] })
    }
  }
  return records
}

// replies-owed.md: one line per comment that owed a reply, keyed by the comment's id.
export function loadOwed(file) {
  const map = new Map()
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    const m = line.match(/(\S+)#(\d+) (comment|review-comment|review|wait-ping) (\d+) by/)
    if (!m) continue
    const status = line.match(/^(done|holding|drafting|owed):/)?.[1] ?? 'owed'
    const reply = line.match(/^(?:done|holding|drafting): (https:\S+)/)?.[1]
    map.set(m[4], { status, note: line.slice(0, line.indexOf(m[0])), reply, line })
  }
  return map
}

export function loadTimeline(file) {
  return readFileSync(file, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line))
}
