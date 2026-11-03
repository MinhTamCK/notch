import { Hono, type Context, type MiddlewareHandler } from 'hono'
import { serve } from '@hono/node-server'
import { WebSocketServer, WebSocket } from 'ws'
import type { Server } from 'node:http'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { Store, type Decision } from './state.js'
import { allowedSource, principalFor, parseMachineTokens, type Principal } from './net.js'
import { serveStatic } from '@hono/node-server/serve-static'

const PORT = Number(process.env.NOTCH_PORT ?? 4519)
// Bind address. Set to the Tailscale IP on a host with other interfaces so the
// port is not even open on LAN/public NICs (the source filter stays as 2nd layer).
const HOST = process.env.NOTCH_HOST || undefined
// Machine role: report events, open permission requests, poll own decision.
const TOKEN = process.env.NOTCH_TOKEN ?? ''
// Operator role: list sessions, open the dashboard WebSocket, decide permissions.
// Falls back to the machine token only if unset (single-token compatibility mode).
const OPERATOR_TOKEN = process.env.NOTCH_OPERATOR_TOKEN || TOKEN
// Per-machine tokens for hosts other people can log into (e.g. a shared VM): a holder
// can only report as that one machine and read its own decisions. See parseMachineTokens.
const MACHINE_TOKENS = parseMachineTokens(process.env.NOTCH_MACHINE_TOKENS ?? '', [TOKEN, OPERATOR_TOKEN])
// Set (always overwritten) by the relay connector on requests that came from the internet.
const RELAY_HEADER = 'x-notch-relay'
// Limits for per-machine tokens, so a shared host can't flood the dashboard or the disk.
const MAX_SESSIONS_PER_MACHINE = 50
const MAX_PENDING_PER_MACHINE = 20
const MAX_REQUESTS_PER_MINUTE = 300
const MAX_WAIT_SEC = 120
const MAX_BODY_BYTES = 256 * 1024

// Refuse to run with a missing or weak credential — a public default token would
// let anyone on the tailnet approve tool calls.
if (!TOKEN || TOKEN === 'dev-token' || TOKEN.length < 16) {
  console.error('[notch] refusing to start: set NOTCH_TOKEN to a strong secret (>= 16 chars)')
  process.exit(1)
}

const dataDir = process.env.NOTCH_DATA_DIR || path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'data')
const store = new Store(dataDir)

type Env = { Variables: { principal: Principal } }
const app = new Hono<Env>()

app.use('*', async (c, next) => {
  const socket = (c.env as { incoming?: { socket?: { remoteAddress?: string } } })?.incoming?.socket
  if (!allowedSource(socket?.remoteAddress)) return c.json({ error: 'forbidden' }, 403)
  await next()
})

app.get('/health', c => c.json({ ok: true }))

// Web dashboard (static shell, no data inside). Data needs the operator token via
// /api/sessions + /ws, so serving the page itself to the tailnet leaks nothing.
app.use('/dashboard/*', serveStatic({ root: './public', rewriteRequestPath: p => p.replace(/^\/dashboard/, '') }))
app.get('/dashboard', c => c.redirect('/dashboard/'))

/** Bearer-token check for a given role. Operator implies machine rights. */
function requireRole(role: 'machine' | 'operator'): MiddlewareHandler<Env> {
  return async (c, next) => {
    const tokens = { machineToken: TOKEN, operatorToken: OPERATOR_TOKEN, machineTokens: MACHINE_TOKENS }
    const viaRelay = c.req.header(RELAY_HEADER) !== undefined
    const principal = principalFor(c.req.header('authorization'), tokens, viaRelay)
    if (!principal || (role === 'operator' && principal.role !== 'operator')) {
      return c.json({ error: 'unauthorized' }, 401)
    }
    if (principal.role === 'machine' && principal.machine && !withinRate(principal.machine)) {
      return c.json({ error: 'too many requests' }, 429)
    }
    c.set('principal', principal)
    // Cap body size before any handler reads it (Content-Length + chunked fallback).
    const len = Number(c.req.header('content-length') ?? 0)
    if (len > MAX_BODY_BYTES) return c.json({ error: 'payload too large' }, 413)
    if (!c.req.header('content-length') && c.req.method !== 'GET') {
      const buf = await c.req.arrayBuffer()
      if (buf.byteLength > MAX_BODY_BYTES) return c.json({ error: 'payload too large' }, 413)
    }
    await next()
  }
}

/** The machine a per-machine token is pinned to, or undefined for the shared tokens. */
function boundMachine(c: Context<Env>): string | undefined {
  const p = c.get('principal')
  return p.role === 'machine' ? p.machine : undefined
}

const requestsThisMinute = new Map<string, { minute: number; count: number }>()
function withinRate(machine: string): boolean {
  const minute = Math.floor(Date.now() / 60_000)
  const r = requestsThisMinute.get(machine)
  if (!r || r.minute !== minute) {
    requestsThisMinute.set(machine, { minute, count: 1 })
    return true
  }
  return ++r.count <= MAX_REQUESTS_PER_MINUTE
}

/**
 * Pin a per-machine token's payload to its machine, and keep it under its caps.
 * Returns the envelope to store, or an error response.
 */
