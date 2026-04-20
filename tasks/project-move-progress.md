# engram "接管项目目录操作" — 进度快照 (2026-04-20)

> 用途：跨 context-compact 持久化，下次继续时第一时间读这个。

## 一句话现状

Phase 4a rev3 **完成并全绿**。功能在 CLI 和 MCP 层都可用。
Swift UI (Phase 4b) 和 mvp.py 退役 (Phase 5) 还没做。

## 测试 / Lint 状态

- `npx vitest run`: **1111 pass / 0 fail**
- `npm run build`: clean
- `biome check`: 0 errors, 3 cosmetic infos
- Phase 4a 新增 14 个 MCP 工具测试；Phase 3 新增 ~40 个；Phase 2 新增 80+；Phase 1 新增 25+

## Phase 完成情况

| Phase | 状态 | 关键交付 |
|---|---|---|
| Phase 1 — DB 事务层 | ✅ rev2 | migration_log 三阶段写入、watcher pending guard、applyMigrationDb、LIKE 通配符修复 |
| Phase 2 — FS/Patch/Scan 层 | ✅ rev2 | jsonl-patch (Buffer字节级+UTF8校验)、fs-ops tempDst模式、subprocess grep fast-path、6 源覆盖含 copilot、concurrent-write CAS、Golden diff-test 与 Python mvp.py byte-identical |
| Phase 3 — Orchestrator + CLI + Undo/Recover/Batch | ✅ rev2 | runProjectMove 7-step + 补偿、atomic lock (O_EXCL)、self-subdir guard、UndoStaleError、SIGINT handler、concurrent patchFile pool |
| Phase 4a — MCP 工具 | ✅ rev3 | 7 tools + 2 critical/10 major/若干 minor 修复到位 |
| Phase 4b — Swift UI | ✅ done 2026-04-20 | `/api/project/*` HTTP endpoints + `DaemonClient` wrappers + `ProjectsView` ⋯ 菜单 (Rename/Archive) + top-bar Undo button + Rename/Archive/Undo sheets w/ retry_policy-aware 错误展示；xcodebuild Debug 绿 |
| Phase 4b rev2 (3-way review 修复) | ✅ done 2026-04-20 | 1 Critical + 4 Major + 7 Minor：interactiveDismissDisabled + Task 取消、HTTP 401 JSON envelope + per-request token 刷新、expandHome + 绝对路径校验、sanitize node FS 错误、retry_policy 人话翻译 + Retry 按钮、UndoStale 行禁用、Undo 按钮条件显示、archive 物理移动警告、startedAt DateFormatter、accessibility labels、chevron 转独立 button。+4 test cases，1143 TS pass，xcodebuild 绿 |
| Phase 5a — mvp shim | ✅ done 2026-04-20 | `/Users/bing/-Code-/_项目扫描报告/mvp` 是 bash shim；Python 原版备份为 `mvp.py-retired-20260420` |
| Phase 5b1 — Gemini/iFlow 救援迁移 | ✅ done 2026-04-20 | 41 Gemini + 1 iFlow 活会话从 coding-memory 迁到 engram；DB `source_locator/file_path/cwd` 同步更新；冷备份 `~/.engram/index.sqlite.bak.zombie-rescue.20260420_133127` |
| Phase 5b2 — orchestrator 多源 rename | ✅ done 2026-04-20 | `sources.ts`：`encodesCwd` → `encodeProjectDir`（per-source fn）；加入 iflow (7 sources)；orchestrator 循环 rename 所有源侧项目目录，补偿反向同步。1113 tests green |
| Phase 5b2 rev2 (3-way review 修复) | ✅ done 2026-04-20 | 1 Critical + 3 Major + 4 Minor：preflight 目录冲突检查、Gemini projects.json 同步 + 反向补偿、basename 劫持预检、rename error 加 sourceId 上下文、migration_log.detail 加 skipped_dirs/gemini_projects_json_updated、iFlow 有损编码 doc 警告、MCP 描述更新。1131 tests green (+18)。新模块 `gemini-projects-json.ts` |
| Phase 5b3 — CC 墓碑（无动作） | ✅ decided 2026-04-20 | 231 条 CC suspect tombstones + 1 minimax 保留原状：`tier=skip`+`orphan_status=suspect` 已经 UI 不可见，当历史记录 |

