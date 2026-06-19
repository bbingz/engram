# ADAPTERS KNOWLEDGE BASE

## OVERVIEW
Swift adapters here are the product parser source of truth. They normalize
sessions, messages, tool calls, usage, cwd, provider/source identity, and
live-sync availability for indexing, transcript export, app reads, and MCP
reads.

## STRUCTURE
```
- Sources/                  # Source-specific Swift adapters
- SessionAdapterFactory.swift
- AdapterRegistry.swift
- shared normalized models/protocols
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Registered product sources | `SessionAdapterFactory.swift` | `defaultAdapters()` currently registers 17 sources. |
| Source parser | `Sources/*Adapter.swift` | One file per source family where possible. |
| Parity harness | `AdapterRegistry.swift` | Loads goldens and compares Swift parser results. |
| Golden fixtures | `../../../../tests/fixtures/adapter-parity/` | `success.expected.json` per provider plus batch-size gate. |
| Adapter tests | `../../../EngramCoreTests/AdapterParityTests.swift`, `../../../EngramTests/AdapterParityTests.swift` | Product parity and app-level parser checks. |

## CONVENTIONS
- Add new product adapters in Swift first.
- Parser failures for malformed/unreadable inputs generally produce skip/failure results rather than crashing the whole scan.
- Visible transcript content normalizes to non-empty user/assistant bubbles; system/tool/event rows are for indexing, diagnostics, and stats.
- Windsurf and Antigravity are constructed with `enableLiveSync: false`; do not count them as live gRPC sources.
- For parser output changes, update or regenerate fixture/parity data in the same change.
- Derived Claude Code sources should avoid re-reading identical file heads; preserve hint/cache behavior.

## ANTI-PATTERNS
- Do not treat TypeScript adapters as shipped behavior.
- Do not surface provider health probes, review probes, or known dispatch noise as independent normal sessions.
- Do not assign the whole backing database file size to every session when only a payload/session size is meaningful.
- Do not add mock-only parser tests when real fixture coverage can exercise the format.

## COMMANDS
```bash
npm run check:adapter-parity-fixtures
npm test -- tests/adapters
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -only-testing:EngramCoreTests/AdapterParityTests/testSwiftAdaptersMatchNodeParityGoldensForAllProviders
xcodebuild test -project Engram.xcodeproj -scheme Engram -destination 'platform=macOS' -only-testing:EngramTests/MessageParserTests
```
