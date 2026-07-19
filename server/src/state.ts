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
  agent?: string
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

// Configurable via ~/.notch/env: NOTCH_STALE_MINUTES / NOTCH_RETAIN_HOURS.
const STALE_AFTER_MS = (Number(process.env.NOTCH_STALE_MINUTES) || 15) * 60 * 1000
const RETAIN_FINISHED_MS = (Number(process.env.NOTCH_RETAIN_HOURS) || 6) * 60 * 60 * 1000
// Hooks long-poll for 55s; anything older than this was abandoned (hook died
// before polling) and would otherwise leave a stuck approval card.
const PERMISSION_EXPIRY_MS = 90 * 1000
const ACTIVE_STATES: SessionState[] = ['working', 'needs_permission', 'needs_attention']

function trunc(s: unknown, n: number): string | undefined {
  if (typeof s !== 'string' || s.length === 0) return undefined
  return s.length > n ? s.slice(0, n) + '…' : s
}

/** Metadata-only view of a hook envelope for the default (privacy-preserving) log. */
export function redact(data: unknown): unknown {
  if (!data || typeof data !== 'object') return data
  const env = data as HookEnvelope
  const event = env.event ?? {}
  return {
    machine: env.machine,
    agent: env.agent,
    session_id: event.session_id,
    hook_event_name: event.hook_event_name,
    tool_name: event.tool_name,
    // Never the command/prompt/file contents — just the fact that they existed.
    has_tool_input: event.tool_input != null,
    has_prompt: event.prompt != null,
  }
}

/// Slash-command invocations arrive as XML-ish wrappers; show the command itself
/// instead of raw markup. Ordinary prompts pass through untouched.
function cleanPrompt(p: unknown): string | undefined {
  if (typeof p !== 'string') return undefined
  const cmd = p.match(/<command-name>([^<]+)<\/command-name>/)
  if (cmd) {
    const args = p.match(/<command-args>([^<]*)<\/command-args>/)
    return trunc(`${cmd[1].trim()} ${args?.[1]?.trim() ?? ''}`.trim(), 200)
  }
  return trunc(p, 200)
}

export function describeQuestion(input?: Record<string, unknown>): string | undefined {
  const questions = input?.questions as Array<Record<string, unknown>> | undefined
  const first = questions?.[0]
  if (!first) return undefined
  const q = (first.question as string) ?? (first.header as string) ?? 'Question'
  const opts = ((first.options as Array<Record<string, unknown>>) ?? [])
    .map(o => o.label as string)
    .filter(Boolean)
  return trunc(opts.length ? `${q} · ${opts.slice(0, 4).join(' / ')}` : q, 300)
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

  // Raw prompts/commands/file contents are only logged when explicitly opted in.
  private logPayloads = process.env.NOTCH_LOG_PAYLOADS === '1'

  constructor(dataDir: string) {
    mkdirSync(dataDir, { recursive: true, mode: 0o700 })
    this.logFile = path.join(dataDir, 'events.jsonl')
  }

  onChange(cb: (msg: ChangeMessage) => void) {
    this.listeners.push(cb)
  }

  private emit(msg: ChangeMessage) {
    for (const l of this.listeners) l(msg)
  }

  private log(kind: string, data: unknown) {
    const entry = this.logPayloads ? { ts: Date.now(), kind, data } : { ts: Date.now(), kind, meta: redact(data) }
    appendFile(this.logFile, JSON.stringify(entry) + '\n', { mode: 0o600 }).catch(() => {})
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
    // Never materialize a session from a terminal event (phantom "done" rows).
    const name = env.event.hook_event_name ?? ''
    if (
      (name === 'Stop' || name === 'SessionEnd') &&
      !this.sessions.has(`${env.machine}:${env.event.session_id}`)
    ) {
      return undefined
    }
    const s = this.upsert(env)
    switch (env.event.hook_event_name) {
      case 'SessionStart':
        s.state = 'working'
        break
      case 'UserPromptSubmit':
        s.state = 'working'
        s.lastMessage = cleanPrompt(env.event.prompt)
        break
      case 'PreToolUse':
        if (env.event.tool_name === 'AskUserQuestion') {
          // Claude is waiting for you to pick an option — surface it, don't say "working".
          s.state = 'needs_attention'
          s.lastMessage = describeQuestion(env.event.tool_input) ?? 'Claude is asking you a question'
          break
        }
      // falls through to the generic tool handling below
      case 'PostToolUse':
        if (!this.hasPendingPermission(s)) s.state = 'working'
        if (env.event.tool_name) s.lastTool = describeTool(env.event.tool_name, env.event.tool_input)
        break
      case 'Notification': {
        const msg = env.event.message ?? ''
        // "waiting for your input" is the idle "your turn" ping — not an action to
        // confirm, so don't force-expand or hold the panel open for it.
        if (!msg.toLowerCase().includes('waiting for your input') && !this.hasPendingPermission(s)) {
          s.state = 'needs_attention'
        }
        s.lastMessage = trunc(msg, 300)
        break
      }
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
      agent: env.agent ?? 'claude-code',
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
