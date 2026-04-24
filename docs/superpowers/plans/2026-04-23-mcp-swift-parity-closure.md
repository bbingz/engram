# Swift MCP Parity Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the highest-risk Swift MCP parity gaps so the native helper matches the Node MCP for `initialize`, `search`, and `get_context` behavior that clients and docs already rely on.

**Architecture:** Preserve the current Phase C shape: Swift remains a native stdio helper, read paths stay local, write paths stay daemon-only. Fix parity in three narrow tracks: protocol envelope parity, `search` result-shape/behavior parity, and `get_context` memory/environment parity. Add regression tests before each behavior change so future Swift work cannot silently narrow the contract again.

**Tech Stack:** TypeScript (Node 20, Vitest, tsx), Swift 5.9, XCTest, GRDB, XcodeGen, Biome.

---

## File Map

- `macos/EngramMCP/Core/MCPStdioServer.swift` — `initialize` response shape, server instructions, protocol metadata
- `macos/EngramMCP/Core/MCPToolRegistry.swift` — Swift tool dispatch, result shaping, error wrapping
- `macos/EngramMCP/Core/MCPDatabase.swift` — current Swift read-side implementations for `search` and `get_context`
- `macos/EngramMCPTests/EngramMCPExecutableTests.swift` — subprocess contract tests for the built Swift helper
- `scripts/gen-mcp-contract-fixtures.ts` — golden fixture generation source of truth for Node output
- `tests/fixtures/mcp-golden/*.json` — byte-stable contract fixtures used by Swift tests
- `src/index.ts` — Node MCP source of truth for `initialize` semantics and tool surface
- `src/tools/search.ts` — Node `search` behavior source of truth
- `src/tools/get_context.ts` — Node `get_context` behavior source of truth
- `docs/mcp-swift.md` — switchover guide; must stop overclaiming while parity work is in flight

---

### Task 1: Lock `initialize` Contract Before Changing Swift

**Files:**
- Modify: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Modify: `macos/EngramMCP/Core/MCPStdioServer.swift`
- Modify: `docs/mcp-swift.md`

- [ ] Add a failing Swift contract test that snapshots `initialize` against the current Node MCP behavior, not just `result != nil`.
- [ ] Include assertions for:
  - top-level `protocolVersion`
  - `capabilities.tools`
  - `serverInfo.name`
  - presence of `instructions`
- [ ] Reproduce the current drift with direct commands:
  - `printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}' | node dist/index.js`
  - `printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}' | <swift-helper-path>`
- [ ] Update `MCPStdioServer.initialize` to emit the same contract fields the Node server already exposes.
- [ ] Keep protocol negotiation behavior unchanged for now; parity here means matching the current Node response, not inventing a new negotiation layer.
- [ ] Narrow the docs claim in `docs/mcp-swift.md` until the code and tests prove equivalence end-to-end.
- [ ] Verify:
  - `xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'`
  - direct `initialize` comparison between Node and Swift helper output

### Task 2: Restore `search` Behavioral Parity

**Files:**
- Modify: `macos/EngramMCP/Core/MCPDatabase.swift`
- Modify: `macos/EngramMCP/Core/MCPToolRegistry.swift` only if result shaping needs extraction
- Modify: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Modify: `scripts/gen-mcp-contract-fixtures.ts`
- Modify: `tests/fixtures/mcp-golden/search.*.json` as needed

- [ ] Add failing Swift contract coverage for at least these Node-observed cases:
  - hybrid search without embeddings still returns keyword results plus the keyword-only warning
  - search returns `insightResults` when FTS/insight fallback finds them
  - semantic-mode short-query handling matches Node warning semantics
- [ ] Generate the expected Node outputs from `src/tools/search.ts`, not handwritten Swift expectations.
- [ ] Decide the smallest acceptable parity target:
  - preserve current Swift local-read architecture
  - reproduce Node result shape and warnings even when semantic ranking is unavailable
  - do not silently downgrade `hybrid`/`semantic` into unlabelled keyword-only behavior
- [ ] Implement the missing result-shape pieces in Swift:
  - `warning`
  - `insightResults`
  - correct `searchModes`
  - correct short-query handling
