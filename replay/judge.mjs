// Scores a replay: per comment, the planner's action against the orchestrator's, and the counts.
// usage: node replay/judge.mjs <replay.json> [--split <iso>]
import { readFileSync } from 'node:fs'

const POSTED = /Done in|fixed in|\([0-9a-f]{7}\)|\bin [0-9a-f]{7}\b|pushed|implementer|applied|moved|renamed|removed|dropped|rewr|refactor/i
const FOLDED = /answered in|reply waits|in progress|goes out with|no reply yet/i
const UNMODELED = /gist|pre-release|PROMISED|proposals-open|new PR|opened #|PR body|body row|merged|mergeworthy commits|final review|review round|convergence|LOC|harness|Done in #\d+/i

export function judge(row) {
  const owed = row.actual.owed ?? ''
  const note = owed.split(' — ')[0]
  let actual
  if (!owed) actual = row.actual.replyAt ? 'reply (no owed line)' : row.actual.touch ? 'touched, no record' : 'nothing'
  else if (row.actual.noReply) actual = FOLDED.test(note) ? 'reply (folded)' : 'no reply'
  else actual = POSTED.test(note) ? 'change + reply' : 'reply'
  const planned = { question: 'reply', design: 'debate + reply', instruction: 'change + reply', 'bot-finding': 'change + reply', unclear: 'decide', ack: 'no reply (ack)', none: 'no reply', wait: 'no reply (wait)', 'merge-ask': 'merge', suggestion: 'change, no reply' }[row.cls]
  const wantsReply = /^(reply|change)/.test(actual)
  const plansReply = /reply$/.test(planned) && !/^no/.test(planned)
  let verdict
  if (planned === 'decide') verdict = 'decide'
  else if (planned === 'no reply (wait)' && actual === 'reply (folded)') verdict = 'right'
  else if (actual === 'nothing' || actual === 'touched, no record') verdict = plansReply ? 'v1 posted nothing' : 'right'
  else if (plansReply !== wantsReply) verdict = 'wrong'
  else if (plansReply && owed && (planned === 'change + reply') !== (actual === 'change + reply') && row.cls !== 'design') verdict = 'wrong step'
  else verdict = 'right'
  const unmodeled = UNMODELED.test(note) || /^(Mergeworthy change|Harness:)/i.test(row.body)
  return { actual, planned, verdict, unmodeled }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const rows = JSON.parse(readFileSync(process.argv[2], 'utf8'))
  const split = process.argv.includes('--split') ? process.argv[process.argv.indexOf('--split') + 1] : null
  for (const [name, part] of split ? [['before', rows.filter((r) => r.at < split)], ['after', rows.filter((r) => r.at >= split)]] : [['all', rows]]) {
    const counts = {}
    for (const r of part) {
      const j = judge(r)
      const key = j.unmodeled ? 'unmodeled' : j.verdict
      counts[key] = (counts[key] ?? 0) + 1
    }
    console.log(name, part.length, JSON.stringify(counts))
  }
}
