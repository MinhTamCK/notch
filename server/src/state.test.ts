import { describe, it, expect } from 'vitest'
import { redact, describeQuestion } from './state.js'

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
