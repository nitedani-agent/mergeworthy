// Prints the replay as a markdown table, one row per comment.
// usage: node replay/table.mjs <replay.json>
import { readFileSync } from 'node:fs'
import { judge } from './judge.mjs'

const rows = JSON.parse(readFileSync(process.argv[2], 'utf8'))
const min = (a, b) => (a && b ? Math.round((Date.parse(a) - Date.parse(b)) / 60e3) : '')
console.log('| # | posted (UTC) | comment | class | yielded | planner says | v1 did | verdict | v1 first touch (min) | holding saves (min) | v1 brief: notes/pin/thread/voice |')
console.log('|---|---|---|---|---|---|---|---|---|---|---|')
rows.forEach((r, i) => {
  const j = judge(r)
  const saved = r.plannerHolding && r.firstActual ? Math.max(0, min(r.firstActual, r.plannerFirst)) : ''
  const b = r.v1brief.count ? ['notes', 'pin', 'thread', 'voice'].map((k) => (r.v1brief[k] ? 'y' : 'n')).join('/') : 'no brief'
  const link = `[${r.url.replace('https://github.com/', '').replace(/\/(pull|issues)\//, '#').replace(/#(issuecomment-|discussion_r)/, ' ')}](${r.url})`
  console.log(`| ${i + 1} | ${r.at.slice(5, 16)} | ${link} ${r.author.replace('[bot]', '')}: ${r.body.slice(0, 60).replace(/[|`<>\n]/g, ' ')} | ${r.cls} | ${r.yielded} | ${j.planned} | ${j.actual} | ${j.unmodeled ? 'unmodeled' : j.verdict} | ${min(r.actual.touch, r.at)} | ${saved} | ${b} |`)
})
