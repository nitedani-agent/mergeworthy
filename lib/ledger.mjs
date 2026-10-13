import { appendFileSync, mkdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

// One append-only ledger per root: every event, take, done and memory record, one JSON object per line.
export function openLedger(root) {
  mkdirSync(root, { recursive: true })
  const file = join(root, 'ledger.jsonl')
  let cache = null
  return {
    file,
    append(record) {
      appendFileSync(file, JSON.stringify(record) + '\n')
      cache?.push(record)
    },
    records() {
      if (!cache) {
        try {
          cache = readFileSync(file, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line))
        } catch {
          cache = []
        }
      }
      return cache
    },
  }
}

// An in-memory ledger with the same interface, for the replay and the tests.
export function memoryLedger(records = []) {
  return { file: null, append: (record) => records.push(record), records: () => records }
}
