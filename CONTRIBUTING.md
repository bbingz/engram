# Contributing to Engram

## Prerequisites
- Node.js >= 20
- macOS 14+ (for Swift app)
- Xcode 16+ with xcodegen (`brew install xcodegen`)

## Setup
```bash
npm install && npm run build
```

## Development
```bash
npm run dev          # run without compile (tsx)
npm test             # vitest
npm run lint         # biome check
npm run lint:fix     # biome auto-fix
npx knip             # dead code detection
```

## Swift App
```bash
cd macos && xcodegen generate
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build
```

## Commit Convention
We use conventional commits: `feat()`, `fix()`, `chore()`, `refactor()`, `test()`, `docs()`

## Pre-commit
Husky + lint-staged runs biome check on staged `.ts` files automatically.

## Architecture
See `AGENTS.md` and `CLAUDE.md` for detailed architecture, patterns, and conventions.
