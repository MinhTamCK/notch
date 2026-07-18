import { appendFile } from 'node:fs/promises'
import { mkdirSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import path from 'node:path'

export type SessionState =
  | 'working'
  | 'needs_permission'
  | 'needs_attention'
  | 'done'
  | 'ended'
  | 'stale'

export interface Session {
  key: string
  machine: string
  sessionId: string
  agent: string
  cwd?: string
  state: SessionState
  lastTool?: string
  lastMessage?: string
  startedAt: number
  updatedAt: number
  pendingPermissionIds: string[]
}

export type Decision = 'allow' | 'deny' | 'timeout'

export interface PermissionRequest {
  id: string
  machine: string
  sessionId: string
  toolName: string
  toolInput: unknown
  cwd?: string
  createdAt: number
  decision?: Decision
  reason?: string
  decidedAt?: number
}

export interface HookEnvelope {
  machine: string
  agent?: string
  ts?: number
  event: {
    session_id?: string
    hook_event_name?: string
    cwd?: string
    message?: string
    prompt?: string
    tool_name?: string
    tool_input?: Record<string, unknown>
    [k: string]: unknown
  }
}

export type ChangeMessage =
  | { type: 'session'; session: Session }
  | { type: 'session_removed'; key: string }
  | { type: 'permission'; request: PermissionRequest }
  | { type: 'permission_resolved'; id: string; decision: Decision; reason?: string }

const STALE_AFTER_MS = 15 * 60 * 1000
const RETAIN_FINISHED_MS = 6 * 60 * 60 * 1000
// Hooks long-poll for 55s; anything older than this was abandoned (hook died
// before polling) and would otherwise leave a stuck approval card.
const PERMISSION_EXPIRY_MS = 90 * 1000
const ACTIVE_STATES: SessionState[] = ['working', 'needs_permission', 'needs_attention']

function trunc(s: unknown, n: number): string | undefined {
  if (typeof s !== 'string' || s.length === 0) return undefined
  return s.length > n ? s.slice(0, n) + '…' : s
}

function describeTool(name: string, input?: Record<string, unknown>): string {
  if (name === 'Bash') return trunc(`$ ${input?.command ?? ''}`, 120) ?? name
  if (name === 'Write' || name === 'Edit' || name === 'MultiEdit')
    return trunc(`${name} ${input?.file_path ?? ''}`, 120) ?? name
  if (name === 'ExitPlanMode') return 'Plan ready for review'
  return name
}

export class Store {
  sessions = new Map<string, Session>()
  permissions = new Map<string, PermissionRequest>()
  private waiters = new Map<string, ((r: PermissionRequest) => void)[]>()
  private listeners: ((msg: ChangeMessage) => void)[] = []
  private logFile: string

  constructor(dataDir: string) {
    mkdirSync(dataDir, { recursive: true })
    this.logFile = path.join(dataDir, 'events.jsonl')
  }

  onChange(cb: (msg: ChangeMessage) => void) {
    this.listeners.push(cb)
  }

  private emit(msg: ChangeMessage) {
    for (const l of this.listeners) l(msg)
  }

  private log(kind: string, data: unknown) {
    appendFile(this.logFile, JSON.stringify({ ts: Date.now(), kind, data }) + '\n').catch(() => {})
  }

  snapshot() {
    return {
      sessions: [...this.sessions.values()].sort((a, b) => b.updatedAt - a.updatedAt),
      permissions: [...this.permissions.values()].filter(p => !p.decision),
    }
  }

  private upsert(env: HookEnvelope): Session {
    const sid = env.event.session_id as string
    const key = `${env.machine}:${sid}`
    let s = this.sessions.get(key)
    if (!s) {
      s = {
        key,
        machine: env.machine,
        sessionId: sid,
        agent: env.agent ?? 'claude-code',
        state: 'working',
        startedAt: Date.now(),
        updatedAt: Date.now(),
        pendingPermissionIds: [],
      }
      this.sessions.set(key, s)
    }
    if (env.event.cwd) s.cwd = env.event.cwd
    return s
  }

  private hasPendingPermission(s: Session): boolean {
    return s.pendingPermissionIds.some(id => {
      const req = this.permissions.get(id)
      return !!req && !req.decision
    })
  }

  handleEvent(env: HookEnvelope): Session | undefined {
    if (!env?.machine || !env.event?.session_id) return undefined
    this.log('event', env)
    const s = this.upsert(env)
    switch (env.event.hook_event_name) {
      case 'SessionStart':
        s.state = 'working'
        break
      case 'UserPromptSubmit':
        s.state = 'working'
        s.lastMessage = trunc(env.event.prompt, 200)
        break
      case 'PreToolUse':
      case 'PostToolUse':
        if (!this.hasPendingPermission(s)) s.state = 'working'
        if (env.event.tool_name) s.lastTool = describeTool(env.event.tool_name, env.event.tool_input)
        break
      case 'Notification':
        if (!this.hasPendingPermission(s)) s.state = 'needs_attention'
        s.lastMessage = trunc(env.event.message, 300)
        break
      case 'Stop':
        s.state = 'done'
        break
      case 'SessionEnd':
        s.state = 'ended'
        break
      default:
        break
    }
    s.updatedAt = Date.now()
    this.emit({ type: 'session', session: s })
    return s
  }

  createPermission(env: HookEnvelope): PermissionRequest | undefined {
    if (!env?.machine || !env.event?.session_id || !env.event.tool_name) return undefined
    this.log('permission_request', env)
    const s = this.upsert(env)
    const req: PermissionRequest = {
      id: randomUUID(),
      machine: env.machine,
      sessionId: env.event.session_id,
      toolName: env.event.tool_name,
      toolInput: env.event.tool_input,
      cwd: env.event.cwd,
      createdAt: Date.now(),
    }
    this.permissions.set(req.id, req)
    s.state = 'needs_permission'
    s.pendingPermissionIds.push(req.id)
    s.lastTool = describeTool(req.toolName, env.event.tool_input)
    s.updatedAt = Date.now()
    this.emit({ type: 'permission', request: req })
    this.emit({ type: 'session', session: s })
    return req
  }

  decide(id: string, decision: Decision, reason?: string): PermissionRequest | undefined {
    const req = this.permissions.get(id)
    if (!req || req.decision) return undefined
    req.decision = decision
    req.reason = reason
    req.decidedAt = Date.now()
    this.log('permission_decision', { id, decision, reason })

    const s = this.sessions.get(`${req.machine}:${req.sessionId}`)
    if (s && s.pendingPermissionIds.includes(id)) {
      s.pendingPermissionIds = s.pendingPermissionIds.filter(p => p !== id)
      // Only leave needs_permission once every queued request is resolved.
      if (!this.hasPendingPermission(s)) {
        // On timeout the hook falls back to the terminal prompt, so the user is needed there.
        s.state = decision === 'timeout' ? 'needs_attention' : 'working'
      }
      s.updatedAt = Date.now()
      this.emit({ type: 'session', session: s })
    }

    const waiters = this.waiters.get(id) ?? []
    this.waiters.delete(id)
    for (const w of waiters) w(req)
    this.emit({ type: 'permission_resolved', id, decision, reason })
    return req
  }

  waitForDecision(id: string, waitMs: number): Promise<PermissionRequest> | undefined {
    const req = this.permissions.get(id)
    if (!req) return undefined
    if (req.decision) return Promise.resolve(req)
    return new Promise(resolve => {
      const done = (r: PermissionRequest) => {
        clearTimeout(timer)
        resolve(r)
      }
      const timer = setTimeout(() => {
        if (!this.permissions.get(id)?.decision) this.decide(id, 'timeout', 'No decision before hook timeout')
      }, waitMs)
      this.waiters.set(id, [...(this.waiters.get(id) ?? []), done])
    })
  }

  sweepStale() {
    // Expire abandoned permission requests (hook died before long-polling) so
    // approval cards can't get stuck.
    const permCutoff = Date.now() - PERMISSION_EXPIRY_MS
    for (const req of this.permissions.values()) {
      if (!req.decision && req.createdAt < permCutoff) {
        this.decide(req.id, 'timeout', 'Expired unanswered')
      }
    }

    const cutoff = Date.now() - STALE_AFTER_MS
    for (const s of this.sessions.values()) {
      if (ACTIVE_STATES.includes(s.state) && s.updatedAt < cutoff) {
        s.state = 'stale'
        s.updatedAt = Date.now()
        this.emit({ type: 'session', session: s })
      }
    }
    // Prune finished sessions so they don't accumulate forever.
    const retainCutoff = Date.now() - RETAIN_FINISHED_MS
    for (const [key, s] of this.sessions) {
      if (!ACTIVE_STATES.includes(s.state) && s.updatedAt < retainCutoff) {
        this.sessions.delete(key)
        this.emit({ type: 'session_removed', key })
      }
    }
  }
}
