---
name: Session inspector Option A landed
description: Swift-native inspector parity ships in EngramServiceCore; no Node/HTTP bridge reintroduced
type: project
originSessionId: 93479a02-f06e-4376-941f-6c168e24ed31
---
Task 5 (Option A) replaces the original BLOCKED Swift inspector plan.

**Why:** The legacy plan assumed a TypeScript-backed bridge in the .app, which Stage 5 single-stack removed. Option A moves the inspector derivation into Swift to keep one runtime.

**How to apply:**
- Inspector derivation lives in `SQLiteEngramServiceReadProvider.inspectSession(_:)`; do not add a parallel TS-bridge path inside the .app.
- The contract DTO is `EngramServiceSessionInspector` in `macos/Shared/Service/EngramServiceModels.swift`. Treat `tests/fixtures/mcp-golden/session_inspector.fixture.json` as the contract source of truth — the Swift parity test decodes it directly.
- Phase 0 invariants are enforced in Swift: never back-fill `summaries.llmSummary`, never probe PATH inside the inspector resume builder, never reach for Process()/URLSession/daemon.js. Suggested children must stay separate from confirmed child rollup.
- UI surface: `SessionInspectorPanel` inside `SessionDetailView`. The dead `generateSummary()` method was removed; do not resurrect it without wiring an actual user-facing summary action.
