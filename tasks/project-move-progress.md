# engram "接管项目目录操作" — 进度快照 (2026-04-20)

> 用途：跨 context-compact 持久化，下次继续时第一时间读这个。

## 一句话现状

全部 Phase 完成；经过 **4 轮 post-ship review** + 用户 2 次 UI 实测修复。功能在 CLI / MCP / HTTP / Swift UI 四个端全部可用。

## 测试 / Lint 状态

- `./node_modules/.bin/vitest run`: **1169 pass / 0 fail**（+23 since Round 3）
- `npm run build`: clean
- `biome check`: pre-existing `noExplicitAny` warnings in scripts/tests（非本轮改动引入）
- Round 4 新增：19 retry-policy 契约 + 3 NFC/NFD + 1 projects.json unlink

## Phase 完成情况

| Phase | 状态 | 关键交付 |
|---|---|---|
| Phase 1 — DB 事务层 | ✅ rev2 | migration_log 三阶段写入、watcher pending guard、applyMigrationDb、LIKE 通配符修复 |
| Phase 2 — FS/Patch/Scan 层 | ✅ rev2 | jsonl-patch (Buffer字节级+UTF8校验)、fs-ops tempDst模式、subprocess grep fast-path、6 源覆盖含 copilot、concurrent-write CAS、Golden diff-test 与 Python mvp.py byte-identical |
| Phase 3 — Orchestrator + CLI + Undo/Recover/Batch | ✅ rev2 | runProjectMove 7-step + 补偿、atomic lock (O_EXCL)、self-subdir guard、UndoStaleError、SIGINT handler、concurrent patchFile pool |
| Phase 4a — MCP 工具 | ✅ rev3 | 7 tools + 2 critical/10 major/若干 minor 修复到位 |
| Phase 4b — Swift UI | ✅ done 2026-04-20 | `/api/project/*` HTTP endpoints + `DaemonClient` wrappers + `ProjectsView` ⋯ 菜单 (Rename/Archive) + top-bar Undo button + Rename/Archive/Undo sheets w/ retry_policy-aware 错误展示；xcodebuild Debug 绿 |
| Phase 4b rev2 (3-way review 修复) | ✅ done 2026-04-20 | 1 Critical + 4 Major + 7 Minor：interactiveDismissDisabled + Task 取消、HTTP 401 JSON envelope + per-request token 刷新、expandHome + 绝对路径校验、sanitize node FS 错误、retry_policy 人话翻译 + Retry 按钮、UndoStale 行禁用、Undo 按钮条件显示、archive 物理移动警告、startedAt DateFormatter、accessibility labels、chevron 转独立 button。+4 test cases，1143 TS pass，xcodebuild 绿 |
| Phase 5a — mvp shim | ✅ done 2026-04-20 | `/Users/example/-Code-/_项目扫描报告/mvp` 是 bash shim；Python 原版备份为 `mvp.py-retired-20260420` |
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

计划内 phase 全部落地并经过 **3 轮 post-ship review**。

### 已完成
1. ✅ Phase 4b 3-way review (rev2 修 1 Critical + 4 Major + 7 Minor)
2. ✅ superpowers code-reviewer follow-ups (3 Important + 3 Minor)
3. ✅ 部署 Release build 到 `/Applications/Engram.app`，daemon 3457 真实监听
4. ✅ User 实测 Pi-Agent dry-run → 抓到 `buildDryRunPlan` stub bug → 真扫描替换
5. ✅ Round 2/3 fix：watcher ENFILE + resolve guard + structuredContent + review.own 警告 + tempArtifacts 真扫 + PathProbe 三态 + 测试加真值断言 + 多项 Swift UI trust-failure 修复
6. ✅ User 二次 UI 实测：发现 Preview 无进度条 + 文件列表不可展开 → 修 `4d3edb5`（progress indicators + manifest disclosure + code-reviewer I4）
7. ✅ Round 4 三方 review（codex + gemini + code-reviewer）+ 全修：4 Critical + 7 Important + 12 Minor
   - B1 `cb95811`: retry-policy.ts 单一事实源；error details 结构化透传；sanitize 逗号修复
   - B2 `a5c4edf`: skippedDirs + perSource.issues surface；ArchiveSheet confirmationDialog；Rename 输入校验 + Enter 绑定；UndoSheet 禁用原因；stale-preview opacity
   - B3 `c95f788`: autoFixDotQuote 入 CAS + 补偿自动反转；archive 别名 normalize 集中；patchFile 硬/软错误分类；limit-before-filter 修；dry-run 计数器；CLI skippedDirs 输出
   - B4 `ff333cb`: macOS case-only rename preflight；NFC/NFD fallback in patchBuffer
   - B5 `f3e9a5c`: contextMenu；MCP 路径示例；recover fs_done 建议修正；Gemini projects.json 空文件 unlink；CLI retry_policy 人话
8. ✅ 测试 1169 绿（+23 since Round 3）；Swift xcodebuild Debug 绿；CHANGELOG + memory 已同步

### 未完成 / 新一轮 review 候选
1. **Round 5 review** — 如需继续，应针对 Round 4 引入的新代码（retry-policy.ts / patchBufferWithDotQuote / realpath preflight / NFC fallback）做专项审
2. **UI 手工再走查** — 真点 Rename → 完整 committed 流程（非 dry-run）到现在还没验（Round 4 加了 ArchiveSheet confirm dialog，需手测）
3. **recover 的 fs_done 路径** — Round 4 已修建议文案，端到端 test 仍缺
4. **Batch YAML 功能** — 代码全、tests 全，但实际大批量 move 没跑过真实数据
5. **Archive 分类启发式** — 3 个 rule 没有边界大样本测
6. **Round 4 未做**：UndoSheet 键盘导航（List(selection:) 重构 — 工作量大，跳过）；CAS mtime 1s 精度（需 inode + size 双 CAS，工作量大，跳过）
7. **已知局限**：NFC/NFD fallback 只处理 `patchBuffer`，不处理 `findReferencingFiles`（grep 不做 normalize）— 极端边界用户须人肉检查

### 已知边界/不修
- 测试用 `process.env.HOME` 注入 tmp —— 有 afterEach restore；并行测试不互扰
- RenameSheet 坚持 Preview → Rename 两步 —— 对破坏性操作合理
- 内存里 `disabledMigrationIds` 只跨 sheet 生命周期 —— 关了重开丢失，但罕见

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

- `/Users/example/.claude/projects/-Users-example--Code--engram/memory/MEMORY.md` — 索引
- `/Users/example/-Code-/_项目扫描报告/engram_接管_项目目录操作_handoff.md` — 用户最初的需求书
- `/Users/example/-Code-/engram/plans/project-move-takeover.md` — 方案 rev 2
