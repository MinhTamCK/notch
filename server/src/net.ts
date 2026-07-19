// Auth + network policy, kept pure and side-effect-free so they are unit-testable.

/**
 * Bearer-token authorization for a given role. Operator implies machine rights.
 * Empty tokens never authorize (defends against a misconfigured blank secret).
 */
export function authorizeRole(
  authHeader: string | undefined,
  role: 'machine' | 'operator',
  tokens: { machineToken: string; operatorToken: string },
): boolean {
  if (!authHeader?.startsWith('Bearer ')) return false
  const token = authHeader.slice(7)
  if (!token) return false
  if (tokens.operatorToken && token === tokens.operatorToken) return true
  if (role === 'machine' && tokens.machineToken && token === tokens.machineToken) return true
  return false
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
