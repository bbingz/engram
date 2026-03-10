export interface AutoSummaryOptions {
  cooldownMs: number
  minMessages: number
  onTrigger: (sessionId: string) => Promise<void>
  hasSummary: (sessionId: string) => boolean
}

export class AutoSummaryManager {
  private timers = new Map<string, ReturnType<typeof setTimeout>>()
  private messageCounts = new Map<string, number>()
  private opts: AutoSummaryOptions

  constructor(opts: AutoSummaryOptions) {
    this.opts = opts
  }

  onSessionIndexed(sessionId: string, messageCount: number): void {
    this.messageCounts.set(sessionId, messageCount)
    const existing = this.timers.get(sessionId)
    if (existing) clearTimeout(existing)
    const timer = setTimeout(() => {
      this.timers.delete(sessionId)
      this.tryGenerate(sessionId).catch(() => {})
    }, this.opts.cooldownMs)
    this.timers.set(sessionId, timer)
  }

  private async tryGenerate(sessionId: string): Promise<void> {
    const count = this.messageCounts.get(sessionId) ?? 0
    if (count < this.opts.minMessages) return
    if (this.opts.hasSummary(sessionId)) return
    await this.opts.onTrigger(sessionId)
  }

  cleanup(): void {
    for (const timer of this.timers.values()) clearTimeout(timer)
    this.timers.clear()
    this.messageCounts.clear()
  }
}
