import { Hono } from 'hono'
import { serve } from '@hono/node-server'
import { WebSocketServer, WebSocket } from 'ws'
import type { Server } from 'node:http'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { Store, type Decision } from './state.js'

const PORT = Number(process.env.NOTCH_PORT ?? 4519)
const TOKEN = process.env.NOTCH_TOKEN ?? 'dev-token'
const MAX_WAIT_SEC = 120

if (TOKEN === 'dev-token') {
  console.warn('[notch] NOTCH_TOKEN not set — using insecure default "dev-token"')
}

const dataDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'data')
const store = new Store(dataDir)

const app = new Hono()

app.get('/health', c => c.json({ ok: true }))

app.use('/api/*', async (c, next) => {
  if (c.req.header('authorization') !== `Bearer ${TOKEN}`) {
    return c.json({ error: 'unauthorized' }, 401)
  }
  await next()
})

app.post('/api/events', async c => {
  const session = store.handleEvent(await c.req.json())
  if (!session) return c.json({ error: 'missing machine or session_id' }, 400)
  return c.json({ ok: true })
})

app.get('/api/sessions', c => c.json({ sessions: store.snapshot().sessions }))

app.get('/api/permissions', c => {
  const pending = [...store.permissions.values()].filter(p => !p.decision)
  return c.json({ permissions: pending })
})

app.post('/api/permissions', async c => {
  const req = store.createPermission(await c.req.json())
  if (!req) return c.json({ error: 'missing machine, session_id or tool_name' }, 400)
  return c.json({ id: req.id })
})

app.get('/api/permissions/:id/decision', async c => {
  const waitSec = Math.min(Number(c.req.query('wait') ?? 0), MAX_WAIT_SEC)
  const pending = store.waitForDecision(c.req.param('id'), waitSec * 1000)
  if (!pending) return c.json({ error: 'unknown permission id' }, 404)
  const req = await pending
  return c.json({ decision: req.decision, reason: req.reason })
})

app.post('/api/permissions/:id/decide', async c => {
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
  const url = new URL(req.url ?? '', 'http://localhost')
  if (url.pathname !== '/ws') return socket.destroy()
  if (url.searchParams.get('token') !== TOKEN) {
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
