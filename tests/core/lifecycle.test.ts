import { describe, it, expect, vi } from 'vitest'
import { setupProcessLifecycle } from '../../src/core/lifecycle.js'

describe('setupProcessLifecycle', () => {
  // 1. Signal handlers registered without throwing
  it('registers signal handlers and returns a heartbeat handle', () => {
    // setupProcessLifecycle should not throw and should return a handle
    const handle = setupProcessLifecycle({
      idleTimeoutMs: 0,  // disable idle timeout so it doesn't interfere
      onExit: () => {},
    })
    expect(handle).toBeDefined()
    expect(typeof handle.heartbeat).toBe('function')
  })

  // 2. Idle timeout calls cleanup callback
  it('idle timeout triggers onExit callback', async () => {
    const onExit = vi.fn()
    // Mock process.exit to prevent actual exit
    const exitSpy = vi.spyOn(process, 'exit').mockImplementation((() => {}) as any)

    setupProcessLifecycle({
      idleTimeoutMs: 50,  // 50ms for fast test
      onExit,
    })

    // Wait for the idle timer to fire
    await new Promise(resolve => setTimeout(resolve, 150))

    expect(onExit).toHaveBeenCalled()
    expect(exitSpy).toHaveBeenCalledWith(0)

    exitSpy.mockRestore()
  })

  // 3. Parent process check handles missing PID
  it('heartbeat resets idle timer (does not exit prematurely)', async () => {
    const onExit = vi.fn()
    const exitSpy = vi.spyOn(process, 'exit').mockImplementation((() => {}) as any)

    const handle = setupProcessLifecycle({
      idleTimeoutMs: 100,
      onExit,
    })

    // Heartbeat before timeout
    await new Promise(resolve => setTimeout(resolve, 50))
    handle.heartbeat()

    // Wait past the original timeout but not past the reset one
    await new Promise(resolve => setTimeout(resolve, 70))
    expect(onExit).not.toHaveBeenCalled()

    // Wait for the reset timer to fire
    await new Promise(resolve => setTimeout(resolve, 80))
    expect(onExit).toHaveBeenCalled()

    exitSpy.mockRestore()
  })
})
