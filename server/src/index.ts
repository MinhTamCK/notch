import { Hono } from 'hono'
import { serve } from '@hono/node-server'
import { WebSocketServer, WebSocket } from 'ws'
import type { Server } from 'node:http'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { Store, type Decision } from './state.js'
import { allowedSource, authorizeRole } from './net.js'

const PORT = Number(process.env.NOTCH_PORT ?? 4519)
// Machine role: report events, open permission requests, poll own decision.
const TOKEN = process.env.NOTCH_TOKEN ?? ''
// Operator role: list sessions, open the dashboard WebSocket, decide permissions.
// Falls back to the machine token only if unset (single-token compatibility mode).
const OPERATOR_TOKEN = process.env.NOTCH_OPERATOR_TOKEN || TOKEN
const MAX_WAIT_SEC = 120
const MAX_BODY_BYTES = 256 * 1024

// Refuse to run with a missing or weak credential — a public default token would
// let anyone on the tailnet approve tool calls.
if (!TOKEN || TOKEN === 'dev-token' || TOKEN.length < 16) {
  console.error('[notch] refusing to start: set NOTCH_TOKEN to a strong secret (>= 16 chars)')
  process.exit(1)
}

const dataDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'data')
const store = new Store(dataDir)

const app = new Hono()

app.use('*', async (c, next) => {
  const socket = (c.env as { incoming?: { socket?: { remoteAddress?: string } } })?.incoming?.socket
  if (!allowedSource(socket?.remoteAddress)) return c.json({ error: 'forbidden' }, 403)
  await next()
})

app.get('/health', c => c.json({ ok: true }))

/** Bearer-token check for a given role. Operator implies machine rights. */
function requireRole(role: 'machine' | 'operator') {
  return async (c: Parameters<Parameters<typeof app.use>[1]>[0], next: () => Promise<void>) => {
    const tokens = { machineToken: TOKEN, operatorToken: OPERATOR_TOKEN }
    if (!authorizeRole(c.req.header('authorization'), role, tokens)) {
      return c.json({ error: 'unauthorized' }, 401)
    }
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

app.post('/api/events', requireRole('machine'), async c => {
  const session = store.handleEvent(await c.req.json())
  if (!session) return c.json({ error: 'missing machine or session_id' }, 400)
  return c.json({ ok: true })
})

app.post('/api/permissions', requireRole('machine'), async c => {
  const req = store.createPermission(await c.req.json())
  if (!req) return c.json({ error: 'missing machine, session_id or tool_name' }, 400)
  return c.json({ id: req.id })
})

app.get('/api/permissions/:id/decision', requireRole('machine'), async c => {
  const waitSec = Math.min(Number(c.req.query('wait') ?? 0), MAX_WAIT_SEC)
  const pending = store.waitForDecision(c.req.param('id'), waitSec * 1000)
  if (!pending) return c.json({ error: 'unknown permission id' }, 404)
  const req = await pending
  return c.json({ decision: req.decision, reason: req.reason })
})

// Operator-only: viewing all sessions and deciding requests is a dashboard right,
// not something a reporting machine should be able to do.
app.get('/api/sessions', requireRole('operator'), c => c.json({ sessions: store.snapshot().sessions }))

app.get('/api/permissions', requireRole('operator'), c => {
  const pending = [...store.permissions.values()].filter(p => !p.decision)
  return c.json({ permissions: pending })
})

app.post('/api/permissions/:id/decide', requireRole('operator'), async c => {
  const body = await c.req.json<{ decision: Decision; reason?: string }>()
  if (body.decision !== 'allow' && body.decision !== 'deny') {
    return c.json({ error: 'decision must be "allow" or "deny"' }, 400)
  }
  const req = store.decide(c.req.param('id'), body.decision, body.reason)
  if (!req) return c.json({ error: 'unknown or already-decided permission id' }, 409)
  return c.json({ ok: true })
})

const server = serve({ fetch: app.fetch, port: PORT }, info => {
  console.log(`[notch] server listening on :${info.port}`)
}) as Server

const wss = new WebSocketServer({ noServer: true })

server.on('upgrade', (req, socket, head) => {
  if (!allowedSource(req.socket.remoteAddress)) return socket.destroy()
  const url = new URL(req.url ?? '', 'http://localhost')
  if (url.pathname !== '/ws') return socket.destroy()
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
      if (msg.type === 'decide' && (msg.decision === 'allow' || msg.decision === 'deny')) {
        store.decide(msg.id, msg.decision, msg.reason)
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
