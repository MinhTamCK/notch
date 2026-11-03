import { describe, it, expect } from 'vitest'
import { localRequest, type RelayRequest } from './connector.js'

const BASE = 'http://100.82.132.78:4519'
const ID = '0b6f3c1e-7d2a-4c55-9f0e-2a1b3c4d5e6f'
const msg = (method: string, path: string, extra: Partial<RelayRequest> = {}): RelayRequest => ({
  id: 'x',
  method,
  path,
  token: 'panda-secret-1234567890',
  body: '{}',
  ...extra,
})

describe('relay connector allowlist', () => {
  it('forwards the three machine calls, marked as relayed', () => {
    for (const [m, p] of [['POST', '/api/events'], ['POST', '/api/permissions'], ['GET', `/api/permissions/${ID}/decision`]]) {
      const r = localRequest(msg(m, p), BASE)
      expect(r?.url.startsWith(`${BASE}${p}`)).toBe(true)
      expect((r?.init.headers as Record<string, string>)['x-notch-relay']).toBe('1')
    }
  })

  it('refuses everything a viewer or operator would use', () => {
    for (const [m, p] of [
      ['GET', '/api/sessions'],
      ['GET', '/api/permissions'],
      ['POST', `/api/permissions/${ID}/decide`],
      ['POST', '/api/usage'],
      ['GET', '/ws'],
      ['GET', '/dashboard/'],
      ['GET', '/api/events'],
      ['POST', '/api/events/../sessions'],
      ['POST', '//evil.example/api/events'],
      ['GET', `/api/permissions/${ID}/decision/../../../sessions`],
    ]) {
      expect(localRequest(msg(m, p), BASE)).toBeUndefined()
    }
  })

  it('refuses a request with no token', () => {
    expect(localRequest(msg('POST', '/api/events', { token: '' }), BASE)).toBeUndefined()
  })

  it('clamps the decision wait', () => {
    const r = localRequest(msg('GET', `/api/permissions/${ID}/decision`, { wait: 9999 }), BASE)
    expect(new URL(r!.url).searchParams.get('wait')).toBe('60')
  })
})
