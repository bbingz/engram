// src/core/lifecycle.ts
// Multi-layer process lifecycle manager.
// Ensures Node.js processes exit cleanly when their parent/client disappears.

interface LifecycleOptions {
  /** Idle timeout in ms. Default 300_000 (5 min). Set 0 to disable. */
  idleTimeoutMs?: number;
  /** Cleanup callback — close watchers, db connections, etc. */
  onExit?: () => void;
}

interface LifecycleHandle {
  /** Call on each MCP request / meaningful activity to reset idle timer. */
  heartbeat: () => void;
}

export function setupProcessLifecycle(
  options?: LifecycleOptions,
): LifecycleHandle {
  const idleTimeoutMs = options?.idleTimeoutMs ?? 300_000;
  const onExit = options?.onExit;
  let exiting = false;

  function exit() {
    if (exiting) return;
    exiting = true;
    try {
      onExit?.();
    } catch {} // intentional: best-effort cleanup on exit
    process.exit(0);
  }

  // Layer 1: stdin end/close — fires when MCP client closes the pipe
  process.stdin.on('end', exit);
  process.stdin.on('close', exit);
  // Ensure stdin is in flowing mode so 'end' fires when pipe closes.
  // If nothing else is consuming stdin data, attach a no-op handler.
  if (!process.stdin.readableFlowing) {
    process.stdin.resume();
  }

  // Layer 2: Parent process liveness — detect parent crash/kill
  const ppid = process.ppid;
  if (ppid && ppid > 1) {
    const parentCheck = setInterval(() => {
      try {
        process.kill(ppid, 0); // signal 0 = existence check, no actual signal
      } catch {
        // intentional: parent no longer exists (ESRCH), trigger cleanup
        exit();
      }
    }, 2000);
    parentCheck.unref(); // don't keep event loop alive just for this
  }

  // Layer 3: Idle timeout — exit if no MCP requests for N minutes
  let idleTimer: ReturnType<typeof setTimeout> | null = null;

  function resetIdleTimer() {
    if (idleTimeoutMs <= 0) return;
    if (idleTimer) clearTimeout(idleTimer);
    idleTimer = setTimeout(exit, idleTimeoutMs);
    idleTimer.unref();
  }

  if (idleTimeoutMs > 0) {
    resetIdleTimer();
  }

  // Layer 4: Signal handlers — graceful shutdown on SIGTERM/SIGINT
  process.on('SIGTERM', exit);
  process.on('SIGINT', exit);

  return {
    heartbeat: resetIdleTimer,
  };
}
