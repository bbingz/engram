# GitHub README Refresh Design

## Goal

Make the public GitHub repository understandable to a new visitor in 30 seconds and runnable in 5 minutes, without changing runtime behavior.

## Scope

- Rewrite `README.md` as the English public landing page.
- Add `README.zh-CN.md` as the Chinese mirror for native Chinese readers.
- Add GitHub-friendly Mermaid diagrams for data flow and runtime architecture.
- Clarify installation paths: prebuilt macOS release, source build, and MCP registration.
- Make privacy posture visible near the top: local-first, zero telemetry, read-only source logs.
- Add a standard MIT `LICENSE` because the README already declares MIT.
- Add lightweight GitHub issue templates for bug reports and feature requests.

## Out of scope

- No code changes.
- No release asset changes.
- No app screenshots or binary assets.
- No marketing claims that depend on unverified external state.

## Content architecture

The English README should lead with:

1. Project identity: Engram is a local-first memory layer for AI coding tools.
2. Concrete problem: switching between Codex, Claude Code, Cursor, Gemini CLI, and other tools loses context.
3. Value proposition: index local session logs once, then expose search, recall, handoff, and statistics through MCP and the macOS app.
4. Safety posture: read-only adapters, local SQLite, optional network features only when configured.
5. Quick start: release download first, source build second, MCP registration examples.

The Chinese README should keep the same structure but use natural Chinese instead of a literal translation.

## Verification

- Run `npm run lint`.
- Check `git status --short --ignored .memory` to ensure local memory remains ignored.
- Review Markdown links and Mermaid fences by inspection.