function pinned(body: unknown, machine: string | undefined, opensPermission: boolean) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { error: 'bad body' as const }
  const env = body as { machine?: unknown; event?: { session_id?: unknown } }
  if (!machine) return { env }
  const sessions = [...store.sessions.values()].filter(s => s.machine === machine)
  const known = sessions.some(s => s.sessionId === env.event?.session_id)
  if (!known && sessions.length >= MAX_SESSIONS_PER_MACHINE) return { error: 'too many sessions' as const }
  if (opensPermission) {
    const pending = [...store.permissions.values()].filter(p => p.machine === machine && !p.decision)
    if (pending.length >= MAX_PENDING_PER_MACHINE) return { error: 'too many pending permissions' as const }
  }
  return { env: { ...env, machine } }
}

app.post('/api/events', requireRole('machine'), async c => {
  const p = pinned(await c.req.json(), boundMachine(c), false)
  if ('error' in p) return c.json({ error: p.error }, p.error === 'bad body' ? 400 : 429)
  const session = store.handleEvent(p.env as never)
  if (!session) return c.json({ error: 'missing machine or session_id' }, 400)
  return c.json({ ok: true })
})

app.post('/api/permissions', requireRole('machine'), async c => {
  const p = pinned(await c.req.json(), boundMachine(c), true)
  if ('error' in p) return c.json({ error: p.error }, p.error === 'bad body' ? 400 : 429)
  const req = store.createPermission(p.env as never)
  if (!req) return c.json({ error: 'missing machine, session_id or tool_name' }, 400)
  return c.json({ id: req.id })
})

// Statusline scripts report the account's plan usage (5h/7d rate limits).
app.post('/api/usage', requireRole('machine'), async c => {
  // Plan usage is the operator's own account; a per-machine host has no say in it.
  if (boundMachine(c)) return c.json({ error: 'forbidden' }, 403)
  const body = await c.req.json<{ rate_limits?: unknown }>()
  const usage = store.setUsage(body.rate_limits)
  if (!usage) return c.json({ error: 'bad rate_limits' }, 400)
  return c.json({ ok: true })
})

app.get('/api/permissions/:id/decision', requireRole('machine'), async c => {
  const waitSec = Math.min(Number(c.req.query('wait') ?? 0), MAX_WAIT_SEC)
  // A per-machine token may only wait on its own requests (and so can't time out others').
  const machine = boundMachine(c)
  if (machine && store.permissions.get(c.req.param('id'))?.machine !== machine) {
    return c.json({ error: 'unknown permission id' }, 404)
  }
  const pending = store.waitForDecision(c.req.param('id'), waitSec * 1000)
  if (!pending) return c.json({ error: 'unknown permission id' }, 404)
  const req = await pending
  return c.json({ decision: req.decision, reason: req.reason, answers: req.answers })
})

// Operator-only: viewing all sessions and deciding requests is a dashboard right,
// not something a reporting machine should be able to do.
app.get('/api/sessions', requireRole('operator'), c => c.json({ sessions: store.snapshot().sessions }))

app.get('/api/permissions', requireRole('operator'), c => {
  const pending = [...store.permissions.values()].filter(p => !p.decision)
  return c.json({ permissions: pending })
})

/** Untrusted transport value → a clean question→label(s) map, or undefined. */
function cleanAnswers(raw: unknown): Record<string, string> | undefined {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return undefined
  const out: Record<string, string> = {}
  for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
    if (typeof v === 'string') out[k] = v
  }
  return Object.keys(out).length ? out : undefined
}

// "timeout" is a valid operator decision too: it hands the question/tool back
// to the terminal prompt instead of allowing or denying it.
const DECISIONS: Decision[] = ['allow', 'deny', 'timeout']

app.post('/api/permissions/:id/decide', requireRole('operator'), async c => {
  const body = await c.req.json<{ decision: Decision; reason?: string; answers?: unknown }>()
  if (!DECISIONS.includes(body.decision)) {
    return c.json({ error: 'decision must be "allow", "deny" or "timeout"' }, 400)
  }
  const req = store.decide(c.req.param('id'), body.decision, body.reason, cleanAnswers(body.answers))
  if (!req) return c.json({ error: 'unknown or already-decided permission id' }, 409)
  return c.json({ ok: true })
})

const server = serve({ fetch: app.fetch, port: PORT, hostname: HOST }, info => {
  console.log(`[notch] server listening on ${info.address}:${info.port}`)
}) as Server

const wss = new WebSocketServer({ noServer: true })

server.on('upgrade', (req, socket, head) => {
  if (!allowedSource(req.socket.remoteAddress)) return socket.destroy()
  const url = new URL(req.url ?? '', 'http://localhost')
  if (url.pathname !== '/ws' || req.headers[RELAY_HEADER] !== undefined) return socket.destroy()
  // The dashboard WebSocket (snapshots + decide) is operator-only.
  if (url.searchParams.get('token') !== OPERATOR_TOKEN) {
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n')
    return socket.destroy()
  }
  wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws, req))
})

wss.on('connection', ws => {
  ws.send(JSON.stringify({ type: 'snapshot', ...store.snapshot() }))
  ws.on('message', data => {
    try {
      const msg = JSON.parse(data.toString())
      if (msg.type === 'decide' && DECISIONS.includes(msg.decision)) {
        store.decide(msg.id, msg.decision, msg.reason, cleanAnswers(msg.answers))
      }
    } catch {
      // ignore malformed client messages
    }
  })
})

store.onChange(msg => {
  const json = JSON.stringify(msg)
  for (const client of wss.clients) {
    if (client.readyState === WebSocket.OPEN) client.send(json)
  }
})

setInterval(() => store.sweepStale(), 60_000)
