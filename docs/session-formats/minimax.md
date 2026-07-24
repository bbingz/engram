# MiniMax — On-Disk Session Format (Detection Overlay)

Last researched: 2026-07-24

MiniMax is **not** a standalone session store. It is a *detection overlay* on
top of Claude Code: a session is reclassified from `claude-code` to `minimax`
purely by inspecting the model name, while the bytes on disk remain ordinary
Claude Code JSONL. There is no MiniMax-specific file, directory, schema, or
storage technology.

> **Evidence basis:** adapter source (TypeScript `src/adapters/claude-code.ts`,
> Swift `ClaudeCodeAdapter.swift`) + parity/unit tests, cross-checked against the
> **live store** `~/.claude/projects/` (5276 `*.jsonl` files scanned). **Zero**
> real sessions currently carry an actual MiniMax `message.model` field (see
> [Gotchas](#gotchas)), so the field tables below are adapter-defined and
> test-fixture-confirmed, not sampled from a live MiniMax session on this
> machine.

---

## Overview

The on-disk format is **identical to Claude Code** in every respect — same
root (`~/.claude/projects/`), same project-dir name encoding, same JSONL record
types, same `message` / content-block nesting, same subagent layout. For the
complete record-by-record / field-by-field format reference, see
[claude-code.md](./claude-code.md). Everything in that document applies verbatim
to MiniMax sessions.

MiniMax differs from Claude Code in exactly one dimension: the **Engram source
label** assigned at parse time. It is registered as a derived adapter:

```swift
ClaudeCodeDerivedSourceAdapter(source: .minimax, base: claudeCode)
```

(`SessionAdapterFactory.swift:13`, also `:58`). The derived adapter reuses the
shared `ClaudeCodeAdapter` base for enumeration and parsing, then keeps only the
sessions whose detected source equals `.minimax`.

---

## What differs from Claude Code

| Aspect | Value |
|---|---|
| Storage location | **Same** as Claude Code: `~/.claude/projects/` (no MiniMax-specific path) |
| Storage tech | **Same**: line-delimited JSONL, one file per session |
| File schema | **Same** Claude Code record/content-block schema — see [claude-code.md](./claude-code.md) |
| Engram source label | `minimax` (Swift enum `SourceName.minimax`, `SessionAdapter.swift:13`; display name "MiniMax", `SourceColors.swift:40`) |
| Detection signal | Model name (case-insensitive substring `minimax`) read from a `user`/`assistant` record |
| Storage-location nuance | **None.** `SourceCatalog.swift:26` lists `minimax` with `defaultPath: "~/.claude/projects"`, the same path as `claude-code` |

### The exact detection rule

A session is classified `minimax` iff its detected model string contains the
substring `minimax` (case-insensitive), and it is not first claimed by the
Lobster AI path check. The model is the first non-empty `message.model` found
while scanning `user`/`assistant` records.

Precedence (top-down, first match wins):

1. file path contains a `lobsterai` component → `lobsterai`
2. model is empty / starts with `claude` / starts with `<` → `claude-code`
3. lowercased model **contains** `minimax` → **`minimax`**
4. otherwise (e.g. qwen/kimi/gemini routed through a Claude-compatible client) → `claude-code`

Authoritative source (byte-for-byte parity between the two adapters):

```ts
// src/adapters/claude-code.ts:180-191
static detectSource(model: string, filePath?: string): SessionInfo['source'] {
  if (filePath && ClaudeCodeAdapter.hasLobsterAIPathComponent(filePath))
    return 'lobsterai';
  if (!model || model.startsWith('claude') || model.startsWith('<'))
    return 'claude-code';
  const m = model.toLowerCase();
  if (m.includes('minimax')) return 'minimax';   // ← the MiniMax rule
  return 'claude-code';
}
```

```swift
// macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:212-223
static func detectSource(model: String, filePath: String? = nil) -> SourceName {
    if let filePath, hasLobsterAIPathComponent(filePath) { return .lobsterai }
    if model.isEmpty || model.hasPrefix("claude") || model.hasPrefix("<") {
        return .claudeCode
    }
    let lowercased = model.lowercased()
    if lowercased.contains("minimax") { return .minimax }   // ← the MiniMax rule
    return .claudeCode
}
```

**Detection rule lives at:** `src/adapters/claude-code.ts:187` and
`macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:219`.

Confirmed model strings that match (from tests): `minimax-m1`
(`tests/adapters/claude-code.test.ts:122`, `EngramTests/AdapterParityTests.swift:101`)
and `minimax-text-01` (`EngramCoreTests/AdapterParityTests.swift:119`). The
rule is a substring match, so any model id containing `minimax` qualifies.

> **Freshness note (web-checked 2026-06-21):** the `minimax-m1` /
> `minimax-text-01` strings above are valid but predate the current official
> Claude Code integration. As of June 2026 the official MiniMax "Claude Code"
> setup doc sets `ANTHROPIC_MODEL="MiniMax-M3"` (with the M2.x series —
> `MiniMax-M2.5` / `MiniMax-M2.1` — also in use). All contain the substring
> `minimax`, so the detection rule still holds unchanged; the live official
> examples are simply `MiniMax-M3` / `MiniMax-M2.5` rather than the older
> fixtures. This is a freshness/example update, not a correctness error.
> ([source](https://platform.minimax.io/docs/token-plan/claude-code))

---

## Engram mapping

How a single Claude-format file resolves to `minimax` vs `claude-code`:

1. **Enumerate** — the derived adapter lists candidates via the shared base.
   `ClaudeCodeDerivedSourceAdapter.listSessionLocators()` →
   `base.listDerivedSessionLocators(source: .minimax)`
   (`ClaudeCodeAdapter.swift:600-602`, `:57-80`). The base does a cheap
   first-model "source hint" scan (up to 64 lines / 1 MB,
   `firstModelHint` `ClaudeCodeAdapter.swift:260-309`,
   `modelHint` checks top-level `model`, `message.model`, then `payload.model`
   `:322-333`) and keeps only locators whose hint equals `.minimax`. Results are
   cached per `(path, mtime, size)` signature
   (`ClaudeCodeSourceHintCache`, `:539-571`).

2. **Parse** — `parseSessionInfo` extracts `detectedModel` from the first
   `message.model` on a `user`/`assistant` record, then calls `detectSource`
   to set `source`.
   - TS: model capture `src/adapters/claude-code.ts:106-108`; classification
     `:146`.
   - Swift: model capture `ClaudeCodeAdapter.swift:123-125`; classification
     `:151`.

3. **Filter to source** — the derived adapter accepts the parse result only
   when `info.source == .minimax`, otherwise returns
   `.unsupportedVirtualLocator`
   (`ClaudeCodeDerivedSourceAdapter.parseSessionInfo`,
   `ClaudeCodeAdapter.swift:612-621`). This guarantees a single physical file is
   owned by exactly one source even though Claude + MiniMax + Lobster all share
   the base enumerator.

Streaming/transcript reads route MiniMax through the Claude-code path
(`MessageParser.swift:32`, `MCPTranscriptReader.swift:102,144`,
`TranscriptExportService.swift:333`), since the bytes are Claude format.

Every Claude Code field maps identically; the only field whose interpretation
changes is `message.model`, which feeds `detectSource`:

| Field | Type | Role for MiniMax | Example |
|---|---|---|---|
| `message.model` | string (optional) | First non-empty value on a `user`/`assistant` record; substring `minimax` (case-insensitive) → `source = minimax`; also stored as `SessionInfo.model` | `"minimax-m1"`, `"minimax-text-01"` |

Example assistant record (anonymized; structure verbatim, this is plain Claude
Code JSONL):

```json
{
  "type": "assistant",
  "sessionId": "<uuid>",
  "timestamp": "2026-04-29T10:00:01.000Z",
  "message": {
    "role": "assistant",
    "model": "minimax-m1",
    "content": [{ "type": "text", "text": "<assistant text>" }]
  }
}
```

---

## Gotchas

- **Detection is content-blind — it only reads the `model` field.** In the live
  store, `minimax` appears in many sessions, but only inside *user-message
  content text* (e.g. a prompt listing model SKUs like `MiniMax M3 / M2.x`).
  Those are **not** detected as MiniMax, because `detectSource` keys on
  `message.model`, never on message body text. Scanning the 5276 live
  `~/.claude/projects/*.jsonl` files found **zero** sessions with an actual
  MiniMax `message.model` field — so on this machine the `minimax` source
  currently yields no sessions, even though the substring is common in content.
- **Substring, not equality.** Any model id containing `minimax`
  (case-insensitive) classifies as MiniMax. A future Anthropic/third-party
  model whose id incidentally contained that substring would be mis-tagged.
- **First-model-wins / model mixing.** Classification uses the *first*
  non-empty `message.model` encountered. A file whose first model is `claude-*`
  but which later switches to a `minimax-*` model (or vice versa) is classified
  solely by that first model — mid-session model switches do not reclassify.
  Conversely, an early `minimax-*` line tags the whole file `minimax` regardless
  of later Claude lines.
- **Hint vs. parse can disagree on truncated files.** Enumeration uses a capped
  scan (64 lines / 1 MB). If the first 64 lines carry no `model` but a later
  line does, the hint may miss it; the authoritative `source` is always the one
  from the full `parseSessionInfo` pass. The derived adapter's post-parse
  `info.source == .minimax` filter is the final arbiter.
- **`claude` / `<` prefixes short-circuit before the MiniMax check.** A model
  starting with `claude` or `<` (placeholder) returns `claude-code` and never
  reaches the `minimax` branch.
- **Lobster AI path wins over model.** The path-based `lobsterai` check runs
  first; a MiniMax-model file located under a `lobsterai` project dir would be
  labeled `lobsterai`, not `minimax`.

---

## Open questions / web confirmation (resolved 2026-06-21)

The "detection overlay on Claude Code" framing and the substring-match
detection rule were checked against official MiniMax sources. Results:

- **Confirmed (official):** MiniMax is a Claude-Code-compatible runtime, not a
  standalone session store. MiniMax officially documents running its models
  *inside* Anthropic's Claude Code via an Anthropic-compatible endpoint — the
  setup page instructs users to set
  `ANTHROPIC_BASE_URL="https://api.minimax.io/anthropic"` (China:
  `https://api.minimaxi.com/anthropic`) and point `ANTHROPIC_MODEL` at a
  MiniMax model. Because MiniMax runs inside Claude Code via env-var overrides,
  sessions are written by Claude Code itself to `~/.claude/projects/` as
  ordinary Claude Code JSONL. MiniMax's own first-party CLI (`mmx-cli`) is a
  multimodal generation tool, not a coding-session store. This validates the
  "detection overlay, not a standalone format" claim.
  ([source](https://platform.minimax.io/docs/token-plan/claude-code),
  [source](https://github.com/MiniMax-AI/Mini-Agent/blob/main/README.md))
- **Confirmed (official):** every official MiniMax model identifier uses the
  `MiniMax-` prefix, which contains the case-insensitive substring `minimax`:
  `MiniMax-M3` (the model the official Claude Code doc sets `ANTHROPIC_MODEL`
  to), `MiniMax-M2.5` / `MiniMax-M2.1` (Anthropic-compatible coding models),
  `MiniMax-Text-01` and `MiniMax-VL-01` (the open-sourced MiniMax-01 series),
  and `MiniMax-M1` (open-source reasoning model). The substring-match detection
  rule on `message.model` therefore correctly classifies real, current official
  MiniMax models.
  ([source](https://platform.minimax.io/docs/token-plan/claude-code),
  [source](https://www.minimax.io/news/minimax-01-series-2))
- **Confirmed (official):** the doc's example strings `minimax-m1` and
  `minimax-text-01` are real official MiniMax model ids. `MiniMax-Text-01` is
  the foundational language model of the open-sourced MiniMax-01 series
  (announced 2025-01-15, alongside `MiniMax-VL-01`); `MiniMax-M1` is MiniMax's
  open-source hybrid-attention reasoning model (456B params, built on
  `MiniMax-Text-01`, variants `MiniMax-M1-40k` / `MiniMax-M1-80k`). Both are
  valid; both contain `minimax`. Caveat: they are earlier-generation ids — see
  the freshness note in [The exact detection rule](#the-exact-detection-rule).
  ([source](https://www.minimax.io/news/minimax-01-series-2),
  [source](https://venturebeat.com/ai/minimax-m1-is-a-new-open-source-model-with-1-million-token-context-and-new-hyper-efficient-reinforcement-learning))
- **Confirmed (official):** no MiniMax-specific on-disk session format exists.
  The documented Claude Code integration is purely env-var overrides
  (`ANTHROPIC_BASE_URL` + `ANTHROPIC_MODEL`) on top of Anthropic's Claude Code
  client, so the session bytes are written by Claude Code to
  `~/.claude/projects/` in standard Claude Code JSONL. MiniMax's separate tools
  (`mmx-cli`, the MiniMax MCP server) are generation/agent-skill tools, not
  transcript stores. This confirms the "identical to Claude Code, same
  `~/.claude/projects/`" claim.
  ([source](https://platform.minimax.io/docs/token-plan/claude-code),
  [source](https://github.com/MiniMax-AI/Mini-Agent/blob/main/README.md))
- **Confirmed (partial):** the `minimax` substring rule is theoretically
  over-broad (a future model whose id incidentally contains `minimax` would be
  mis-tagged — already noted under [Gotchas](#gotchas)). Official sources
  confirm the practical risk is low today: every MiniMax model uses the
  unambiguous `MiniMax-` prefix, and no major non-MiniMax model id is known to
  contain that substring. The rule is currently safe but, as the doc honestly
  notes, theoretically over-broad. (This is partly an Engram-internal design
  choice rather than a tool-format fact.)
  ([source](https://www.minimax.io/news/minimax-01-series-2),
  [source](https://platform.minimax.io/docs/token-plan/claude-code))

---

## References (official sources)

- [MiniMax API Docs — Claude Code (token-plan)](https://platform.minimax.io/docs/token-plan/claude-code)
- [MiniMax API Docs — M3 for AI Coding Tools](https://platform.minimax.io/docs/guides/text-ai-coding-tools)
- [MiniMax-AI/Mini-Agent (official repo, Anthropic-compatible API)](https://github.com/MiniMax-AI/Mini-Agent/blob/main/README.md)
- [MiniMax News — MiniMax-01 series open-sourced (MiniMax-Text-01 / MiniMax-VL-01)](https://www.minimax.io/news/minimax-01-series-2)
- [VentureBeat — MiniMax-M1 open-source model (based on MiniMax-Text-01)](https://venturebeat.com/ai/minimax-m1-is-a-new-open-source-model-with-1-million-token-context-and-new-hyper-efficient-reinforcement-learning)
- [MiniMax (official) on X — MiniMax-01 open-source announcement](https://x.com/MiniMax__AI/status/1879226391352549451)
