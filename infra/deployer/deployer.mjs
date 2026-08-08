/**
 * Receives Gitea push webhooks and runs a deploy.
 *
 * Reachable only from the `deploy` Docker network, which Gitea is attached to and
 * nothing else is. There is no published port and no tunnel hostname, so this
 * endpoint does not exist as far as the internet is concerned. The HMAC check
 * below is therefore the second lock, not the first.
 *
 * It holds the Docker socket so it can run builds in sibling containers, which is
 * root-equivalent — hence the deliberately tiny surface: one route, one method,
 * a signature check before anything is parsed as meaningful, and an allowlist of
 * sites that can be deployed.
 */

import { createServer } from 'node:http'
import { spawn } from 'node:child_process'
import { timingSafeEqual, createHmac } from 'node:crypto'

const PORT = 9000
const SECRET = process.env.WEBHOOK_SECRET ?? ''
const BRANCH = process.env.DEPLOY_BRANCH ?? 'refs/heads/main'

// Which repositories may deploy, and as which site. An allowlist rather than
// deriving the site from the payload: the payload is attacker-influenced if the
// secret ever leaks, and "deploy any name you like into the web root" is a much
// worse outcome than "deploy the wrong one of two known sites".
const SITES = {
  'MakeBelieveStudio/mbs-www': ['landing', 'status'],
  'MakeBelieveStudio/MBSWareHouse': ['warehouse'],
}

if (!SECRET) {
  console.error('deployer: WEBHOOK_SECRET is not set — refusing to start')
  process.exit(1)
}

/** Constant-time compare. A plain === leaks the signature a byte at a time. */
function signatureMatches(body, provided) {
  if (!provided) return false
  const expected = createHmac('sha256', SECRET).update(body).digest('hex')
  const a = Buffer.from(expected, 'utf8')
  const b = Buffer.from(provided, 'utf8')
  // timingSafeEqual throws on a length mismatch, which would itself be a signal.
  if (a.length !== b.length) return false
  return timingSafeEqual(a, b)
}

// One deploy at a time. Two pushes seconds apart would otherwise race on the same
// checkout directory and produce a release built from a mixture of both.
let running = false
const queue = []

function runDeploy(site, sha) {
  return new Promise((resolve) => {
    const child = spawn('/usr/local/bin/deploy.sh', [site, sha], {
      stdio: ['ignore', 'inherit', 'inherit'],
    })
    child.on('close', (code) => resolve(code === 0))
  })
}

async function drain() {
  if (running) return
  running = true
  while (queue.length > 0) {
    const { site, sha } = queue.shift()
    console.log(`deployer: ${site} -> ${sha}`)
    const ok = await runDeploy(site, sha)
    console.log(`deployer: ${site} ${ok ? 'published' : 'FAILED'}`)
  }
  running = false
}

createServer((req, res) => {
  if (req.method !== 'POST' || req.url !== '/hooks/deploy') {
    res.writeHead(404).end()
    return
  }

  const chunks = []
  let size = 0
  req.on('data', (c) => {
    size += c.length
    // A push payload is a few KB. Anything larger is not one, and buffering it
    // unbounded is how a tiny service becomes a memory exhaustion target.
    if (size > 1_000_000) {
      res.writeHead(413).end()
      req.destroy()
      return
    }
    chunks.push(c)
  })

  req.on('end', () => {
    const body = Buffer.concat(chunks)

    // Signature first, before the body is trusted enough to parse.
    if (!signatureMatches(body, req.headers['x-gitea-signature'])) {
      console.warn('deployer: rejected — bad signature')
      res.writeHead(401).end('bad signature\n')
      return
    }

    let payload
    try {
      payload = JSON.parse(body.toString('utf8'))
    } catch {
      res.writeHead(400).end('bad json\n')
      return
    }

    if (payload.ref !== BRANCH) {
      // Not an error: feature branches push too, and they should be ignored
      // quietly rather than logged as failures.
      res.writeHead(200).end(`ignored ${payload.ref}\n`)
      return
    }

    const repo = payload.repository?.full_name
    const sites = SITES[repo]
    if (!sites) {
      console.warn(`deployer: rejected — unknown repository ${repo}`)
      res.writeHead(403).end('unknown repository\n')
      return
    }

    const sha = payload.after
    if (!/^[0-9a-f]{40}$/.test(sha ?? '')) {
      // Shell-injection guard: this reaches a command line. Anything that is not
      // exactly a commit hash does not belong there.
      res.writeHead(400).end('bad sha\n')
      return
    }

    // Gitea's "Test Delivery" sends forty zeros. It passes the format check above
    // and then fails at `git reset`, which reports a FAILED deploy for what was a
    // successful test — the one message most likely to be read as a real fault.
    if (/^0{40}$/.test(sha)) {
      console.log('deployer: test delivery accepted (no commit to deploy)')
      res.writeHead(200).end('test delivery ok — signature verified, nothing to deploy\n')
      return
    }

    for (const site of sites) queue.push({ site, sha })
    // Reply immediately. Gitea times webhooks out, and a build takes far longer
    // than it will wait — a slow 200 shows up as a failed delivery.
    res.writeHead(202).end(`queued ${sites.join(', ')} @ ${sha.slice(0, 7)}\n`)
    void drain()
  })
}).listen(PORT, () => {
  console.log(`deployer: listening on ${PORT}, branch ${BRANCH}`)
  console.log(`deployer: repositories ${Object.keys(SITES).join(', ')}`)
})
