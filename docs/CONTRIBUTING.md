# Contributing to Engram

## Prerequisites

- Node.js >= 24
- macOS 14+ (for Swift app)
- Xcode 16+ with xcodegen (`brew install xcodegen`)

## Setup

```bash
npm install && npm run build
```

## Development

```bash
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

Use conventional commits: `feat()`, `fix()`, `chore()`, `refactor()`, `test()`, `docs()`.

## Pre-commit

Husky + lint-staged runs biome check on staged `.ts` files automatically.

## Backlog 规范

Backlog 只维护三个入口：

- `docs/roadmap.md`: 产品级方向或跨模块能力。适合需要设计取舍、可能拆成多项工程任务、或影响用户可见能力的工作。
- `docs/TODO.md`: 已确认要做的工程任务。适合 bug、测试缺口、配置修复、工具契约不一致、可在一个 PR 内验收的改动。
- `docs/followups.md`: 观察项、手工验证项、低优先级重构、需要真实数据或运行环境确认的后续工作。

不要新增零散的 `todo*.md`、`plan*.md`、`followup*.md` 或 per-review checklist。历史材料如需保留，放入 `docs/archive/`，但不能作为当前 backlog 的来源。

每个 backlog 条目使用同一结构：

```markdown
### <短标题>

- **Module:** <负责模块或目录>
- **Type:** roadmap | todo | follow-up
- **Source:** <来源文件/审计报告/issue>
- **Acceptance:** <可验证完成条件>
- **Related files:** `<file>`, `<file>`
- **Status:** open | blocked | needs-confirmation
```

代码注释里的 `TODO` 只能作为短期占位。升级路径：

1. 当 TODO 需要跨文件、跨 PR、真实数据验证、或超过当前改动范围时，先按上面格式写入 `docs/TODO.md` 或 `docs/followups.md`。
2. 文档化后移除代码里的 `TODO` 注释；必要时保留不含 TODO 的解释性注释。
3. 完成时从 canonical backlog 删除或移到相关 changelog/closeout，而不是留下已完成 checklist。

## Architecture

See `CLAUDE.md` for detailed architecture, patterns, and conventions.
