import type { Message } from '../adapters/types.js';

interface Chunk {
  text: string;
  sessionId: string;
  chunkIndex: number;
}

const DEFAULT_MAX_CHARS = 800;
const DEFAULT_OVERLAP = 200;

/**
 * Chunk messages for embedding. Primary split: message boundaries.
 * Secondary split: sliding window for oversized individual messages.
 */
export function chunkMessages(
  sessionId: string,
  messages: Message[],
  opts?: { maxChars?: number; overlap?: number },
): Chunk[] {
  const maxChars = opts?.maxChars ?? DEFAULT_MAX_CHARS;
  const overlap = opts?.overlap ?? DEFAULT_OVERLAP;
  const chunks: Chunk[] = [];
  let idx = 0;
  let buffer = '';

  for (const msg of messages) {
    // Skip empty or system messages
    if (!msg.content?.trim() || msg.role === 'system') continue;

    const line = `[${msg.role}] ${msg.content.trim()}`;

    // If a single message exceeds maxChars, flush buffer then window-chunk it
    if (line.length > maxChars) {
      if (buffer.trim()) {
        chunks.push({ text: buffer.trim(), sessionId, chunkIndex: idx++ });
        buffer = '';
      }
      for (const sub of slidingWindow(line, maxChars, overlap)) {
        chunks.push({ text: sub, sessionId, chunkIndex: idx++ });
      }
      continue;
    }

    // Accumulate messages into buffer, flush when full
    if (buffer.length + line.length + 1 > maxChars && buffer.trim()) {
      chunks.push({ text: buffer.trim(), sessionId, chunkIndex: idx++ });
      buffer = '';
    }
    buffer += (buffer ? '\n' : '') + line;
  }

  // Flush remaining
  if (buffer.trim()) {
    chunks.push({ text: buffer.trim(), sessionId, chunkIndex: idx++ });
  }

  return chunks;
}

function slidingWindow(
  text: string,
  windowSize: number,
  overlap: number,
): string[] {
  const results: string[] = [];
  const step = windowSize - overlap;
  for (let i = 0; i < text.length; i += step) {
    results.push(text.slice(i, i + windowSize));
    if (i + windowSize >= text.length) break;
  }
  return results;
}
