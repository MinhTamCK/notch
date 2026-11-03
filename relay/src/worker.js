// notch relay: lets a host outside the tailnet (e.g. a shared VM) report to the fleet
// server without learning where it lives. The host talks only to this Worker; the
// server's side dials out to it (relay/connector) — nobody opens a port at home.
//
// Only the three "machine" calls pass, and only with a per-machine token. No dashboard,
// no WebSocket for viewers, no deciding: those never leave the tailnet.
//
// Secrets (wrangler secret put):
//   CONNECTOR_SECRET      the connector's credential for /connect
//   MACHINE_TOKEN_HASHES  comma-separated sha256 hex of the per-machine tokens allowed through

const ROUTES = [
  ['POST', /^\/api\/events$/],
  ['POST', /^\/api\/permissions$/],
  ['GET', /^\/api\/permissions\/[0-9a-f-]{36}\/decision$/],
]
const MAX_BODY_BYTES = 256 * 1024

const json = (status, body) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

async function sha256Hex(text) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, '0')).join('')
}

/** Constant-time compare of two secrets, via their hashes so lengths match. */
async function sameSecret(a, b) {
  if (!a || !b) return false
  const [x, y] = await Promise.all([sha256Hex(a), sha256Hex(b)])
  let diff = 0
  for (let i = 0; i < x.length; i++) diff |= x.charCodeAt(i) ^ y.charCodeAt(i)
  return diff === 0
}

function bearer(request) {
  const h = request.headers.get('authorization') ?? ''
  return h.startsWith('Bearer ') ? h.slice(7) : ''
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url)
    const hub = env.HUB.get(env.HUB.idFromName('hub'))

    if (url.pathname === '/connect') {
      if (request.headers.get('upgrade') !== 'websocket') return json(426, { error: 'websocket only' })
      if (!(await sameSecret(bearer(request), env.CONNECTOR_SECRET))) return json(401, { error: 'unauthorized' })
      return hub.fetch(request)
    }

    if (!ROUTES.some(([m, re]) => m === request.method && re.test(url.pathname))) {
      return json(404, { error: 'not found' })
    }
    // Early filter only; the fleet server checks the token again and pins the machine.
    const allowed = (env.MACHINE_TOKEN_HASHES ?? '').split(',').map(s => s.trim()).filter(Boolean)
    const token = bearer(request)
    if (!token || !allowed.includes(await sha256Hex(token))) return json(401, { error: 'unauthorized' })

    const body = request.method === 'POST' ? await request.text() : undefined
    if (body && body.length > MAX_BODY_BYTES) return json(413, { error: 'payload too large' })
    const wait = url.searchParams.get('wait')
    return hub.fetch('https://hub/forward', {
      method: 'POST',
      body: JSON.stringify({
        method: request.method,
        path: url.pathname,
        wait: wait === null ? undefined : Number(wait),
        token,
        body,
      }),
    })
  },
}

/** Holds the connector's socket and pairs each forwarded request with its answer. */
export class Hub {
  constructor(ctx) {
    this.ctx = ctx
    this.pending = new Map() // id → resolve
    // Keepalive pings are answered without waking the object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'))
  }

  async fetch(request) {
    if (request.headers.get('upgrade') === 'websocket') {
      // One connector at a time: a new one replaces the old.
      for (const old of this.ctx.getWebSockets()) old.close(1000, 'replaced')
      const [client, server] = Object.values(new WebSocketPair())
      this.ctx.acceptWebSocket(server)
      return new Response(null, { status: 101, webSocket: client })
    }

    const [socket] = this.ctx.getWebSockets()
    if (!socket) return json(503, { error: 'server offline' })
    const req = await request.json()
    const id = crypto.randomUUID()
    // The decision long-poll may hold for up to `wait` seconds on the server.
    const timeoutMs = (Math.min(Math.max(req.wait ?? 0, 0), 60) + 15) * 1000
    const answer = new Promise(resolve => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        resolve({ status: 504, body: JSON.stringify({ error: 'server timeout' }) })
      }, timeoutMs)
      this.pending.set(id, r => (clearTimeout(timer), resolve(r)))
    })
    socket.send(JSON.stringify({ id, ...req }))
    const { status, body } = await answer
    return new Response(body ?? '', { status, headers: { 'content-type': 'application/json' } })
  }

  webSocketMessage(_ws, message) {
    let msg
    try {
      msg = JSON.parse(typeof message === 'string' ? message : new TextDecoder().decode(message))
    } catch {
      return
    }
    const resolve = this.pending.get(msg.id)
    if (!resolve) return
    this.pending.delete(msg.id)
    resolve({ status: Number(msg.status) || 502, body: typeof msg.body === 'string' ? msg.body : '' })
  }

  webSocketClose() {
    for (const [id, resolve] of this.pending) {
      this.pending.delete(id)
      resolve({ status: 502, body: JSON.stringify({ error: 'server disconnected' }) })
    }
  }
}
