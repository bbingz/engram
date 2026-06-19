# ENGRAM SERVICE KNOWLEDGE BASE

## OVERVIEW
`EngramService` is the native helper process. It owns the socket-facing service runtime, command dispatch, write gate, indexing coordination, observability events, and native Hummingbird transcript web UI.

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Process entry | `main.swift` | Installs signal handling and runs `EngramServiceRunner`. |
| Startup/indexing/web readiness | `Core/EngramServiceRunner.swift` | Service lifecycle, initial scan phases, indexing loop, usage/web events. |
| Command dispatch | `Core/EngramServiceCommandHandler*.swift` | Native command implementations and compatibility behavior. |
| Write serialization | `Core/ServiceWriterGate.swift` | Single service-owned writer path and IPC write protection. |
| Read DTO provider | `Core/EngramServiceReadProvider.swift` | Search, stats, timeline, exports, settings reads. |
| Native web UI | `Core/EngramWebUIServer.swift` | Hummingbird transcript/app web server. |
| IPC listener | `IPC/UnixSocketServiceServer.swift` | Framed JSON socket handling and peer/token checks. |
| Tests | `../EngramServiceCoreTests/` | IPC, writer gate, telemetry, web, replay, security coverage. |

## CONVENTIONS
- Mutating app/MCP-facing operations go through `ServiceWriterGate`; do not bypass it with local GRDB writes.
- Service errors should remain structured and observable; do not silently swallow DB or command failures.
- Keyword search is the product search path. Unsupported semantic/hybrid/both requests must degrade explicitly with a warning.
- The native web UI is part of the Swift product path; do not confuse it with historical `src/web.ts`.
- IPC and web code should fail closed when capability tokens, peer identity, Host/CORS, or body limits matter.
- Long service loops emit status/usage events; keep event shapes compatible with app and MCP consumers.

## ANTI-PATTERNS
- Do not make app code reach around the service for writes.
- Do not report unsupported command behavior as success.
- Do not add Node-backed startup or web serving to this target.
- Do not treat transient listener errors as a reason to tear down the whole service.

## COMMANDS
```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Engram.xcodeproj -scheme Engram -destination 'platform=macOS' -only-testing:EngramTests/AppSearchServiceCutoverScanTests
```