- [ ] If true semantic parity is still impossible in Swift without vector-store plumbing, make that explicit in code and docs while matching Node’s degraded no-embedding branch exactly.
- [ ] Verify with focused comparisons:
  - `npx tsx -e "import { Database } from './src/core/db.ts'; import { handleSearch } from './src/tools/search.ts'; ..."`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'`
  - refresh any affected `tests/fixtures/mcp-golden/search*.json`

### Task 3: Restore `get_context` Memory and Environment Parity

**Files:**
- Modify: `macos/EngramMCP/Core/MCPDatabase.swift`
- Modify: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Modify: `scripts/gen-mcp-contract-fixtures.ts`
- Modify: `tests/fixtures/mcp-golden/get_context*.json` as needed

- [ ] Add failing Swift contract coverage for Node-observed `get_context` behavior:
  - task query that injects `[memory]` lines through FTS fallback
  - footer includes `+ N memories` when memories are present
  - `include_environment:true` with `detail:"abstract"` and `detail:"full"` does not silently collapse to the same output
- [ ] Use the fixture DB and Node handler to generate expected golden text. Do not hardcode Swift-only text blobs.
- [ ] Port the missing Swift behavior in this order:
  - memory lookup fallback for task queries
  - memory-first rendering in the output body
  - footer memory count
  - environment section parity for the subset Swift can source locally from the DB today
- [ ] For any environment block Swift cannot compute yet, document the exact omission and keep the test matrix scoped to what Node currently emits from fixture-backed data.
- [ ] Remove or resolve the TODO at `MCPDatabase.getContext` once the parity subset is implemented.
- [ ] Verify:
  - Node fixture output vs Swift helper output for the same request payload
  - `xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'`

### Task 4: Rebuild Fixture Discipline and Ship Criteria

**Files:**
- Modify: `scripts/gen-mcp-contract-fixtures.ts`
- Modify: `macos/EngramMCPTests/EngramMCPExecutableTests.swift`
- Modify: `docs/mcp-swift.md`
- Optional modify: `CHANGELOG.md` if parity closure lands as a user-facing fix set

- [ ] Audit the current Swift contract suite for blind spots:
  - only keyword `search` is covered
  - only one narrow `get_context` case is covered
  - `initialize` is presence-only, not parity-asserting
- [ ] Expand the generator so every new Swift golden is derived from Node runtime behavior, not manually assembled JSON.
- [ ] Keep the suite deterministic:
  - `TZ=UTC`
  - fixture DB only
  - mock daemon for write tools
- [ ] Update `docs/mcp-swift.md` to reflect the post-fix truth:
  - if parity is achieved, keep the strong claim
  - if any narrow deviations remain, list them explicitly instead of saying “identical”
- [ ] Final verification:
  - `npm test`
  - `npm run lint`
  - `xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'`
  - targeted Node/Swift direct comparisons for `initialize`, `search`, `get_context`

---

## Execution Order

1. `initialize` first, because it is a pure contract fix with the smallest blast radius and immediately improves the test harness.
2. `search` second, because its result-shape drift is externally visible and easier to isolate than `get_context`.
3. `get_context` third, because memory/environment parity touches more text assembly paths and will benefit from the hardened fixture discipline from Task 2.
4. Docs and final fixture regeneration last, so user-facing claims are based on the finished code, not intent.

## Success Criteria

- Swift `initialize` returns the same user-relevant contract fields as Node, including `instructions`
- Swift `search` no longer silently narrows hybrid/semantic requests into an under-specified keyword-only subset
- Swift `get_context` restores memory-aware context assembly and no longer drops environment-related behavior by default
- Swift contract tests fail if any of the three areas drift again
- `docs/mcp-swift.md` matches the verified state of the shipped helper

## Verification Notes

- `npm run lint` is already red on `main` for pre-existing reasons outside this parity closure. Treat lint cleanup as a parallel hygiene task, not as proof that the parity work itself is wrong.
- Do not claim “identical JSON-RPC contracts” again unless the direct Node-vs-Swift comparison for the covered scenarios is part of the final evidence set.
