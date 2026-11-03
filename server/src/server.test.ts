// End-to-end: boots the real server and checks what a per-machine token (a shared
// host like a multi-user VM) can and cannot do, over the tailnet and via the relay.
import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { spawn, type ChildProcess } from 'node:child_process'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { WebSocket } from 'ws'

const PORT = 45190 + Math.floor(Math.random() * 500)
const BASE = `http://127.0.0.1:${PORT}`
const MACHINE = 'machine-secret-1234567890'
const OPERATOR = 'operator-secret-1234567890'
const PANDA = 'panda-secret-1234567890'
const WORK = 'work-operator-secret-1234567890'
let server: ChildProcess

function call(method: string, p: string, token: string, body?: unknown, relay = false) {
  return fetch(BASE + p, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      ...(relay ? { 'x-notch-relay': '1' } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
}

const event = (machine: string, sid: string, name = 'SessionStart') => ({
  machine,
  agent: 'codex',
  event: { session_id: sid, hook_event_name: name, cwd: '/root/x' },
})
const permission = (machine: string, sid: string) => ({
  machine,
  agent: 'codex',
  event: { session_id: sid, tool_name: 'Bash', tool_input: { command: 'ls' } },
})

async function sessions() {
  const r = await call('GET', '/api/sessions', OPERATOR)
  return ((await r.json()) as { sessions: { machine: string; sessionId: string }[] }).sessions
}

function wsOpens(headers: Record<string, string> = {}, token = OPERATOR): Promise<boolean> {
  return new Promise(resolve => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws?token=${token}`, { headers })
    ws.on('open', () => (ws.close(), resolve(true)))
    ws.on('error', () => resolve(false))
  })
}

beforeAll(async () => {
  server = spawn(process.execPath, ['--import', 'tsx', 'src/index.ts'], {
    cwd: path.join(import.meta.dirname, '..'),
    env: {
      ...process.env,
      NOTCH_HOST: '127.0.0.1',
      NOTCH_PORT: String(PORT),
      NOTCH_TOKEN: MACHINE,
      NOTCH_OPERATOR_TOKEN: OPERATOR,
      NOTCH_MACHINE_TOKENS: `panda=${PANDA}`,
      NOTCH_OPERATOR_TOKENS: `mac-work=${WORK}`,
      NOTCH_DATA_DIR: mkdtempSync(path.join(tmpdir(), 'notch-e2e-')),
    },
    stdio: 'ignore',
  })
  for (let i = 0; i < 100; i++) {
    if (await fetch(`${BASE}/health`).then(r => r.ok, () => false)) return
    await new Promise(r => setTimeout(r, 100))
  }
  throw new Error('server did not start')
}, 15_000)

afterAll(() => {
  server?.kill()
})

describe('per-machine token (panda)', () => {
  it('reports only as its own machine, whatever the payload claims', async () => {
    expect((await call('POST', '/api/events', PANDA, event('mac-home', 'spoof-1'))).status).toBe(200)
    const s = (await sessions()).find(x => x.sessionId === 'spoof-1')
    expect(s?.machine).toBe('panda')
    expect((await sessions()).some(x => x.machine === 'mac-home' && x.sessionId === 'spoof-1')).toBe(false)
  })

  it('cannot see the dashboard data or decide', async () => {
    expect((await call('GET', '/api/sessions', PANDA)).status).toBe(401)
    expect((await call('GET', '/api/permissions', PANDA)).status).toBe(401)
    expect((await call('POST', '/api/permissions/x/decide', PANDA, { decision: 'allow' })).status).toBe(401)
    expect(await wsOpens({}, PANDA)).toBe(false)
  })

  it('cannot report plan usage', async () => {
    const usage = { rate_limits: { five_hour: { used_percentage: 99 } } }
    expect((await call('POST', '/api/usage', PANDA, usage)).status).toBe(403)
  })

  it("cannot wait on (or time out) another machine's permission", async () => {
    const r = await call('POST', '/api/permissions', MACHINE, permission('mac-home', 'mac-1'))
    const { id } = (await r.json()) as { id: string }
    expect((await call('GET', `/api/permissions/${id}/decision?wait=0`, PANDA)).status).toBe(404)
    const pending = (await (await call('GET', '/api/permissions', OPERATOR)).json()) as { permissions: { id: string }[] }
    expect(pending.permissions.some(p => p.id === id)).toBe(true)
  })

  it('gets the decision on its own permission', async () => {
    const r = await call('POST', '/api/permissions', PANDA, permission('mac-home', 'panda-1'))
    const { id } = (await r.json()) as { id: string }
    const wait = call('GET', `/api/permissions/${id}/decision?wait=5`, PANDA)
    expect((await call('POST', `/api/permissions/${id}/decide`, OPERATOR, { decision: 'deny' })).status).toBe(200)
    expect(await (await wait).json()).toMatchObject({ decision: 'deny' })
  })

  it('is capped on pending permissions', async () => {
    let last = 0
    for (let i = 0; i < 21; i++) last = (await call('POST', '/api/permissions', PANDA, permission('panda', `cap-${i}`))).status
    expect(last).toBe(429)
  })
})

describe('requests marked as coming through the relay', () => {
  it('accept the per-machine token', async () => {
    expect((await call('POST', '/api/events', PANDA, event('panda', 'relay-1'), true)).status).toBe(200)
  })

  it('refuse the shared machine and operator tokens', async () => {
    expect((await call('POST', '/api/events', MACHINE, event('nuc', 'relay-2'), true)).status).toBe(401)
    expect((await call('GET', '/api/sessions', OPERATOR, undefined, true)).status).toBe(401)
    expect((await call('POST', '/api/events', OPERATOR, event('nuc', 'relay-3'), true)).status).toBe(401)
  })

  it('never open the dashboard WebSocket', async () => {
    expect(await wsOpens()).toBe(true)
    expect(await wsOpens({ 'x-notch-relay': '1' })).toBe(false)
  })
})

describe('named operator token (mac-work)', () => {
  it('can view, decide and open the dashboard WebSocket on the tailnet', async () => {
    expect((await call('GET', '/api/sessions', WORK)).status).toBe(200)
    const r = await call('POST', '/api/permissions', WORK, permission('mac-work', 'work-1'))
    const { id } = (await r.json()) as { id: string }
    expect((await call('POST', `/api/permissions/${id}/decide`, WORK, { decision: 'allow' })).status).toBe(200)
    expect(await wsOpens({}, WORK)).toBe(true)
  })

  it('is refused through the relay', async () => {
    expect((await call('GET', '/api/sessions', WORK, undefined, true)).status).toBe(401)
    expect(await wsOpens({ 'x-notch-relay': '1' }, WORK)).toBe(false)
  })
})

describe('shared tokens on the tailnet are unchanged', () => {
  it('machine token still reports as the machine it names', async () => {
    expect((await call('POST', '/api/events', MACHINE, event('nuc', 'nuc-1'))).status).toBe(200)
    expect((await sessions()).find(x => x.sessionId === 'nuc-1')?.machine).toBe('nuc')
  })
})
