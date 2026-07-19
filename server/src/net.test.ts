import { describe, it, expect } from 'vitest'
import { allowedSource } from './net.js'

describe('allowedSource', () => {
  it('allows loopback (v4 and v6)', () => {
    expect(allowedSource('127.0.0.1')).toBe(true)
    expect(allowedSource('::1')).toBe(true)
    expect(allowedSource('::ffff:127.0.0.1')).toBe(true)
  })

  it('allows the Tailscale range 100.64.0.0/10', () => {
    expect(allowedSource('100.64.0.1')).toBe(true)
    expect(allowedSource('100.82.132.78')).toBe(true) // the real VM
    expect(allowedSource('100.127.255.255')).toBe(true)
    expect(allowedSource('::ffff:100.82.132.78')).toBe(true)
  })

  it('allows the Tailscale IPv6 ULA prefix', () => {
    expect(allowedSource('fd7a:115c:a1e0::1')).toBe(true)
    expect(allowedSource('FD7A:115C:A1E0::abcd')).toBe(true)
  })

  it('rejects LAN and public addresses', () => {
    expect(allowedSource('192.168.1.10')).toBe(false) // Mac's own LAN IP
    expect(allowedSource('192.168.1.14')).toBe(false)
    expect(allowedSource('10.0.0.5')).toBe(false)
    expect(allowedSource('8.8.8.8')).toBe(false)
    expect(allowedSource('172.16.0.1')).toBe(false)
  })

  it('rejects near-miss CGNAT boundaries', () => {
    expect(allowedSource('100.63.255.255')).toBe(false) // just below /10
    expect(allowedSource('100.128.0.0')).toBe(false) // just above /10
    expect(allowedSource('101.64.0.1')).toBe(false)
  })

  it('rejects malformed and empty input', () => {
    expect(allowedSource(undefined)).toBe(false)
    expect(allowedSource('')).toBe(false)
    expect(allowedSource('not-an-ip')).toBe(false)
    expect(allowedSource('100.64')).toBe(false)
    expect(allowedSource('100.999.0.1')).toBe(false)
  })
})
