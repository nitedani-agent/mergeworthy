import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'briefs')

// Fills a brief template. A placeholder without a value throws: a brief never goes out with a hole in it.
export function fill(name, fields) {
  const template = readFileSync(join(DIR, `${name}.md`), 'utf8')
  return template.replace(/\{\{(\w+)\}\}/g, (_, key) => {
    if (fields[key] === undefined || fields[key] === null) throw new Error(`brief ${name}: no value for {{${key}}}`)
    return fields[key]
  })
}
