// Auth + network policy, kept pure and side-effect-free so they are unit-testable.

export interface Tokens {
  machineToken: string
  operatorToken: string
  /** Per-machine tokens (token → machine name) for hosts that are not fully trusted. */
  machineTokens?: Map<string, string>
  /** Extra operator tokens (token → device name), each revocable on its own. */
  operatorTokens?: Map<string, string>
}

/**
 * Who a bearer token belongs to. A per-machine token is a machine role pinned to one
 * machine name: whatever `machine` its payload claims, it reports as that machine.
 * Requests that came in over the internet relay (`viaRelay`) may use only per-machine
 * tokens, so the shared machine and operator tokens never work from outside the tailnet.
 * Empty tokens never authorize (defends against a misconfigured blank secret).
 */
export type Principal = { role: 'operator' } | { role: 'machine'; machine?: string }

export function principalFor(authHeader: string | undefined, tokens: Tokens, viaRelay = false): Principal | undefined {
  if (!authHeader?.startsWith('Bearer ')) return undefined
  const token = authHeader.slice(7)
  if (!token) return undefined
  const bound = tokens.machineTokens?.get(token)
  if (bound) return { role: 'machine', machine: bound }
  if (viaRelay) return undefined
  if (tokens.operatorToken && token === tokens.operatorToken) return { role: 'operator' }
  if (tokens.operatorTokens?.has(token)) return { role: 'operator' }
  if (tokens.machineToken && token === tokens.machineToken) return { role: 'machine' }
  return undefined
}

/** Bearer-token authorization for a given role. Operator implies machine rights. */
export function authorizeRole(authHeader: string | undefined, role: 'machine' | 'operator', tokens: Tokens): boolean {
  const p = principalFor(authHeader, tokens)
  return !!p && (p.role === 'operator' || role === 'machine')
}

/**
 * NOTCH_MACHINE_TOKENS="panda=<token>,other=<token>" → token → machine name
 * (also NOTCH_OPERATOR_TOKENS, keyed by device name).
 * Throws on anything malformed so the server refuses to start rather than run open.
 */
export function parseMachineTokens(raw: string, shared: string[] = [], envName = 'NOTCH_MACHINE_TOKENS'): Map<string, string> {
  const out = new Map<string, string>()
  for (const entry of raw.split(',').map(s => s.trim()).filter(Boolean)) {
    const eq = entry.indexOf('=')
    const machine = eq > 0 ? entry.slice(0, eq) : ''
    const token = entry.slice(eq + 1)
    if (!/^[a-z0-9][a-z0-9-]{0,31}$/.test(machine)) throw new Error(`${envName}: bad name`)
    if (token.length < 16) throw new Error(`${envName}: token for ${machine} is too short`)
    if (shared.includes(token) || out.has(token)) throw new Error(`${envName}: token for ${machine} is reused`)
    out.set(token, machine)
  }
  return out
}

// Network source policy, kept pure and side-effect-free so it is unit-testable.
// Only loopback and the Tailscale tailnet (100.64.0.0/10, fd7a:115c:a1e0::/48)
// may talk to the server — LAN and internet sources are rejected outright.
export function allowedSource(ip: string | undefined): boolean {
  if (!ip) return false
  const v4 = ip.startsWith('::ffff:') ? ip.slice(7) : ip
  if (v4 === '127.0.0.1' || ip === '::1') return true
  if (ip.toLowerCase().startsWith('fd7a:115c:a1e0')) return true
  const parts = v4.split('.').map(Number)
  return (
    parts.length === 4 &&
    parts.every(n => Number.isInteger(n) && n >= 0 && n <= 255) &&
    parts[0] === 100 &&
    parts[1] >= 64 &&
    parts[1] <= 127
  )
}
