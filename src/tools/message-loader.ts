// src/tools/message-loader.ts
//
// Bounded message loader for tools that previously buffered an entire session
// into memory (generate_summary, export, /api/summary). A pathological session
// with 100k+ messages × ~1KB each is ~100MB+ — enough to OOM the host.
//
// We keep only the first `head` messages plus a sliding window of the last
// `tail` messages (via a ring buffer), and cap each message's content length.
// This preserves the head+tail shape that summary sampling already relies on
// (see sampleMessages in ai-client.ts) while bounding peak memory to roughly
// (head + tail) × maxContentChars regardless of session size.

interface StreamedMessage {
  role: string;
  content: string;
  timestamp?: string;
}

interface BoundedLoadOptions {
  /** Messages to retain from the start of the session. */
  head?: number;
  /** Messages to retain from the end of the session. */
  tail?: number;
  /** Per-message content cap (chars). Longer content is truncated with an ellipsis. */
  maxContentChars?: number;
}

interface BoundedLoadResult {
  messages: StreamedMessage[];
  /** Total messages seen in the stream (not the retained count). */
  totalSeen: number;
  /** True when messages were dropped from the middle to stay within the cap. */
  truncated: boolean;
}

// Defaults are generous relative to typical summary sampling configs
// (sampleFirst/sampleLast are usually a few dozen), so normal sessions are
// unaffected and only abusive sessions get clipped.
const DEFAULT_HEAD = 500;
const DEFAULT_TAIL = 500;
const DEFAULT_MAX_CONTENT_CHARS = 50_000;

function clip(content: string, max: number): string {
  return content.length > max ? `${content.slice(0, max)}...` : content;
}

/**
 * Stream messages from an adapter while holding at most `head + tail` of them
 * in memory. Returns them in original order with a truncation flag.
 */
export async function loadBoundedMessages(
  stream: AsyncIterable<{ role: string; content: string; timestamp?: string }>,
  opts: BoundedLoadOptions = {},
): Promise<BoundedLoadResult> {
  const head = opts.head ?? DEFAULT_HEAD;
  const tail = opts.tail ?? DEFAULT_TAIL;
  const maxContentChars = opts.maxContentChars ?? DEFAULT_MAX_CONTENT_CHARS;

  const headBuf: StreamedMessage[] = [];
  // Ring buffer for the tail so we never grow beyond `tail` entries.
  const tailBuf: StreamedMessage[] = [];
  let tailStart = 0;
  let totalSeen = 0;

  for await (const msg of stream) {
    totalSeen++;
    const entry: StreamedMessage = {
      role: msg.role,
      content: clip(msg.content, maxContentChars),
      timestamp: msg.timestamp,
    };
    if (headBuf.length < head) {
      headBuf.push(entry);
      continue;
    }
    if (tail <= 0) continue;
    if (tailBuf.length < tail) {
      tailBuf.push(entry);
    } else {
      tailBuf[tailStart] = entry;
      tailStart = (tailStart + 1) % tail;
    }
  }

  // Unroll the ring buffer back into chronological order.
  const orderedTail =
    tailBuf.length < tail
      ? tailBuf
      : [...tailBuf.slice(tailStart), ...tailBuf.slice(0, tailStart)];

  const truncated = totalSeen > head + orderedTail.length;
  return {
    messages: [...headBuf, ...orderedTail],
    totalSeen,
    truncated,
  };
}
