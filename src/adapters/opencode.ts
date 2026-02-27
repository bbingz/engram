// src/adapters/opencode.ts
import { stat } from 'fs/promises'
import { homedir } from 'os'
import { join } from 'path'
import type { SessionAdapter, SessionInfo, Message, StreamMessagesOptions } from './types.js'

// TODO: OpenCode 的实际存储格式待确认
// 当前 ~/.local/share/opencode/storage/session_diff/*.json 内容为空数组
// 待有真实数据后补全实现
export class OpenCodeAdapter implements SessionAdapter {
  readonly name = 'opencode' as const
  private storageRoot: string

  constructor(storageRoot?: string) {
    this.storageRoot = storageRoot ?? join(homedir(), '.local', 'share', 'opencode', 'storage')
  }

  async detect(): Promise<boolean> {
    try {
      await stat(this.storageRoot)
      return true
    } catch {
      return false
    }
  }

  async *listSessionFiles(): AsyncGenerator<string> {
    // TODO: 实现后补全
  }

  async parseSessionInfo(_filePath: string): Promise<SessionInfo | null> {
    return null
  }

  async *streamMessages(_filePath: string, _opts?: StreamMessagesOptions): AsyncGenerator<Message> {
    // TODO: 实现后补全
  }
}