## 关键文件地图

```
src/core/project-move/
  orchestrator.ts     # 主 pipeline + 补偿事务 + SIGINT
  paths.ts            # expandHome 共享 helper
  encode-cc.ts        # Claude Code / → - 编码
  jsonl-patch.ts      # Buffer 字节级 + CAS + TextDecoder 严格 UTF-8
  sources.ts          # 6 源枚举 + grep fast-path + walkSessionFiles(stack)
  fs-ops.ts           # safeMoveDir + EXDEV 回退 + tempDst 模式
  git-dirty.ts
  lock.ts             # O_EXCL 原子锁
  archive.ts          # 归档启发式 + forceCategory
  review.ts           # own/other 分类
  undo.ts             # 含 UndoStaleError + actor 参数
  recover.ts          # 诊断不动
  batch.ts            # YAML v1 parser + archive mkdir parent
src/tools/project.ts   # 7 MCP 工具定义 + handler
src/cli/project.ts     # 子命令
src/index.ts           # MCP registry + structuredContent 错误映射

tests/core/project-move/  # 每模块单测 + golden diff-test
tests/tools/project-mcp.test.ts
tests/fixtures/project-move/golden/  # 6 case + Python oracle

scripts/generate-golden-patch.py   # 动态 import mvp.py 保持 drift-proof

plans/project-move-takeover.md    # 方案文档 (rev 2)
```

## 真实数据准备

- 冷备份：`~/.engram/index.sqlite.bak.20260420_073851` 和 `bak.20260420_083315`
- 1498 孤儿会话 baseline（未来 Phase 5 可能需要 bulk cleanup）
- 大部分是 Claude Code 自动清理的 subagent，不是 mvp 误伤（考古已证）

## Phase 4a rev3 关键设计（AI 侧重要）

1. **MCP structuredContent** 代替自造字段，AI client first-class 识别
2. **`retry_policy`** 四值枚举：`safe` / `conditional` / `wait` / `never`
3. **Tool description 全加 `⚠️ Cannot run concurrently`** — AI 知道串行
4. **`force` 描述硬约束** — AI 不得自动 retry with force
5. **`resolved: {src, dst}`** — `~` 展开时 echo 回，防 AI 路径幻觉
6. **英文别名** `archived-done/empty-project/historical-scripts`（避 `completed` 语义污染）
7. **Batch top-level `dry_run`** 覆盖 YAML defaults

## 下次继续时的决策点

所有计划内 phase 全部落地。剩余可选项：

1. **Swift UI 手工走查** — Xcode 跑起来点一遍 Rename/Archive/Undo 三个 sheet（build 已绿，但没真按过按钮）
2. **Phase 4b 3-way review** — 新增的 HTTP endpoints + Swift UI 可以再过一轮 codex + gemini
3. **push 到 origin/main** — 本地已积 3 次 feat commit 未 push
4. **暂停** — 功能完整，进入下个项目

## Phase 5a 翻译说明（mvp shim, 2026-04-20）

行为变化（唯一一处）：原 `mvp --review-only` 会自动 sed `<old>."` → `<new>."`；shim 不做此自动修复。
理由：`engram project move` 走 JSONL 字节级 patch，`."` 漏网情况已极少；残留建议人肉审。
环境变量 `ENGRAM_CLI` 可覆盖默认 `dist/cli/index.js` 路径。

## 三方 Review 工作流（如要继续审）

模式：并行 `codex:codex-rescue` + `gemini:gemini-agent` + self-review，汇总去重，按 severity 排序全修。
每轮重点不同：Codex 挖工程/正确性，Gemini 挖产品/AI UX，self 兜架构陷阱。

## 未合并到 git

- 本 session 所有改动都在 working tree，没 commit。用户明确偏好「只在被要求时 commit」（见 user memory）。
- 如果要 commit，提醒冷备份 DB 已做，代码风险低（1111 绿 + lint clean）。

## 相关 memory（如需读）

- `/Users/bing/.claude/projects/-Users-bing--Code--engram/memory/MEMORY.md` — 索引
- `/Users/bing/-Code-/_项目扫描报告/engram_接管_项目目录操作_handoff.md` — 用户最初的需求书
- `/Users/bing/-Code-/engram/plans/project-move-takeover.md` — 方案 rev 2
