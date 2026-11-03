// Relay connector: runs next to the fleet server and dials OUT to the relay Worker
// (relay/src/worker.js), then forwards the relay's requests to the local server.
// Hosts outside the tailnet talk to the relay only, so they never learn this
// machine's address and no port is opened here.
//
// Defense in depth: the relay already filters, but this side allowlists the same three
// machine calls and always marks them with x-notch-relay, which makes the server accept
// per-machine tokens only (never the shared machine or operator token).
//
// Env: NOTCH_RELAY_URL (https://<name>.<sub>.workers.dev), NOTCH_RELAY_SECRET,
//      NOTCH_HOST / NOTCH_PORT (where the fleet server listens).
import { WebSocket } from 'ws'

const RELAY_URL = process.env.NOTCH_RELAY_URL ?? ''
const SECRET = process.env.NOTCH_RELAY_SECRET ?? ''
const LOCAL = `http://${process.env.NOTCH_HOST || '127.0.0.1'}:${process.env.NOTCH_PORT ?? 4519}`

export const ROUTES: [string, RegExp][] = [
  ['POST', /^\/api\/events$/],
  ['POST', /^\/api\/permissions$/],
  ['GET', /^\/api\/permissions\/[0-9a-f-]{36}\/decision$/],
]

export interface RelayRequest {
  id: string
  method: string
  path: string
  wait?: number
  token: string
  body?: string
}

/** Turn a relay message into the local request to make, or undefined to refuse it. */
export function localRequest(msg: RelayRequest, base: string): { url: string; init: RequestInit } | undefined {
  if (typeof msg?.path !== 'string' || typeof msg.token !== 'string' || !msg.token) return undefined
  if (!ROUTES.some(([m, re]) => m === msg.method && re.test(msg.path))) return undefined
  const url = new URL(msg.path, base)
  if (msg.method === 'GET' && Number.isFinite(msg.wait)) {
    url.searchParams.set('wait', String(Math.min(Math.max(Math.floor(msg.wait as number), 0), 60)))
  }
  return {
    url: url.toString(),
    init: {
      method: msg.method,
      headers: { authorization: `Bearer ${msg.token}`, 'content-type': 'application/json', 'x-notch-relay': '1' },
      body: msg.method === 'POST' ? (msg.body ?? '') : undefined,
    },
  }
}

async function answer(msg: RelayRequest): Promise<{ status: number; body: string }> {
  const req = localRequest(msg, LOCAL)
  if (!req) return { status: 404, body: '{"error":"not found"}' }
  try {
    const res = await fetch(req.url, req.init)
    return { status: res.status, body: await res.text() }
  } catch {
    return { status: 502, body: '{"error":"server unreachable"}' }
  }
}

function connect(attempt = 0) {
  const url = RELAY_URL.replace(/^http/, 'ws').replace(/\/$/, '') + '/connect'
  const ws = new WebSocket(url, { headers: { authorization: `Bearer ${SECRET}` } })
  let ping: NodeJS.Timeout | undefined
  let lastPong = Date.now()
  ws.on('open', () => {
    attempt = 0
    console.log('[relay] connected')
    // The relay answers "ping" with "pong". A home connection behind NAT can die
    // without a close, so a socket that stops answering is dropped and redialed.
    ping = setInterval(() => {
      if (Date.now() - lastPong > 75_000) return ws.terminate()
      ws.send('ping')
    }, 30_000)
  })
  ws.on('message', async data => {
    if (data.toString() === 'pong') return void (lastPong = Date.now())
    let msg: RelayRequest
    try {
      msg = JSON.parse(data.toString())
    } catch {
      return
    }
    if (typeof msg?.id !== 'string') return
    const { status, body } = await answer(msg)
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ id: msg.id, status, body }))
  })
  ws.on('error', err => console.error(`[relay] ${err.message}`))
  ws.on('close', () => {
    clearInterval(ping)
    const delay = Math.min(30, 2 ** attempt)
    console.log(`[relay] disconnected, retrying in ${delay}s`)
    setTimeout(() => connect(attempt + 1), delay * 1000)
  })
}

if (process.argv[1]?.endsWith('connector.ts')) {
  const local = /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?\/?$/.test(RELAY_URL) // wrangler dev only
  if (!(RELAY_URL.startsWith('https://') || local) || SECRET.length < 32) {
    console.error('[relay] refusing to start: set NOTCH_RELAY_URL (https) and NOTCH_RELAY_SECRET (>= 32 chars)')
    process.exit(1)
  }
  connect()
}
