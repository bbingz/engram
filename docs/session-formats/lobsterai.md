# LobsterAI — On-Disk Session Format (Detection Overlay)

Last researched: 2026-07-24

> **Evidence basis:** adapter source (Swift + TypeScript) + adapter parity
> tests, cross-checked against **live on-disk data** on this machine:
> `~/.claude/projects/-Users-bing-lobsterai-project/` (1 directory; index only).
> A discrepancy between the live data and the adapter is flagged in
> [Gotchas](#gotchas).

## Overview

LobsterAI's interactive transcripts have **no on-disk format of their own.**
LobsterAI is built on the [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/sessions)
(`@anthropic-ai/claude-agent-sdk`, the same engine as Claude Code), which it runs
as a managed subprocess via its Cowork `coworkRunner.ts`
([AGENTS.md](https://github.com/netease-youdao/LobsterAI/blob/main/AGENTS.md);
[issue #139](https://github.com/netease-youdao/LobsterAI/issues/139) shows the
running stack invoking `@anthropic-ai/claude-agent-sdk/cli.js`). That is **why**
its transcripts inherit Claude Code's exact JSONL record/content-block schema and
the exact same location (`~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`):
the SDK writes them, not LobsterAI.

**Routing nuance:** LobsterAI's `CoworkEngineRouter` can dispatch to either the
Claude Agent SDK path (writes `~/.claude/projects` JSONL — the path Engram
indexes) **or** an OpenClaw engine (file-based memory in the OpenClaw working
directory, no `~/.claude/projects` JSONL). LobsterAI is also explicitly
multi-provider — it can switch between cloud APIs and local models (Ollama
running DeepSeek/Qwen) — so "no on-disk format of its own" holds specifically
for the Claude Agent SDK transcript path. LobsterAI additionally maintains its
own `lobsterai.sqlite` app store (see below). Either way this does not affect
Engram, which only indexes whatever Claude-Code-format JSONL is present.

For the complete field-by-field record, content-block, and tool-formatting
reference, see **[claude-code.md](./claude-code.md)** — it applies verbatim.
This document covers **only** what makes a session LobsterAI instead of Claude
Code, which is a **detection overlay** (a source label decided at parse time),
not a separate store, parser, schema, or directory.

In Engram the LobsterAI adapter is literally a thin wrapper around the Claude
Code adapter that keeps only the locators the Claude Code adapter classifies as
`.lobsterai`:

- `ClaudeCodeDerivedSourceAdapter(source: .lobsterai, base: claudeCode)`
  registered in
  `macos/.../Adapters/SessionAdapterFactory.swift:14` (and `:59`).
- The wrapper itself: `macos/.../Adapters/Sources/ClaudeCodeAdapter.swift:573`
  (`ClaudeCodeDerivedSourceAdapter`); it constrains itself to MiniMax/LobsterAI
  via `precondition(source == .minimax || source == .lobsterai)`
  (`ClaudeCodeAdapter.swift:578`) and defaults `projectsRoot` to
  `~/.claude/projects` (`ClaudeCodeAdapter.swift:585`).

## What differs from Claude Code

**The only difference is the source label, decided by a directory-path-component
rule.** A session is LobsterAI iff some path component of its `.jsonl` locator
is `lobsterai` (optionally a leading dot, optionally followed by a `._-`
separator and more text). Model name is **irrelevant** to LobsterAI detection
(LobsterAI sessions usually carry a `claude*` model).

| Aspect | Claude Code | LobsterAI |
|---|---|---|
| On-disk root | `~/.claude/projects/` | identical (same root) |
| Storage tech | per-session JSONL (`<uuid>.jsonl`) | identical |
| Record / content-block schema | see claude-code.md | identical |
| Subagents | `<session>/subagents/*.jsonl` | identical |
| Engram source label | `claude-code` | `lobsterai` ("Lobster AI") |
| Distinguished by | n/a | **project-dir name path component** |

Detection rule, by exact regex / equality check:

```
^(?:\.?lobsterai(?:$|[._-].*))$     (case-insensitive, per path component)
```

A component matches when it is exactly `lobsterai` / `.lobsterai`, or begins
with `lobsterai`/`.lobsterai` immediately followed by one of `.`, `_`, `-`.
A component that merely *contains* or *prefixes* the substring does **not**
match (see Gotchas).

| Match? | Example path component | Result |
|---|---|---|
| ✓ | `lobsterai` | `lobsterai` |
| ✓ | `.lobsterai` | `lobsterai` |
| ✓ | `lobsterai-project` | `lobsterai` |
| ✓ | `.lobsterai-project` | `lobsterai` |
| ✗ | `.lobsteraiproject` (no separator) | `claude-code` |
| ✗ | `notlobsterai-project` (prefix) | `claude-code` |

Where it lives (file:line in both adapters):

| Concern | Swift | TypeScript |
|---|---|---|
| `detectSource(model, filePath)` (path check first) | `ClaudeCodeAdapter.swift:212-213` | `claude-code.ts:180-183` |
| Path-component matcher | `hasLobsterAIPathComponent` `ClaudeCodeAdapter.swift:225-239` (string equality/`hasPrefix` set) | `hasLobsterAIPathComponent` `claude-code.ts:199-203` (regex above) |
| Locator-only hint (listing) | `detectSourceHint` `ClaudeCodeAdapter.swift:241-244` | n/a |
| Source enum entry | `SourceName.lobsterai` `SessionAdapter.swift:14` | `types.ts:14` |
| Display label / color | n/a (Swift `SourceColors`) | `views.ts:21` `'Lobster AI'`, `:41` `#f1c40f` |

**Storage-location nuance:** none. LobsterAI shares Claude Code's root, file
naming, JSONL format, and watcher path (`watcher.ts:48` lists `lobsterai`, but
it watches the same `~/.claude/projects/` tree). There is a separate native app
store named `lobsterai.sqlite` in LobsterAI's user-data directory, persisted via
`coworkStore.ts` / `SqliteStore`. Confirmed tables include `cowork_sessions`,
`cowork_messages`, `user_memories`, and `cowork_config`
([DeepWiki](https://deepwiki.com/netease-youdao/LobsterAI/4.2-session-management-and-ui)).
A `mcp_servers` table and the exact macOS path
`~/Library/Application Support/LobsterAI/lobsterai.sqlite` are plausible (the
public docs say only "in the user data directory", which on macOS Electron
resolves to `~/Library/Application Support/LobsterAI/`) but were **not** literally
confirmed in the public sources checked — treat them as unconfirmed. Either way
Engram does **not** read this store; only the Claude-Code-format JSONL transcripts
are indexed.

## Engram mapping

Classification happens once, at parse time, inside the shared Claude Code
parser; the LobsterAI wrapper just filters to the resulting label.

1. The Claude Code adapter lists every `.jsonl` (and `subagents/*.jsonl`)
   locator under `~/.claude/projects/`
   (`ClaudeCodeAdapter.swift:27-48`; Swift listing for derived sources:
   `listDerivedSessionLocators` `ClaudeCodeAdapter.swift:57-80`, which classifies
   each locator via `detectSourceHint` and keeps only matches for `source`).
2. For each session, `detectSource` runs the **path check before any
   model-based logic**: if a path component matches the LobsterAI rule →
   `lobsterai`; else fall through to model rules (`minimax` if model contains
   `minimax`, otherwise `claude-code`).
   - Swift: `ClaudeCodeAdapter.swift:212-223`
   - TypeScript: `claude-code.ts:180-191`
3. The wrapper keeps a session only if its parsed `source == .lobsterai`,
   otherwise returns `.unsupportedVirtualLocator`
   (`ClaudeCodeAdapter.swift:612-621`). This prevents the same file from being
   double-counted by both the base and derived adapters.
4. For UI grouping/health, LobsterAI is reported as **derived from
   `claude-code`** (`web.ts:931-934` `DERIVED_SOURCES`).

So `lobsterai` vs `claude-code` is decided entirely by
`detectSource` / `hasLobsterAIPathComponent`
(`ClaudeCodeAdapter.swift:212`+`225`, `claude-code.ts:180`+`199`). Everything
downstream (record parsing, message streaming, tiering) reuses the Claude Code
path unchanged.

## Gotchas

- **Substring is NOT a match — separator-bounded only.** The rule matches a
  *whole path component* that equals or starts with `lobsterai` + a `._-`
  separator. `notlobsterai-project` and `.lobsteraiproject` are explicit
  decoys that resolve to `claude-code` (asserted in
  `tests/adapters/claude-code.test.ts:84-166`).
- **LIVE-DATA DISCREPANCY (this machine):** the only on-disk LobsterAI-looking
  data is `~/.claude/projects/-Users-bing-lobsterai-project/`. Its name is a
  **cwd-encoded** dir (`/Users/bing/lobsterai/project` →
  `-Users-bing-lobsterai-project`), so `lobsterai` appears only as a substring
  of the encoded component `-Users-bing-lobsterai-project`, which is **not**
  separator-bounded. Therefore the current adapter classifies these sessions as
  **`claude-code`, not `lobsterai`.** Detection relies on a project *directory*
  literally named `lobsterai*`/`.lobsterai*`, which LobsterAI's cwd encoding
  does not always produce. (On disk reality wins: do not assume "dir contains
  lobsterai" ⇒ `lobsterai`.)
- **Index-only directory.** That live dir currently holds only
  `sessions-index.json` (a LobsterAI app index referencing
  `<sessionId>.jsonl` files that are no longer present). Engram indexes the
  `.jsonl` transcripts, not `sessions-index.json`; with no `.jsonl` files
  present, nothing is indexed from this dir.
- **Model mixing is harmless to detection.** LobsterAI sessions normally carry a
  `claude*` model, and the path check runs first, so the model never downgrades
  a true LobsterAI path. Conversely, a `claude*` model in a non-`lobsterai*`
  dir stays `claude-code` even if it was produced by LobsterAI.
- **MiniMax shares this exact overlay.** The same `ClaudeCodeDerivedSourceAdapter`
  and `detectSource` distinguish `minimax` (by model substring `minimax`) from
  `lobsterai` (by path) from `claude-code`. The `precondition`
  (`ClaudeCodeAdapter.swift:578`) restricts the wrapper to those two derived
  sources.
- **Swift vs TS implementation differ in form, not behavior.** Swift uses an
  explicit equality/`hasPrefix` set (`ClaudeCodeAdapter.swift:230-237`); TS uses
  one regex (`claude-code.ts:202`). Both accept the same `._-`-separated /
  leading-dot variants; keep them in sync if either changes.

## Web-confirmation status (web-checked 2026-06-21)

- **Confirmed (official):** LobsterAI is a Claude-Code-derived client that, via
  its Cowork `coworkRunner.ts` subprocess running the Claude Agent SDK, writes
  interactive sessions into Claude Code's store using Claude Code's exact JSONL
  schema and location (`~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`).
  The Claude Agent SDK is the same engine as Claude Code and writes sessions
  there automatically.
  [issue #139](https://github.com/netease-youdao/LobsterAI/issues/139),
  [DeepWiki: Cowork System](https://deepwiki.com/netease-youdao/LobsterAI/4-cowork-system),
  [Claude Agent SDK — sessions](https://code.claude.com/docs/en/agent-sdk/sessions)
- **Confirmed (official):** the cwd-encoding rule (every non-alphanumeric
  character of the absolute cwd replaced by `-`, so `/Users/me/proj` →
  `-Users-me-proj`) is real, validating the live-data gotcha that
  `-Users-bing-lobsterai-project` is a cwd-encoded dir for
  `/Users/bing/lobsterai/project` (so `lobsterai` is only an internal substring,
  not a separator-bounded component, and these sessions classify as
  `claude-code`).
  [Claude Agent SDK — sessions](https://code.claude.com/docs/en/agent-sdk/sessions)
- **Confirmed (official):** "Lobster AI" as a display label is accurate, and
  LobsterAI is a real, identifiable product — an open-source Electron + React
  desktop AI agent by NetEase Youdao (`netease-youdao/LobsterAI`, open-sourced
  Feb 2026) whose Cowork mode runs the Claude Agent SDK.
  [repo](https://github.com/netease-youdao/LobsterAI),
  [allclaw.org](https://allclaw.org/entry/lobsterai)
- **Confirmed (partial, official):** LobsterAI sessions usually carry a `claude*`
  model — it defaults to Anthropic Claude (OpenClaw-derived engine defaults to
  `anthropic/claude-sonnet-4-6`, with `anthropic/claude-opus-4-6` available) and
  ships a built-in Claude runtime adapter. But it is explicitly multi-provider
  (cloud APIs or local Ollama running DeepSeek/Qwen), so `claude*` is a tendency,
  not a guarantee. Harmless to Engram detection, which is path-based, not
  model-based.
  [AGENTS.md](https://github.com/netease-youdao/LobsterAI/blob/main/AGENTS.md),
  [openclawai.net](https://openclawai.net/blog/lobster-ai-youdao-desktop-agent)
- **Confirmed (partial, official):** LobsterAI keeps a separate SQLite app store
  named `lobsterai.sqlite` (via `coworkStore.ts` / `SqliteStore`) with tables
  `cowork_sessions`, `cowork_messages`, `user_memories`, and `cowork_config`.
  The `mcp_servers` table and the exact path
  `~/Library/Application Support/LobsterAI/lobsterai.sqlite` were **not**
  literally confirmed in the public sources checked (docs say only "in the user
  data directory"); treat them as plausible-but-unconfirmed. "Engram does not
  read it" is an Engram design statement, not a web-verifiable LobsterAI fact.
  [DeepWiki: Cowork System](https://deepwiki.com/netease-youdao/LobsterAI/4-cowork-system),
  [DeepWiki: Session Management and UI](https://deepwiki.com/netease-youdao/LobsterAI/4.2-session-management-and-ui)
- **Engram-internal design — not web-verifiable:** the detection/classification
  specifics (the regex shape, `hasLobsterAIPathComponent`, the
  `ClaudeCodeDerivedSourceAdapter` MiniMax/LobsterAI `precondition`,
  `DERIVED_SOURCES` grouping, and `unsupportedVirtualLocator` double-count
  prevention) describe Engram's own adapter code, not LobsterAI's on-disk format,
  so they are not web-answerable from LobsterAI sources. Their only
  externally-grounded dependency — the Claude Agent SDK cwd encoding — is
  confirmed above.
  [Claude Agent SDK — sessions](https://code.claude.com/docs/en/agent-sdk/sessions)

## References (official sources)

- [netease-youdao/LobsterAI — official GitHub repo](https://github.com/netease-youdao/LobsterAI)
- [LobsterAI AGENTS.md — engine routing + SQLite storage](https://github.com/netease-youdao/LobsterAI/blob/main/AGENTS.md)
- [LobsterAI issue #139 — confirms `@anthropic-ai/claude-agent-sdk/cli.js` subprocess](https://github.com/netease-youdao/LobsterAI/issues/139)
- [DeepWiki: LobsterAI Cowork System (`coworkRunner.ts` / `coworkStore.ts` / `SqliteStore`)](https://deepwiki.com/netease-youdao/LobsterAI/4-cowork-system)
- [DeepWiki: LobsterAI Session Management and UI (`cowork_sessions` / `cowork_messages` tables)](https://deepwiki.com/netease-youdao/LobsterAI/4.2-session-management-and-ui)
- [Claude Agent SDK — Work with sessions (`~/.claude/projects/<encoded-cwd>/*.jsonl` + cwd encoding rule)](https://code.claude.com/docs/en/agent-sdk/sessions)
- [allclaw.org — LobsterAI entry](https://allclaw.org/entry/lobsterai)
- [openclawai.net — LobsterAI (Youdao desktop agent)](https://openclawai.net/blog/lobster-ai-youdao-desktop-agent)
