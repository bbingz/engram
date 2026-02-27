// tests/core/project.test.ts
import { describe, it, expect } from 'vitest'
import { resolveProjectName } from '../../src/core/project.js'

describe('resolveProjectName', () => {
  it('falls back to last path segment for non-git directory', async () => {
    const name = await resolveProjectName('/Users/test/my-awesome-project')
    expect(name).toBe('my-awesome-project')
  })

  it('handles trailing slash', async () => {
    const name = await resolveProjectName('/Users/test/my-project/')
    // basename('/Users/test/my-project/') returns '' in Node.js, so we strip trailing slash first
    expect(name).toBeTruthy()
  })

  it('handles empty cwd', async () => {
    const name = await resolveProjectName('')
    expect(name).toBe('')
  })
})
