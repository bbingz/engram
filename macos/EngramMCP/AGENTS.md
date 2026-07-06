# ENGRAM MCP KNOWLEDGE BASE

## OVERVIEW
`EngramMCP` is the native Swift stdio MCP helper spawned by MCP clients. It exposes tools, reads, service-backed writes, exports, summaries, and project/admin commands through a contract tested against golden fixtures.

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Executable entry | `main.swift` | Starts the stdio MCP server. |
| Tool registry | `Core/MCPToolRegistry.swift` | Tool schemas, service requirements, handler routing. |
| DB/read helpers | `Core/MCPDatabase.swift` | Read-oriented query/tool backing. |
| Transcript reads | `Core/MCPTranscriptReader.swift` | Streams source transcript content through Swift adapters. |
| File tools | `Core/MCPFileTools.swift` | Project review and file-oriented helpers. |
| Tests | `../EngramMCPTests/` | Executable and contract behavior. |
| Golden fixtures | `../../tests/fixtures/mcp-golden/` | Expected JSON tool outputs. |

## CONVENTIONS
- Mutating tools should go through the service socket/client path and fail closed when the service is unavailable.
- Compatibility-only modes may downgrade, but must surface warnings rather than silently changing semantics.
- Tool schemas and output shapes are contract surfaces; update golden fixtures when they intentionally change.
- Transcript rendering uses Swift adapter normalization: user/assistant bubbles for visible content, tool/system/event rows for diagnostics and stats.
- Keep file-system tools bounded and explicit about paths; do not infer broad project writes from read-only helpers.

## ANTI-PATTERNS
- Do not add direct SQLite writers here.
- Do not route MCP product behavior back to `src/index.ts`.
- Do not count fixture `CLAUDE.md` files under `tests/fixtures` as active project instructions.
- Do not hide service-socket unavailability behind empty successful responses.

## COMMANDS
```bash
cd macos
xcodebuild test -project Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
cd ..
npm run generate:mcp-contract-fixtures
```
