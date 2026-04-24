# CLI Replacement Table

Date: 2026-04-24

This table records the Stage 4 decision for the Node `engram` CLI surface before any Stage 5 Node deletion. It separates the current Swift `EngramCLI` target from the Node CLI entrypoint in `package.json`.

## Current Swift CLI

| Surface | Current status | Stage 4 decision | Stage 5 deletion condition |
|---|---|---|---|
| `macos/EngramCLI/main.swift` | Unix-socket stdio bridge to app-local `/mcp` HTTP | Retain temporarily only as compatibility bridge | Delete after external MCP clients use the shipped Swift `EngramMCP` stdio helper directly, or replace with a real Swift ArgumentParser CLI |
| Bare `EngramCLI` with stdin JSON-RPC | Forwards each JSON-RPC line to `/tmp/engram.sock` | Compatibility-only, not a general CLI replacement | Must not be counted as replacing Node diagnostic/project/resume subcommands |

## Node CLI Entrypoints

| Command | Node implementation | Writes? | Swift replacement or deprecation | Verification status |
|---|---|---:|---|---|
| `engram` with no subcommand | `src/cli/index.ts` imports `src/index.ts` MCP stdio server | Mixed through MCP tools | Replaced by Swift `EngramMCP` helper, not by `EngramCLI` | Swift MCP golden tests cover public tools |
| `engram logs` | `src/cli/logs.ts` reads observability DB | No | Deprecated for Stage 4; no Swift replacement yet | No Swift CLI test |
| `engram traces` | `src/cli/traces.ts` reads observability DB | No | Deprecated for Stage 4; no Swift replacement yet | No Swift CLI test |
| `engram health` | `src/cli/health.ts` reads DB health tables | No | Deprecated for Stage 4; service/app health surfaces remain separate | No Swift CLI test |
| `engram diagnose` | `src/cli/health.ts` reads logs/traces diagnostics | No | Deprecated for Stage 4; no Swift replacement yet | No Swift CLI test |
| `engram project move` | `src/cli/project.ts` calls project move orchestrator directly | Yes | Not replaced in Swift; Swift MCP/UI explicitly hide or reject this operation until a native migration pipeline is ported | MCP unavailable tests cover fail-closed behavior |
| `engram project archive` | `src/cli/project.ts` calls archive + project move directly | Yes | Not replaced in Swift; Swift MCP/UI explicitly hide or reject this operation until a native migration pipeline is ported | MCP unavailable tests cover fail-closed behavior |
| `engram project review` | `src/cli/project.ts` scans files for residual refs | Filesystem read | Replaced by Swift MCP `project_review` read tool | MCP golden coverage |
| `engram project undo` | `src/cli/project.ts` calls undo directly | Yes | Not replaced in Swift; Swift MCP/UI explicitly hide or reject this operation until a native migration pipeline is ported | MCP unavailable tests cover fail-closed behavior |
| `engram project list` | `src/cli/project.ts` reads migration log | No | Replaced by Swift MCP `project_list_migrations` | MCP golden coverage |
| `engram project recover` | `src/cli/project.ts` diagnoses migration state | Filesystem read | Replaced by Swift MCP `project_recover` | MCP golden coverage |
| `engram project move-batch` | `src/cli/project.ts` calls batch orchestrator directly | Yes | Not replaced in Swift; Swift MCP/UI explicitly hide or reject this operation until a native migration pipeline is ported | MCP unavailable tests cover fail-closed behavior |
| `engram --resume` / `engram -r` | `src/cli/resume.ts` interactive resume flow | Launches external CLI/app | Deprecated for Stage 4; app resume UI uses service-backed `resumeCommand` | App service-client tests cover payload/response, not CLI |

## Gate Interpretation

- Stage 4 App and MCP routing can be considered service-backed for exposed tools after the current boundary scans pass; project move/archive/undo/batch are intentionally not exposed by Swift MCP.
- Stage 4 CLI is not implemented as a native Swift command tree. It is explicitly documented here as retained/deprecated per command so Node CLI deletion cannot happen silently.
- Stage 5 must either add a Swift ArgumentParser CLI with tests or remove the `engram` Node CLI entrypoint with release-note/deprecation coverage.
