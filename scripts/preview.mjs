#!/usr/bin/env node
/**
 * Serve the built sites locally so both pages can be looked at before deploying.
 *
 *   npm run preview           landing on :4180, status on :4181
 *   npm run preview:status    same, but with a fake /api/status.json so the
 *                             status page has something to render
 *
 * Two ports rather than one server with path prefixes, because the pages use
 * absolute paths (`/tokens.css`) exactly as nginx will serve them. Previewing
 * them under a subpath would work here and then break in production, which is the
 * kind of difference a preview is supposed to catch rather than create.
 *
 * MOCK_STATUS exists because /api/status.json is written by the collector on the
 * server and does not exist locally. Without it the status page correctly shows
 * "cannot reach the collector" — right, but not much to look at.
 */

import { createServer } from 'node:http'
import { existsSync, readFileSync, statSync } from 'node:fs'
import { dirname, extname, join, normalize, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
}

// Shaped exactly like what infra/collector/collect.sh writes, so the page is
// exercised against the real contract rather than a convenient one.
const MOCK = {
  checked_at: new Date().toISOString(),
  services: [
    { name: 'Database', state: 'up' },
    { name: 'API', state: 'up' },
    { name: 'Auth', state: 'up' },
    { name: 'Storage', state: 'up' },
    { name: 'Realtime', state: 'up' },
    { name: 'Git', state: 'down' },
  ],
}

// Shaped exactly like infra/collector writes to /detail/api/detail.json. Values
// are plausible rather than flattering — the disk is deliberately past the 75%
// warn band so the meter styling is actually exercised.
const MOCK_DETAIL = {
  checked_at: new Date().toISOString(),
  host: {
    cpu_pct: 12,
    mem_used_gb: 9.1,
    mem_total_gb: 30.6,
    mem_pct: 30,
    disk_used_gb: 361,
    disk_total_gb: 457,
    disk_pct: 79,
    load1: 0.42,
    uptime: '29h',
  },
  containers: [
    { name: 'Database', state: 'up', uptime: '29h', restarts: 0, image: 'supabase/postgres:17.6.1.136' },
    { name: 'API', state: 'up', uptime: '29h', restarts: 0, image: 'kong/kong:3.9.3' },
    { name: 'Auth', state: 'up', uptime: '29h', restarts: 0, image: 'supabase/gotrue:v2.189.0' },
    { name: 'Storage', state: 'up', uptime: '29h', restarts: 1, image: 'supabase/storage-api:v1.60.4' },
    { name: 'Realtime', state: 'up', uptime: '29h', restarts: 0, image: 'supabase/realtime:v2.102.3' },
    { name: 'Git', state: 'down', uptime: '—', restarts: 3, image: 'gitea/gitea:1.24' },
    { name: 'Web', state: 'up', uptime: '2h', restarts: 0, image: 'nginx:alpine' },
  ],
  deploys: [
    { site: 'landing', ref: 'b293ac5', at: new Date(Date.now() - 3600e3).toISOString() },
    { site: 'status', ref: 'b293ac5', at: new Date(Date.now() - 3600e3).toISOString() },
    { site: 'warehouse', ref: '5e20be4', at: new Date(Date.now() - 86400e3).toISOString() },
  ],
}

function serve(site, port) {
  const docroot = join(root, 'dist', site)

  createServer((req, res) => {
    const url = new URL(req.url, `http://localhost:${port}`)

    if (process.env.MOCK_STATUS === '1' && url.pathname === '/api/status.json') {
      res.writeHead(200, { 'Content-Type': TYPES['.json'], 'Cache-Control': 'no-store' })
      res.end(JSON.stringify({ ...MOCK, checked_at: new Date().toISOString() }))
      return
    }

    // In production this path is behind Cloudflare Access. Locally there is no
    // gate, which is exactly why the detail data lives under /detail/ — one policy
    // covers the page and the JSON together.
    if (process.env.MOCK_STATUS === '1' && url.pathname === '/detail/api/detail.json') {
      res.writeHead(200, { 'Content-Type': TYPES['.json'], 'Cache-Control': 'no-store' })
      res.end(JSON.stringify({ ...MOCK_DETAIL, checked_at: new Date().toISOString() }))
      return
    }

    // normalize + prefix check: without it `..%2f..%2fetc/passwd` escapes docroot.
    // This only ever runs on a developer's machine, but a traversal bug is not
    // worth writing on purpose.
    const rel = normalize(decodeURIComponent(url.pathname)).replace(/^(\.\.[/\\])+/, '')
    let file = join(docroot, rel)
    if (!file.startsWith(docroot)) {
      res.writeHead(403).end('forbidden')
      return
    }
    if (existsSync(file) && statSync(file).isDirectory()) file = join(file, 'index.html')
    if (!existsSync(file)) {
      res.writeHead(404, { 'Content-Type': TYPES['.html'] })
      res.end('<h1>404</h1>')
      return
    }

    res.writeHead(200, {
      'Content-Type': TYPES[extname(file)] ?? 'application/octet-stream',
      'Cache-Control': 'no-store',
    })
    res.end(readFileSync(file))
  }).listen(port, () => {
    console.log(`  ${site.padEnd(8)} http://localhost:${port}`)
  })
}

console.log('preview:')
serve('landing', 4180)
serve('status', 4181)
if (process.env.MOCK_STATUS !== '1') {
  console.log('\n  status will report "cannot reach the collector" — that is correct here.')
  console.log('  Use `npm run preview:status` to serve mock data instead.')
}
