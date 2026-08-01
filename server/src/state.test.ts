import { describe, it, expect } from 'vitest'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { Store, redact, describeQuestion, cleanUsage } from './state.js'

describe('describeQuestion', () => {
  it('summarizes the question with its option labels', () => {
    const out = describeQuestion({
      questions: [{ question: 'Which next step?', options: [{ label: 'Release' }, { label: 'Tests' }] }],
    })
    expect(out).toBe('Which next step? · Release / Tests')
  })

  it('falls back to header when there is no question text, and to just the question with no options', () => {
    expect(describeQuestion({ questions: [{ header: 'Next', options: [] }] })).toBe('Next')
    expect(describeQuestion({ questions: [{ question: 'Proceed?' }] })).toBe('Proceed?')
  })

  it('returns undefined when there are no questions', () => {
    expect(describeQuestion({})).toBeUndefined()
    expect(describeQuestion(undefined)).toBeUndefined()
  })
})

describe('AskUserQuestion permissions', () => {
  it('hands the answers to the long-polling hook and summarizes the question', async () => {
    const store = new Store(mkdtempSync(path.join(tmpdir(), 'notch-test-')))
    const req = store.createPermission({
      machine: 'vm',
      event: {
        session_id: 's1',
        hook_event_name: 'PreToolUse',
        tool_name: 'AskUserQuestion',
        tool_input: { questions: [{ question: 'Which?', options: [{ label: 'A' }, { label: 'B' }] }] },
      },
    })!
    expect(store.sessions.get('vm:s1')?.lastTool).toBe('Which? · A / B')

    const pending = store.waitForDecision(req.id, 5000)!
    store.decide(req.id, 'allow', 'Answered via Notch app', { 'Which?': 'A' })
    const decided = await pending
    expect(decided.decision).toBe('allow')
    expect(decided.answers).toEqual({ 'Which?': 'A' })
  })
})

describe('usage reporting', () => {
  it('accepts statusline rate_limits and includes them in the snapshot', () => {
    const store = new Store(mkdtempSync(path.join(tmpdir(), 'notch-test-')))
    const usage = store.setUsage({
      five_hour: { used_percentage: 38.5, resets_at: 1738425600 },
      seven_day: { used_percentage: 11.2, resets_at: 1738857600 },
    })
    expect(usage?.five_hour?.used_percentage).toBe(38.5)
    expect(store.snapshot().usage?.seven_day?.resets_at).toBe(1738857600)
  })

  it('rejects malformed payloads and junk fields', () => {
    expect(cleanUsage(null)).toBeUndefined()
    expect(cleanUsage('nope')).toBeUndefined()
    expect(cleanUsage({ five_hour: { used_percentage: 'high' } })).toBeUndefined()
    const cleaned = cleanUsage({
      five_hour: { used_percentage: 5, resets_at: 'soon', extra: true },
    })
    expect(cleaned).toEqual({ five_hour: { used_percentage: 5, resets_at: undefined }, seven_day: undefined })
  })
})

describe('redact', () => {
  it('keeps only metadata, never prompt/command/file content', () => {
    const envelope = {
      machine: 'vm-alpha',
      agent: 'claude-code',
      event: {
        session_id: 's1',
        hook_event_name: 'PreToolUse',
        tool_name: 'Bash',
        tool_input: { command: 'cat ~/.ssh/id_rsa' },
        prompt: 'my secret prompt with an API key sk-abc123',
      },
    }
    const out = redact(envelope) as Record<string, unknown>
    expect(out.machine).toBe('vm-alpha')
    expect(out.tool_name).toBe('Bash')
    expect(out.has_tool_input).toBe(true)
    expect(out.has_prompt).toBe(true)
    // The sensitive parts must not survive redaction.
    const serialized = JSON.stringify(out)
    expect(serialized).not.toContain('id_rsa')
    expect(serialized).not.toContain('sk-abc123')
    expect(serialized).not.toContain('secret prompt')
  })

  it('reports absence of optional fields', () => {
    const out = redact({ machine: 'm', event: { session_id: 's', hook_event_name: 'Stop' } }) as Record<string, unknown>
    expect(out.has_tool_input).toBe(false)
    expect(out.has_prompt).toBe(false)
  })

  it('passes through non-object input unchanged', () => {
    expect(redact(null)).toBe(null)
    expect(redact('x')).toBe('x')
  })
})
