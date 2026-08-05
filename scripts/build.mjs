#!/usr/bin/env node
/**
 * Build = copy. There is no bundler here on purpose.
 *
 * Two static pages do not justify a toolchain, and without one the deploy has no
 * step that can fail halfway and leave a broken site: the output is assembled in
 * full, then swapped into place atomically by the deploy script.
 *
 * Each site gets its own directory with `shared/` flattened into its root, so the
 * pages can reference `/tokens.css` and `/logo-landing.png` at absolute paths and
 * nginx can serve each site from its own docroot with no rewriting.
 *
 *   dist/landing/   index.html + shared
 *   dist/status/    index.html + status.css + status.js + shared
 *
 * `npm run build` is the same entry point the Repair Desk uses, so the deploy
 * script on the server needs no per-site special casing.
 */

import { cpSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const DIST = join(root, 'dist')

const SITES = ['landing', 'status']

rmSync(DIST, { recursive: true, force: true })

for (const site of SITES) {
  const out = join(DIST, site)
  mkdirSync(out, { recursive: true })

  // shared/ first, flattened — tokens.css, base.css, theme.js, fonts/, logos.
  cpSync(join(root, 'shared'), out, { recursive: true })
  // then the site's own files, which may legitimately override a shared one.
  cpSync(join(root, site), out, { recursive: true })
}

// A build stamp the deploy script can point at to confirm which release is live.
// COMMIT_REF is set by the deployer; 'local' when someone runs this by hand, the
// same convention as the Repair Desk's vite config.
const ref = (process.env.COMMIT_REF ?? '').slice(0, 7) || 'local'
for (const site of SITES) {
  writeFileSync(join(DIST, site, 'build.txt'), `${ref}\n`)
}

console.log(`build: wrote ${SITES.map((s) => `dist/${s}`).join(', ')} (build ${ref})`)
