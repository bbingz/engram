# VS Code (Copilot Chat) — Session Storage Format

Last researched: 2026-07-01 (official microsoft/vscode source recheck +
Engram session-format workflow); adapter replay and cwd fallback behavior
verified: 2026-07-01.

> **Scope.** This document describes how the **VS Code Copilot Chat / Agent
> extension** (the chat panel *inside* the stable VS Code editor) persists chat
> sessions, and how Engram's `vscode` adapter consumes them. This is **NOT** the
> GitHub Copilot CLI (`~/.copilot/session-state`, `events.jsonl` +
> `workspace.yaml`) — that is a separate product and a separate adapter
> (`tests/fixtures/copilot/`). See [§15 Lineage](#15-lineage-gotchas-version-drift--edge-cases).

---

## Evidence basis

| Basis | Detail |
|---|---|
| **Live store** (primary for layout/lifecycle) | `~/Library/Application Support/Code/User/workspaceStorage/` — **19 workspace dirs** (machine-state, not load-bearing), **4** of which contain a `chatSessions/` folder, holding **5 `*.jsonl` chat-session files**. **All 5 live sessions are empty stubs** (`requests: []`; current `.jsonl` snapshots do **not** carry top-level `isEmpty`). One file (`cea0313a…`) has **2 lines** (a `kind:0` snapshot + a `kind:1` patch); the other 4 are single-line. `state.vscdb` (SQLite) present per workspace. |
| **Repo fixtures** (primary for populated `requests[]`) | `tests/fixtures/vscode/ws-abc123/` — 1 session `sess-001.jsonl` with **2 populated requests** + `workspace.json`. Identical copy under `tests/fixtures/adapter-parity/vscode/input/`, with golden output `success.expected.json`. This is the only populated-turn sample available on this machine. |
| **Adapters** (codified knowledge) | Swift product parser `macos/Shared/EngramCore/Adapters/Sources/VsCodeAdapter.swift`; TS reference `src/adapters/vscode.ts`. Both replay valid ObjectMutationLog entries after the initial snapshot and use session `workingDirectory` as a cwd fallback when `workspace.json` yields no local path. Tests: `tests/adapters/vscode.test.ts`, `AdapterMessageCountTests.testVsCodeReplaysAppendMutationLog`, `AdapterMessageCountTests.testVsCodeUsesSessionWorkingDirectoryWhenWorkspaceJsonMissing`. |

**Which basis wins, by layer:**
- **Directory/naming/lifecycle/SQLite/patch-line layer → live data wins** (verified on disk).
- **Populated request/response schema layer → fixture + adapter typings** (no live session has a non-empty `requests[]`).

**Discrepancies found vs the dimension reports (live data wins, flagged inline):**
1. `state.vscdb` schema is `CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)` — **not** `PRIMARY KEY` as one report claimed.
2. The `kind:1` patch line's `k` field is a **JSON array** (`["inputState"]`), **not** a string keypath as one report inferred.
3. Workspace-dir count is machine-state and **not load-bearing** for the format. Live store currently has **19** workspace dirs (verified: `python3` glob of `workspaceStorage/*` → 19 dirs, 5 `*.jsonl` across 4 `chatSessions/` dirs). The "19" reading is correct; any earlier "21" figure was stale.

---

## 1. Overview & TL;DR

**What/where/how.** VS Code's Copilot Chat extension writes **one file per chat
session** under each workspace's storage dir. Each file is a single self-contained
JSON object (the whole session) on **line 0**, with the cosmetic `.jsonl`
extension. Subsequent lines (when present) are incremental `kind:1` patches that
VS Code replays to rebuild current state. A sibling **`state.vscdb` SQLite** file
holds a derived session *index* (titles, timing, empty-flag) for the UI; a sibling
**`workspace.json`** maps the workspace to a filesystem folder (Engram's primary
source of `cwd`; session `workingDirectory` is the fallback). Edit history lives
in a parallel `chatEditingSessions/` tree.

**Mental model:** the `.jsonl` files are the **content of record**; `state.vscdb`
is a **derived catalog**; `workspace.json` is the **identity sidecar**. Engram
reads and replays the valid ObjectMutationLog entries in each `.jsonl`, reads
`workspace.json`, then falls back to `v.workingDirectory` if the sidecar cannot
yield a local cwd; it never opens the SQLite DB or the edit tree.

```
~/Library/Application Support/Code/User/workspaceStorage/
│
├── <workspace-id>/                      ┐ one dir per VS Code workspace
│   ├── workspace.json                   │  identity → cwd   [READ, primary]
│   ├── state.vscdb        (SQLite)      │  session index    [IGNORED]
│   ├── state.vscdb.backup (SQLite)      │  hot backup       [IGNORED]
│   ├── chatSessions/                    │  ← ADAPTER TARGET
│   │   └── <session-uuid>.jsonl         │    line0=kind:0 snapshot  [REPLAYED]
│   │                                    │    line1+=kind:1/2/3 mutations [REPLAYED]
│   └── chatEditingSessions/             │  edit snapshots   [IGNORED]
│       └── <session-uuid>/              │    (same UUID as the chat session)
│           ├── state.json (version 2)   ┘
│           └── contents/   (blob dir, often empty)
│
   Engram pipeline:  enumerate *.jsonl → replay mutation log from kind:0 state
                     → require requests non-empty & creationDate present
                     → climb 2 dirs up → read workspace.json → fallback to v.workingDirectory
                     → emit {user, assistant} text pairs
```

**TL;DR for Engram:** `id ← v.sessionId`, `startTime ← v.creationDate`,
`endTime ← last request timestamp`, `cwd ← workspace.json ∥ v.workingDirectory`,
messages = `{user text, first markdownContent block}` pairs. **No model, no tokens, no tool calls,
no system messages.** Empty sessions (the live norm here) are rejected. On this
machine the adapter would index **0** VS Code sessions despite 5 files existing.

---

## 2. On-disk layout & file naming

**Authoritative root** (Swift `VsCodeAdapter.swift:9-11`; TS `vscode.ts:41-48`):

```
~/Library/Application Support/Code/User/workspaceStorage/
```

`Code - Insiders/User/workspaceStorage/` uses the **identical** format but the
default adapter root points only at stable `Code/` — Insiders is **not covered**
([§15](#15-lineage-gotchas-version-drift--edge-cases)). On the 2026-07-01
recheck, `~/Library/Application Support/Code - Insiders/User/workspaceStorage`
is not present on this machine, so the Insiders coverage gap is format-level and
not currently backed by local chat files.

**Directory structure:**

```
workspaceStorage/
  <workspace-id>/
    workspace.json              # workspace → folder mapping (primary cwd source) [READ]
    state.vscdb                 # SQLite UI/index state                     [NOT read]
    state.vscdb.backup          # SQLite hot backup                         [NOT read]
    chatSessions/               # ← adapter target
      <session-uuid>.jsonl      # one chat session, payload on line 0
      <session-uuid>.jsonl
    chatEditingSessions/        # paired edit history                       [NOT read]
      <session-uuid>/           # SAME UUID as the chat session (1:1)
        state.json              # edit timeline (version 2)
        contents/               # file-snapshot blobs (often empty)
```

**Naming grammar:**

| Token | Grammar | Live examples |
|---|---|---|
| `<workspace-id>` | EITHER a 32-char lowercase hex hash (MD5 of the workspace URI) OR a numeric timestamp-ms string | hex: `a869823f8fa74cc87f120cdcb5be6bb8`, `395a8c5152c24172f4854c792bd2b32f`; numeric: `1772874866399`, `1781946123322` |
| `<session-uuid>` | RFC-4122 v4 UUID, lowercase, `.jsonl` extension | `5e2c51cc-3e7a-42b9-a239-2d3bb4e30694.jsonl`, `cea0313a-2e97-477f-83aa-850a5f9faad1.jsonl` |
| `chatEditingSessions/<session-uuid>/` | dir named with the **same UUID** as its chat session (1:1 pairing) | `chatEditingSessions/5e2c51cc-3e7a-42b9-a239-2d3bb4e30694/` |

The `.jsonl` extension is a **misnomer** in the chat-message sense: line 0 is
the initial session object, and later lines are ObjectMutationLog entries, not
independent chat-message records. Both adapters replay valid mutation entries
after line 0 (Swift `readSession`/`replayMutationLog` `:140-180`; TS
`readSession`/`replayMutationLog` `:220-277`).

**Live tree (anonymized):**

```
workspaceStorage/
├── a869823f8fa74cc87f120cdcb5be6bb8/
│   ├── workspace.json                  # {"folder":"file:///Users/<user>/<proj>"}
│   ├── state.vscdb                     # SQLite, 53 KB
│   ├── state.vscdb.backup              # SQLite, 53 KB
│   ├── chatSessions/
│   │   ├── 5e2c51cc-3e7a-42b9-a239-2d3bb4e30694.jsonl   # 524 B, 1 line (empty)
│   │   └── cea0313a-2e97-477f-83aa-850a5f9faad1.jsonl   # 545 B, 2 lines (kind:0 + kind:1)
│   └── chatEditingSessions/
│       ├── 5e2c51cc-3e7a-42b9-a239-2d3bb4e30694/
│       │   ├── state.json              # version 2
│       │   └── contents/               # (empty)
│       └── cea0313a-2e97-477f-83aa-850a5f9faad1/
│           ├── state.json
│           └── contents/
├── 1772874866399/                      # numeric workspace-id, no chatSessions/
└── 3011e0800a82af49da1596d7bbbf8a16/
    └── workspace.json                  # {"workspace":"file:///.../Code/Workspaces/.../workspace.json"}  ← legacy key
```

---

## 3. File lifecycle & generation

- **Storage tech:** per-session JSON file (cosmetic `.jsonl`), NOT SQLite for the
  conversation body. SQLite (`state.vscdb`) holds only a derived index.
- **One file per session, rewritten in place (NOT append-only at the conceptual
  level).** Line 0 is a full snapshot of `v`; VS Code re-serializes it on save.
  Lines 1..N are incremental ObjectMutationLog entries (`kind:1` set,
  `kind:2` push/splice, `kind:3` delete) that VS Code can append and later fold
  back into the snapshot. Both adapters now replay those valid mutation entries.
- **File creation:** a new `chatSessions/<uuid>.jsonl` (+ matching
  `chatEditingSessions/<uuid>/`) appears when a chat panel is opened in a
  workspace. Empty sessions persist even with no turns; in current `.jsonl`
  snapshots the decisive marker is `requests: []`, while `isEmpty` lives in the
  derived `state.vscdb` index — **all 5 live sessions are empty by this marker**.
- **DB vs file split:** `.jsonl` = content of record; `state.vscdb`
  (`chat.ChatSessionStore.index`) = derived index (titles, timing, empty flag);
  `state.vscdb.backup` = hot SQLite backup. The adapter intentionally bypasses the
  DB and reads files directly — resilient to DB corruption, but unable to use the
  DB's `title`/`isEmpty` metadata.
- **Resume:** continuing a chat re-opens the same `<uuid>.jsonl`, adds a request to
  `v.requests`, and rewrites line 0. `creationDate` is stable; `endTime` tracks the
  last request's `timestamp`.
- **Rollover:** none — no size-based splitting. A long conversation grows one file.
- **Edit history:** `chatEditingSessions/<uuid>/state.json` (`version: 2`, fields
  `version`, `initialFileContents`, `timeline`, `recentSnapshot`) plus a
  `contents/` blob dir track agent file edits. Independent lifecycle; adapter
  ignores it entirely.
- **Archive/deletion:** deleting a chat removes the `.jsonl` and its
  `chatEditingSessions/<uuid>/`, and drops the entry from
  `chat.ChatSessionStore.index`. No tombstones in the file layer.

**How Engram enumerates** (pure filesystem, no SQLite, no manifest):
1. **Detect** (Swift `detect()` `:18-20`; TS `:51-58`): `workspaceStorage/` exists.
2. **Enumerate** (Swift `listSessionLocators()` `:22-36`; TS `listSessionFiles()`
   `:60-74`): for each direct child dir, check `<child>/chatSessions/`; collect
   every file with `.jsonl` extension. TS uses glob `*/chatSessions/*.jsonl`; Swift
   iterates direct children and filters `pathExtension == "jsonl"`, then sorts.
3. **Parse** (`parseSessionInfo`): replay the ObjectMutationLog into current
   state; reject if `requests` is empty or `creationDate` is missing
   (Swift `:40-48`; TS `:76-115`).
4. **cwd resolution:** climb two dirs up (`<uuid>.jsonl` → `chatSessions/` →
   `<id>/`), read `workspace.json`, decode `folder`/`configuration` URIs, then
   fall back to `v.workingDirectory` if the sidecar yields no local path.
5. **Message stream** (`streamMessages`): iterate `v.requests`; emit a `user`
   message from `message.text`/`parts`, then an `assistant` message from the first
   `response[].value.kind === "markdownContent"` block. `toolMessageCount` /
   `systemMessageCount` hardcoded `0`.

---

## 4. Record / line taxonomy

The `.jsonl` file is a snapshot + mutation-log. Engram replays valid mutation
entries after the initial snapshot, so later lines can affect parsed messages.

| Line `kind` | Record type | Top-level fields | Meaning | Engram use |
|---|---|---|---|---|
| `0` | **Initial snapshot** | `kind:0`, `v:{…}` (full session object — see [§5](#5-shared-envelope--metadata-fields)/[§6](#6-message--content-schema)) | Initial full-session serialization | **Parsed as starting state** |
| `1` | **Set** | `kind:1`, `k:[…keypath…]`, `v:<value>` | Sets the value at JSON keypath array `k` (e.g. replaces `inputState`) | **Replayed** |
| `2` | **Push/splice** | `kind:2`, `k:[…keypath…]`, `v:[…values…]`, optional `i:<startIndex>` | Appends values at a JSON keypath, truncating to `i` first when present | **Replayed** |
| `3` | **Delete/unset** | `kind:3`, `k:[…keypath…]` | Removes/unsets the value at a JSON keypath | **Replayed** |

> **Corrected vs DIM reports:** `k` is a **JSON array** of path segments
> (`["inputState"]`), verified live — not a string.

The TS adapter's tolerance for invalid or unknown trailing entries is explicitly
tested: `tests/adapters/vscode.test.ts:58-104` writes an invalid line plus an
unknown `kind:99` entry and asserts the initial snapshot still parses. Swift is
stricter at the JSONL reader layer and returns `.malformedJSON` for malformed
JSON lines; both Swift and TS replay valid `kind:1/2/3` entries.

---

## 5. Shared envelope / metadata fields

### 5a. Record-layer wrapper (line 0)

| Field | Type | Meaning | Optionality | Example |
|---|---|---|---|---|
| `kind` | int | Record-kind discriminator; adapter requires `0` to accept the file | required | `0` |
| `v` | object | The full session payload | required | `{ "version": 3, … }` |

### 5b. `v` — session payload (live `version: 3`)

All fields verified across the 5 live stubs; types/optionality verbatim.

| Field | Type | Meaning | Optionality | Engram reads? | Example (anon) |
|---|---|---|---|---|---|
| `version` | int | Schema version of the chat-session format. Live + fixture both `3`. | required | No (typed in TS `VsSessionData`, never branched) | `3` |
| `sessionId` | string (UUID) | Stable session id; matches filename | required | **Yes → `id`** (fallback: filename stem) | `"5e2c51cc-3e7a-42b9-a239-2d3bb4e30694"` |
| `creationDate` | int (epoch **ms**) | Session start | required (Swift hard-fails if missing) | **Yes → `startTime`** | `1771392503565` |
| `requests` | array<VsRequest> | Ordered turn-pairs | required (may be `[]`; empty → rejected) | **Yes → messages/counts** | `[]` (live) / 2 entries (fixture) |
| `initialLocation` | string enum | Where chat opened: `"panel"` (also `"editor"`, `"terminal"`, `"notebook"`, `"editing-session"`) | present | No | `"panel"` |
| `responderUsername` | string | Assistant display name (`""`, `"GitHub Copilot"`, `"Gemini"`…) | present | No (provenance signal lost) | `""` |
| `requesterUsername` | string | User identity | sometimes absent | No | `null` |
| `hasPendingEdits` | bool | Unapplied agent edits exist | present | No | `false` |
| `pendingRequests` | array | In-flight turns not yet completed | present | No | `[]` |
| `inputState` | object | Persisted composer/input box draft state | optional (may be absent on line-0 when carried by a later `kind:1` patch — verified live on `cea0313a…`, whose line-0 `v` omits it while line-1 `{"kind":1,"k":["inputState"]}` carries it; the other 4 live stubs include it on line 0) | No | see below |
| `workingDirectory` | string URI | Current official schema persists the model working directory as a URI string; not present in the 5 local empty stubs | optional | **Yes → `cwd` fallback** | `"file:///Users/<user>/<proj>"` |
| `repoData` | object | Repository metadata persisted by current official schema; not present in the 5 local empty stubs | optional | No | `null` |
| `customTitle` | string | User-renamed session title | optional | No (title from first user msg) | `null` |
| `isImported` | bool | Imported from another tool | optional | No | `null` |

`inputState` sub-object (verified live):

| Field | Type | Meaning | Example |
|---|---|---|---|
| `attachments` | array | Attached context items (files/selections) | `[]` |
| `mode` | object \| null | Active chat mode (one live file had `mode: null`) | `{"id":"agent","kind":"agent"}` |
| `mode.id` / `mode.kind` | string | Mode id/kind | `"agent"` (also observed: `"ask"`, `"edit"`) |
| `inputText` | string | Draft text in composer | `""` |
| `selections` | array<object> | Editor selection ranges (1-based line/col); fields `startLineNumber`, `startColumn`, `endLineNumber`, `endColumn`, `selectionStartLineNumber`, `selectionStartColumn`, `positionLineNumber`, `positionColumn` | `[{"startLineNumber":1,…,"positionColumn":1}]` |
| `contrib` | object | Contributed input-model state | `{"chatDynamicVariableModel":[]}` |

The current official `inputState` schema also includes `selectedModel` and
`permissionLevel`; they were not present in the 5 local empty stubs on the
2026-07-01 recheck.

> Engram reads `sessionId`, `creationDate`, `requests` from `v` (plus `version`
> implicitly). It also reads `workingDirectory` only as a fallback for `cwd` when
> `workspace.json` does not resolve to a local path. It does **not** read
> `initialLocation`, `inputState`, `mode`, `selectedModel`, `permissionLevel`,
> `responderUsername`, `requesterUsername`, `hasPendingEdits`, `repoData`,
> `pendingRequests`, `customTitle`, or `isImported`. Model and token/usage are
> **absent at the session level**.

---

## 6. Message & content schema

### Layer A — `requests[i]` (turn object)

Each element is **one user→assistant turn**; user prompt and full assistant
response are co-located (there is NOT a separate per-role top-level record).

| Field | Type | Meaning | Optionality | Engram reads? | Example |
|---|---|---|---|---|---|
| `requestId` | string | Turn id | required | No | `"req-1"` |
| `message` | object | The **user** prompt (Layer B) | required | **Yes → user text** | `{"text":"…","parts":[…]}` |
| `response` | array<object> | Ordered **assistant** response parts (Layer C) | required | **Yes → first markdown only** | `[{"value":{…}}]` |
| `timestamp` | int (epoch **ms**) | Turn time | optional | **Yes → per-msg ts; last → `endTime`** | `1771392005000` |
| `result` | object | Turn result (errors, metadata) | optional (real VS Code) | No | `{"errorDetails":{…},"metadata":{…}}` |
| `followups` | array | Suggested follow-up prompts | optional (real VS Code) | No | `[{"kind":"reply","message":"…"}]` |
| `isCanceled` | bool | User canceled the turn | optional (real VS Code) | No | `false` |
| `agent` / `slashCommand` | object | Participant/agent + `/command` invoked | optional (real VS Code) | No | `{"id":"github.copilot.default",…}` |
| `variableData` | object | Resolved `#`/`@` context variables | optional (real VS Code) | No | `{"variables":[…]}` |
| `modelId` | string | Model used for the turn | optional (real VS Code) | No | `"gpt-4o"` |

> The four fields Engram knows (`requestId`, `message`, `response`, `timestamp`)
> are verified from the fixture. The rest (`result`, `followups`, `isCanceled`,
> `agent`, `variableData`, `modelId`) are the real-VS-Code superset from
> source/web + adapter comments — **not present in this machine's empty data**.

### Layer B — user content blocks: `requests[i].message`

| Field | Type | Meaning | Optionality | Example |
|---|---|---|---|---|
| `text` | string | Flattened plain-text prompt (preferred extraction path) | optional | `"How do I use async/await in TypeScript?"` |
| `parts` | array<{kind,value}> | Structured prompt segments | optional | see below |
| `parts[].kind` | string | Part type: `"text"` (real VS Code also `"reference"`, `"dynamic"`/`#file`, `"slash"`, `"image"`) | — | `"text"` |
| `parts[].value` | string | Part text (for `kind:"text"`) | — | `"How do I use async/await in TypeScript?"` |

**Extraction order** (`extractUserText`, Swift `:203-218`; TS `:236-244`): prefer
`message.text` if non-empty; else first `parts[]` with `kind == "text"` and
non-empty `value`; else `""` (turn contributes no user message).

### Layer C — assistant response blocks: `requests[i].response[]`

`response` is an ordered array of streamed parts, each wrapped as
`{ "value": { "kind": <part-type>, … } }`. A turn typically holds many parts
(progress, tool calls, then markdown). **Engram extracts only the first
`markdownContent` part's text** and ignores all other kinds (`extractAssistantText`,
Swift `:220-233`; TS `:246-253`).

| `value.kind` | Part type | Key nested fields | In live data? | Engram |
|---|---|---|---|---|
| `markdownContent` | Rendered assistant prose/code | `content.value` (markdown string) | **fixture** | **Parsed** (first one wins) |
| `progressTask` / `progressMessage` | Streaming progress / "working…" | `content`, task state | adapter-only | Ignored |
| `toolInvocationSerialized` (a.k.a. `toolUse`) | **Tool call + result, co-located** | `toolId`, `toolCallId`, `invocationMessage`, `pastTenseMessage`, `isComplete`, `resultDetails` | adapter-only | Ignored |
| `inlineReference` / `reference` | Code/file citation | `inlineReference` (uri+range) | adapter-only | Ignored |
| `codeblockUri` | URI tag for a following code block | `uri`, `isEdit` | adapter-only | Ignored |
| `textEditGroup` | Applied file edits (agent edits) | `uri`, `edits[]`, `done` | adapter-only | Ignored |
| `command` / `confirmation` | Button / confirmation prompt | `command`, `title`, `data` | adapter-only | Ignored |
| `warning` / `error` | Inline warning/error block | `content` | adapter-only | Ignored |

**Anonymized populated request (fixture `sess-001.jsonl`):**

```json
{
  "requestId": "req-1",
  "message": {
    "text": "<user prompt text>",
    "parts": [{ "kind": "text", "value": "<user prompt text>" }]
  },
  "response": [
    { "value": { "kind": "markdownContent", "content": { "value": "<assistant markdown>" } } }
  ],
  "timestamp": 1771392005000
}
```

---

## 7. Tool calls & results

**N/A for Engram extraction — present in format, dropped on read.** Within VS
Code, a tool call and its result are **fused into a single
`toolInvocationSerialized` part** (it holds both the invocation message and
`resultDetails`/`isComplete`). There is **no separate `tool_result` record keyed
by id** as in Anthropic/OpenAI logs — call↔result linkage is intrinsic to the one
part. Engram captures **none** of this: response parts with
`value.kind == "toolInvocationSerialized"|"toolUse"` are silently skipped,
`toolCalls` is always `nil`/`[]`, and `toolMessageCount` is hardcoded `0` (Swift
`:69,113,125`; TS `:107`). A turn whose response is entirely a tool call yields no
assistant message and is excluded from counts (commented TS `:85-89`).

> Not sampled from live data (all live sessions empty); documented from VS Code
> source/web + adapter comments.

---

## 8. Reasoning / thinking

**N/A.** No dedicated thinking/reasoning part appears in this machine's data, and
VS Code historically does not serialize a distinct reasoning block — assistant
prose lives in `markdownContent`. Even if a reasoning part existed, Engram would
ignore it (only `markdownContent` is extracted).

---

## 9. Token usage & cost

**N/A — VS Code stores none at any level reachable by the adapter.** There is no
`usage`/token field at session, request, or response-part level in live data or
fixture. Engram emits `usage: nil` per message (Swift `:114,125`) and the parity
golden's `usageTotals` is all-zero (`inputTokens`/`outputTokens`/
`cacheCreationTokens`/`cacheReadTokens` = `0`). No cost is derivable.

---

## 10. Subagent / parent-child / dispatch

**N/A.** VS Code Copilot Chat has no parent-child session linkage in this format
(no Gemini-style `.engram.json` sidecar, no path-based subagent nesting). The
adapter sets `parentSessionId`, `suggestedParentId`, `agentRole`, `originator`,
and `origin` all to `nil` (Swift `:74-82`). Parent-detection layers operate
downstream in Engram core, not in this adapter.

> Note: a single workspace can host *multiple chat backends* (live `state.vscdb`
> shows both `workbench.panel.chat` (Copilot) and
> `workbench.view.extension.geminiChat.state` (Gemini) keys), all writing the
> same `chatSessions/*.jsonl` format. The `responderUsername` field would
> disambiguate them, but Engram discards it — see [§15](#15-lineage-gotchas-version-drift--edge-cases).

---

## 11. Summary / compaction

**N/A in-format.** VS Code does not store a compacted/summary turn type that
Engram consumes. Engram synthesizes its own `summary` field = the first non-empty
user text sliced to 200 chars (Swift `:71`; TS `:109`). It does **not** use the
ready-made `title` from `state.vscdb`'s `chat.ChatSessionStore.index` (a fidelity
gap, not a schema error).

---

## 12. SQLite / DB internals — `state.vscdb`

VS Code is a DB-backed tool for its *index*, but the transcript is file-backed.
Per-workspace `state.vscdb` is a generic key/value store. **Engram does not read
it** — it is the authoritative session catalog, documented here for completeness.

**Schema (verified live):**

```sql
CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
```

> **Corrected vs DIM 2:** the key column is `TEXT UNIQUE ON CONFLICT REPLACE`,
> **not** `PRIMARY KEY`. `value` is `BLOB` (holds JSON text).

**Chat-related keys found live** (in workspace `a869…`):

| Key | Holds |
|---|---|
| `chat.ChatSessionStore.index` | **Session index** — per-session metadata map (below) |
| `memento/interactive-session-view-copilot` | Last active session id + composer/input state |
| `chat.untitledInputState` | Draft input for the untitled (new) chat |
| `chat.customModes` | User-defined custom chat modes |
| `workbench.panel.chat` | Copilot chat panel UI state |
| `workbench.panel.chat.numberOfVisibleViews` | Panel layout count |
| `workbench.view.extension.geminiChat.state` | Gemini chat extension view state (coexisting backend) |
| `workbench.view.extension.geminiOutline.state` | Gemini outline view state |

**`chat.ChatSessionStore.index` value** — `{ version, entries: { <uuid>: {…} } }`:

| Entry field | Type | Meaning | Example (anon) |
|---|---|---|---|
| `sessionId` | string | Session UUID (= `.jsonl` filename) | `"cea0313a-2e97-477f-83aa-850a5f9faad1"` |
| `title` | string | Human title VS Code shows (`"New Chat"` until first prompt) | `"<REDACTED>"` |
| `lastMessageDate` | int (ms) | Last activity time | `1772112775137` |
| `timing` | object `{created:int}` | Creation timing | `{"created":1772112775137}` |
| `initialLocation` | string enum | Open location | `"panel"` |
| `hasPendingEdits` | bool | Pending edits flag | `false` |
| `isEmpty` | bool | True when `requests` is empty (matches all 5 live sessions) | `true` |
| `isExternal` | bool | External (remote/agent) origin | `false` |
| `lastResponseState` | int enum | Last response status code | `1` |

---

## 13. Auxiliary files

| File / dir | Tech | Purpose | Engram |
|---|---|---|---|
| `workspace.json` | JSON | Workspace identity → primary `cwd` source (the only sidecar Engram reads) | **READ** |
| `state.vscdb` | SQLite | Session index, panel/draft state ([§12](#12-sqlite--db-internals--statevscdb)) | NOT read |
| `state.vscdb.backup` | SQLite | Hot backup of `state.vscdb` | NOT read |
| `chatEditingSessions/<uuid>/state.json` | JSON (`version: 2`; keys `version`, `initialFileContents`, `timeline`, `recentSnapshot`) | Agent file-edit timeline for the session | NOT read |
| `chatEditingSessions/<uuid>/contents/` | opaque blobs | File-snapshot blobs for edit undo (often empty) | NOT read |

**cwd resolution** (Swift `readCwd` / `readWorkspaceCwd` `:55,260-289`; TS `:94-96,128-166`):

| Key | Type | Meaning | Adapter handles? | Live example (anon) |
|---|---|---|---|---|
| `folder` | string (`file://` URI) | Single-root workspace folder → `cwd` | **YES** (Swift `:163-165`; TS `:134`) | `"file:///Users/<user>/<proj>"` |
| `configuration` | string (`file://` URI) | Path to a `.code-workspace`; adapter opens it and reads `folders[0].uri`/`.path` | **YES** (Swift `:166-192`; TS `:135-165`) | `"file:///…/foo.code-workspace"` |
| `workspace` | string (`file://` URI) | **Legacy** multi-root pointer into global `Code/Workspaces/<id>/workspace.json` | **NO — flagged** ([§15](#15-lineage-gotchas-version-drift--edge-cases)) | `"file:///Users/<user>/Library/Application%20Support/Code/Workspaces/1616927850246/workspace.json"` |

Resolution rules: single-root `folder` → `decodeFileURI` (strip `file://`,
optional `localhost/`, percent-decode); non-`file://` URIs (`vscode-remote://`,
`vsls://`) → `""`. Multi-root: open the `.code-workspace`, take `folders[0].uri`
(decoded) or `folders[0].path` (absolute as-is; relative resolved against the
`.code-workspace` dir). If this sidecar path yields `""`, Engram falls back to
the session payload's `v.workingDirectory`, again accepting only local `file://`
URIs.

Live distribution: **16** workspaces use `folder`, **1** uses the legacy
`workspace` key.

---

## 14. Engram mapping

Source field/record → Engram `Session` field → adapter file:line (Swift + TS).

| Engram field | Source of value | Swift file:line | TS file:line | Notes / gotcha |
|---|---|---|---|---|
| `id` | `v.sessionId` ∥ filename stem | `VsCodeAdapter.swift:51-52` | `vscode.ts:96` | Fallback to `<uuid>.jsonl` basename if `sessionId` empty |
| `source` | constant `"vscode"` | `VsCodeAdapter.swift:4,58` | `vscode.ts:35,97` | — |
| `summary` / title | first non-empty user text, sliced to 200 chars | `VsCodeAdapter.swift:71` | `vscode.ts:109` | No dedicated title used; `customTitle` + DB `title` ignored |
| `cwd` | `workspace.json` `folder`/`configuration` → decoded `file://`; fallback to `v.workingDirectory` | `VsCodeAdapter.swift:55,260-289` | `vscode.ts:94-96,128-166` | `""` if both sources are missing/remote/malformed/legacy-`workspace` |
| `project` | always `nil` | `VsCodeAdapter.swift:64` | (omitted) | Resolved later by Engram core from `cwd` |
| `model` | always `nil` | `VsCodeAdapter.swift:65` | (omitted) | Not extracted even when present in store |
| `startTime` | `v.creationDate` (ms) → ISO8601 | `VsCodeAdapter.swift:43,59` | `vscode.ts:98` | **Swift hard-fails if `creationDate` absent** (`:43-44`); TS guarded by try/catch null (`:80,113`) |
| `endTime` | last request `timestamp` (ms) → ISO; `nil` if `== creationDate` | `VsCodeAdapter.swift:50,60-62` | `vscode.ts:90,99-102` | `nil`/`undefined` for single-turn chats |
| `messageCount` | `userTexts.count + assistantTexts.count` | `VsCodeAdapter.swift:66` | `vscode.ts:104` | Counts only turns yielding non-empty text |
| `userMessageCount` | count of non-empty user texts | `VsCodeAdapter.swift:67` | `vscode.ts:91,105` | — |
| `assistantMessageCount` | count of non-empty `markdownContent` texts | `VsCodeAdapter.swift:68` | `vscode.ts:92,106` | **toolUse/progressTask-only turns NOT counted** |
| `toolMessageCount` | constant `0` | `VsCodeAdapter.swift:69` | `vscode.ts:107` | Tool calls never extracted ([§7](#7-tool-calls--results)) |
| `systemMessageCount` | constant `0` | `VsCodeAdapter.swift:70` | `vscode.ts:108` | — |
| per-message `role` | `user` / `assistant` only | `VsCodeAdapter.swift:110,121` | `vscode.ts:186,202` | No tool/system roles emitted |
| per-message `content` | user/assistant text (Layer B/C) | `VsCodeAdapter.swift:106-129` | `vscode.ts:182-211` | — |
| per-message `timestamp` | request `timestamp` (ms) → ISO | `VsCodeAdapter.swift:104-105` | `vscode.ts:188-190,204-206` | Both msgs of a turn share the turn timestamp |
| per-message `toolCalls` / `usage` | `nil` | `VsCodeAdapter.swift:113-114,124-125` | `vscode.ts` (omitted) | No tool/token data |
| `filePath` | `.jsonl` locator | `VsCodeAdapter.swift:72` | `vscode.ts:110` | — |
| `sizeBytes` | full file size on disk | `VsCodeAdapter.swift:75` | `vscode.ts:78,111` | Whole `.jsonl` log bytes, not just final-state payload |
| `agentRole`/`originator`/`origin`/`parentSessionId`/`suggestedParentId`/`tier`/`qualityScore`/`indexedAt`/`summaryMessageCount` | all `nil` | `VsCodeAdapter.swift:74-82` | (n/a) | Set downstream by Engram core |

**Discovery / read internals:** detect `VsCodeAdapter.swift:20-22` / `vscode.ts:51-58`;
enumerate `:24-38` / `:60-74`; replay session log via `readSession` +
`replayMutationLog` (`VsCodeAdapter.swift:140-180`; `vscode.ts:220-277`);
`extractUserText` `:311-326` / `:229-237`; `extractAssistantText` `:328-341` /
`:239-246`; `decodeFileURI` `:302-309` / `decodeFileUri` `:313-326`.

**Registration:** Swift `macos/Shared/EngramCore/Adapters/SessionAdapterFactory.swift:31,108`
(`VsCodeAdapter()`) — note this factory lives directly under `Adapters/`, **not**
under `Adapters/Sources/` where `VsCodeAdapter.swift` itself lives; source enum
`SourceName = .vscode` (`VsCodeAdapter.swift:4`). TS registers via
`src/core/bootstrap.ts:63` (`new VsCodeAdapter()`).

**Timestamp helper:** `creationDate`/`timestamp` are epoch **milliseconds**,
converted via `isoFromMilliseconds` (UTC, fractional seconds). Parity confirms
`1771392005000` → `"2026-02-18T05:20:05.000Z"`.

**Swift/TS parity:** exact on all observable outputs (ids, counts, timestamps,
cwd, extraction order), confirmed against
`tests/fixtures/adapter-parity/vscode/success.expected.json`. No drift between
product and reference parsers.

---

## 15. Lineage, gotchas, version drift & edge cases

### Shared-format lineage (sibling tools)

VS Code is the root of a large family: all Code-derived editors fork the same
`User/workspaceStorage/<id>/` layout but diverge on chat persistence.

| Tool | Root | Chat storage tech | Engram reads | Same as VS Code? |
|---|---|---|---|---|
| **VS Code (Copilot/Gemini chat)** | `…/Code/User/workspaceStorage` | per-session `chatSessions/*.jsonl` (`kind:0`+`kind:1`) | the `.jsonl` line 0 | **baseline** |
| **VS Code Insiders** | `…/Code - Insiders/User/workspaceStorage` | same `.jsonl` format | NOT covered — only stable `Code` path scanned | identical format, **uncovered**; the 2026-07-01 recheck found no local Insiders `workspaceStorage` directory, so no current local chat files are missed |
| **VSCodium** | `…/VSCodium/User/workspaceStorage` | would match VS Code `.jsonl` | NOT covered (no adapter, no path) | identical format, **uncovered** |
| **Cursor** | `…/Cursor/User/globalStorage/state.vscdb` | **SQLite `cursorDiskKV`**, keys `composerData:<id>` + `bubbleId:<id>:%` | the SQLite, NOT jsonl | **diverged** — same ancestry, different persistence (`CursorAdapter.swift`; `cursor.ts`) |
| **Windsurf** | `~/.codeium/windsurf/...` (+ `~/.engram/cache/windsurf`) | own cache (gRPC live-sync disabled) | cache, not vscdb | diverged |

**Distinct `copilot/` lineage — do NOT confuse:** `tests/fixtures/copilot/` is the
**GitHub Copilot CLI** (`~/.copilot/session-state`, `workspace.yaml` +
`events.jsonl` with `type:"session.start"|"user.message"|"assistant.message"`
records) — a different product with a different adapter. The "Copilot Chat" here
is the Copilot extension *inside* the editor, persisted in VS Code's
`chatSessions/*.jsonl`.

### Gotchas & edge cases

1. **Multi-line append log is replayed.** Live `.jsonl` files are 1..N lines
   (`kind:0` snapshot + `kind:1/2/3` mutations). Both adapters replay valid
   mutations after the initial snapshot. Verified live: `cea0313a…jsonl` has 2
   lines (`kind:0`, `kind:1`).
2. **Empty sessions are the live norm.** All 5 live sessions have `requests: []`.
   Swift returns `.failure(.malformedJSON)` and TS returns `null` when `requests`
   is empty or `creationDate` missing (`:41-44` / `:80`). Net effect on this
   machine: **0 indexed VS Code sessions** despite 5 files.
3. **`k` is an array.** `kind:1` patch keypath is a JSON array (`["inputState"]`),
   not a string. (Corrected vs DIM report.)
4. **`state.vscdb` schema is `UNIQUE ON CONFLICT REPLACE`, not `PRIMARY KEY`.**
   (Corrected vs DIM report.)
5. **Legacy `workspace` key unhandled.** Live `3011e0800a82af49da1596d7bbbf8a16/`
   uses `{"workspace": "file://…/Code/Workspaces/<id>/workspace.json"}`. Both
   adapters only branch on `folder`/`configuration` (Swift `:163-171`; TS
   `:134-139`), so such a workspace resolves `cwd = ""`. This dir has no
   `chatSessions/` today, so impact is latent.
6. **Backend identity collapses to `vscode`.** Copilot, Gemini-for-VS-Code, and any
   other chat extension all write the same `chatSessions/*.jsonl`;
   `responderUsername` (the disambiguator) is discarded. Provenance is lost.
7. **`version:3` only, no version gate.** Live + fixtures are `version 3`; the
   field is typed but never validated/branched. A future `version:4` with a
   different `requests`/`response` shape would silently mis-parse rather than error.
8. **First-`markdownContent`-block-only.** Only the first markdown block per turn is
   captured; multi-block answers (or tool-call + summary) lose everything after the
   first block.
9. **Tool/progress-only turns vanish.** Turns whose responses are all
   `toolUse`/`progressTask` yield no assistant message and are excluded from counts
   — message counts undercount real interaction volume.
10. **cwd can be empty.** Remote (`vscode-remote://`, `vsls://`) or malformed
    `file://` URIs decode to `""`; multi-root without `folders[0]` also `""`.
11. **`sizeBytes` counts log bytes, not final-state payload bytes.** Reported
    size is the whole `.jsonl`, including mutation-log lines.
12. **Two timestamps per turn collapse.** User and assistant messages of one
    `request` share the single turn `timestamp` (parity golden: both req-1
    messages = `…05.000Z`), so intra-turn ordering is not time-resolvable.
13. **`endTime` suppressed for single-turn chats.** When last `timestamp == creationDate`,
    `endTime` is `nil`/`undefined` by design (`:60-62`).
14. **Swift/TS parity exact.** No drift between product and reference parsers.

### Open / unverified

- **Populated request/response complex payloads.** All live sessions are empty,
  so response-part kinds beyond `markdownContent` (`toolInvocationSerialized`,
  `progressTaskSerialized`, `textEditGroup`, `thinking`, …) and the exact nesting
  of tool/progress payloads are documented from VS Code source + adapter comments,
  **not** sampled locally. Re-sample a machine with active Copilot Chat usage to
  verify real `toolInvocationSerialized` payload shape (`toolCallId`/`resultDetails`
  and any drift). `modelId` and several usage-like fields are no longer unknown:
  the current official schema includes them, but Engram ignores them.
- **Richer mutation payloads.** Current adapters replay `kind:1/2/3`, and focused
  tests cover appended requests via `kind:2`. Local live data only has one
  `kind:1` metadata patch and no populated request mutations, so complex
  request/response mutations still need resampling on a machine with active VS
  Code chat usage.
- **`version:4`+ drift.** Only `version 3` observed locally, and the current
  official `storageSchema` still emits `version:3`; future schema drift remains a
  parser risk.
- **Provenance split.** Whether Engram intends to split Copilot vs
  Gemini-in-VS-Code (via `responderUsername`) into sub-sources is a design
  question, not resolvable from code.

### Official source confirmation (2026-07-01)

- **Confirmed (official):** `ChatSessionStore` stores the index under
  `chat.ChatSessionStore.index`, uses `workspaceStorageHome/<workspaceId>/chatSessions`
  for normal workspaces, and uses the profile `emptyWindowChatSessions` root for an
  empty window.
- **Confirmed (official):** current storage writes `.jsonl` append logs by default
  when `chat.useLogSessionStorage !== false`, with a flat `.json` fallback. Reads
  prefer the `.jsonl` log and fall back to the flat JSON file.
- **Confirmed (official):** `ObjectMutationLog` entries are `kind:0` initial,
  `kind:1` set, `kind:2` push/splice, and `kind:3` delete. Any mutation entry
  before an initial entry throws `Log file is missing an initial entry`.
- **Confirmed (official):** `ChatSessionOperationLog.storageSchema` emits
  `version:3`, `creationDate`, `initialLocation`, `inputState`,
  `responderUsername`, `sessionId`, `requests`, `hasPendingEdits`, `repoData`,
  `pendingRequests`, and `workingDirectory`. Per-request schema includes `agent`,
  `modelId`, `variableData`, `response`, `result`, `followups`, `modelState`,
  `completionTokens`, `promptTokens`, `outputBuffer`, `promptTokenDetails`, and
  `copilotCredits`; Engram's current adapter still drops these richer model/usage
  fields and emits only the user/assistant text pairs documented above.

---

## 16. Appendix: real anonymized samples

### A. Empty-stub session — `chatSessions/<uuid>.jsonl` line 0 (live, `version: 3`)

```json
{"kind":0,"v":{"version":3,"creationDate":1771392503565,"initialLocation":"panel","responderUsername":"","sessionId":"4aa52579-6e03-4031-915e-a6ed65da1d50","hasPendingEdits":false,"requests":[],"pendingRequests":[],"inputState":{"attachments":[],"mode":{"id":"agent","kind":"agent"},"inputText":"","selections":[{"startLineNumber":1,"startColumn":1,"endLineNumber":1,"endColumn":1,"selectionStartLineNumber":1,"selectionStartColumn":1,"positionLineNumber":1,"positionColumn":1}],"contrib":{"chatDynamicVariableModel":[]}}}}
```

### B. `kind:1` patch line (live, second line of `cea0313a…jsonl`)

```json
{"kind":1,"k":["inputState"],"v":{"attachments":[],"mode":{"id":"agent","kind":"agent"},"inputText":"","selections":[{"startLineNumber":1,"startColumn":1,"endLineNumber":1,"endColumn":1,"selectionStartLineNumber":1,"selectionStartColumn":1,"positionLineNumber":1,"positionColumn":1}],"contrib":{"chatDynamicVariableModel":[]}}}
```

### C. Populated session with 2 turns — `chatSessions/<uuid>.jsonl` line 0 (fixture, anonymized)

```json
{"kind":0,"v":{"version":3,"sessionId":"sess-001","creationDate":1771392000000,"requests":[
  {"requestId":"req-1",
   "message":{"text":"<user prompt text>","parts":[{"kind":"text","value":"<user prompt text>"}]},
   "response":[{"value":{"kind":"markdownContent","content":{"value":"<assistant markdown>"}}}],
   "timestamp":1771392005000},
  {"requestId":"req-2",
   "message":{"text":"<user prompt 2>","parts":[{"kind":"text","value":"<user prompt 2>"}]},
   "response":[{"value":{"kind":"markdownContent","content":{"value":"<assistant markdown 2>"}}}],
   "timestamp":1771392015000}
]}}
```

### D. `workspace.json` variants (live, anonymized)

```json
{"folder":"file:///Users/<user>/<proj>"}
```
```json
{"workspace":"file:///Users/<user>/Library/Application%20Support/Code/Workspaces/1616927850246/workspace.json"}
```

### E. `state.vscdb` — `chat.ChatSessionStore.index` value (live, anonymized)

```json
{
  "version": 1,
  "entries": {
    "cea0313a-2e97-477f-83aa-850a5f9faad1": {
      "sessionId": "cea0313a-2e97-477f-83aa-850a5f9faad1",
      "title": "<REDACTED>",
      "lastMessageDate": 1772112775137,
      "timing": { "created": 1772112775137 },
      "initialLocation": "panel",
      "hasPendingEdits": false,
      "isEmpty": true,
      "isExternal": false,
      "lastResponseState": 1
    }
  }
}
```

### F. `state.vscdb` schema (live)

```sql
CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
```

### G. Engram parity golden — `sessionInfo` output for the 2-turn fixture

```json
{
  "id": "sess-001",
  "source": "vscode",
  "startTime": "2026-02-18T05:20:00.000Z",
  "endTime": "2026-02-18T05:20:15.000Z",
  "cwd": "/Users/test/my-project",
  "messageCount": 4,
  "userMessageCount": 2,
  "assistantMessageCount": 2,
  "toolMessageCount": 0,
  "systemMessageCount": 0,
  "summary": "<first user text, ≤200 chars>",
  "sizeBytes": 779
}
```

## References (official sources)

Validated against `microsoft/vscode` `main` on 2026-07-01:

- [chatSessionStore.ts](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/chat/common/model/chatSessionStore.ts) — storage roots, `chat.ChatSessionStore.index`, `.jsonl` vs `.json` storage, read/write flow.
- [chatSessionOperationLog.ts](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/chat/common/model/chatSessionOperationLog.ts) — `storageSchema`, request schema, current `version:3`, model and usage-like fields.
- [objectMutationLog.ts](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/chat/common/model/objectMutationLog.ts) — append-log entry kinds, initial-entry requirement, diff/append behavior.
