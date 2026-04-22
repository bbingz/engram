# Changelog

All notable changes to this project will be documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/).

---

## [Unreleased]

### Added — Phase B Step 3：project_* 家族全量迁移，DB 写工具 6/6 ✅ (2026-04-22)

Phase B 最后一块 —— project_move / project_archive / project_undo 全部路由到 daemon。至此所有 DB 写工具（6/6）都走 daemon 单写者。

**端点侧（`src/web.ts`）**：
- `/api/project/{move,archive,undo}` 新增可选 `actor?: 'cli'|'mcp'|'swift-ui'|'batch'` body 字段，默认 `'swift-ui'`。未知值 → `400 InvalidActor`（防审计污染）
- `actor === 'mcp'` → `normalizeHttpPath` 的 `allowOutsideHome: true`：MCP 作为本地信任对等进程，跳过 HTTP 层的 $HOME 防御（MCP 原本就没这约束，保持对等）
- 原硬编码 `actor: 'swift-ui'` 改为用 `parseActor(body.actor)` 的结果 —— Swift UI 不传 actor 依然落回 'swift-ui'

**MCP dispatch（`src/index.ts`）**：
- `project_move` / `project_undo`：本地 `expandHome` → snake_case→camelCase → 带 `actor:'mcp'` POST；PipelineResult 原本就对齐，响应透传
- `project_archive`：同上 + **响应转换** `{...result, suggestion:{category,reason,dst}}` → `{...result, archive:{category,reason}}`。保持 MCP 契约不变 + Swift UI 契约不变（Swift 只看 `suggestion`）
- 用共享 `shouldFallbackToDirect` 做降级判断

**dry-run 路径自动对齐**：查 orchestrator 发现 `runProjectMove({dryRun:true})` 在 `orchestrator.ts:211-212` 内部就是调 `buildDryRunPlan`，所以 MCP 走 HTTP 后和原来直调 `buildDryRunPlan` 走同一条路径，之前担心的"差异"不存在

**测试 +5**（`tests/web/project-api.test.ts`）：
- 未知 actor → 400 InvalidActor（move / archive / undo 三个端点分别测）
- `actor:'mcp'` 允许 $HOME 外路径通过 normalizeHttpPath
- `actor` 不传 → 默认 'swift-ui'，$HOME 约束仍生效（回归保障）

**结果**：`npm run build` ✓、`npx vitest run` **1202/1202** ✓

**需要 daemon 重新部署**：端点新增 `actor` 字段，旧 daemon 会忽略它（MCP 请求暂时按 `actor:'swift-ui'` 记录审计，功能正常、仅审计字段有小漂移）。Swift UI 不受影响（Swift 没碰 actor，一直是 'swift-ui'）。

### Added — Phase B Step 4：manage_project_alias 迁移 + DELETE body (2026-04-22)

Step 3（project 家族）迁移发现响应形状不对齐（`archive` vs `suggestion`、dry-run 计划差异、$HOME 约束）— 延后为专门一轮。先做简单的 Step 4 闭环继续推进。

- **`manage_project_alias` add/remove 路由到 `POST/DELETE /api/project-aliases`**（端点早有）。`list` 保持直接读（Phase B 只动写路径）
- **`DaemonClient.delete(path, body?)`** 扩展支持带 body 的 DELETE —— `/api/project-aliases` DELETE 需要 `{alias, canonical}` 才能定位要删的行
- MCP dispatch 参数翻译：`old_project/new_project` → `alias/canonical`
- 契约测新增 alias POST+DELETE round-trip + 400 validation bubble-up
- 测试文件重命名 `summary-contract` → `daemon-http-contract`（作用域拓宽到多端点）
- `npm run build` ✓、`npx vitest run` **1197/1197** ✓（+1 delete-with-body + 2 alias contract）
- **不需要 daemon 重新部署**：`/api/project-aliases` 端点早就存在

**Phase B 写工具清点再修订（Survey v3）**：实际 DB 写工具 **6 个**（原估计 10，然后 7，现在 6）：
- `link_sessions` 实为只读（filesystem symlink 是副作用，不触 DB 写），移出 Phase B 范围
- 已完成 4/6：save_insight / generate_summary / alias add / alias remove
- 剩下 Step 3 的 project_move / project_archive / project_undo（共享 orchestrator）

### Added — Phase B Step 2：generate_summary 迁移 + fallback helper 抽共享 (2026-04-22)

Step 1 留的 dispatch 内联判断抽成共享 `shouldFallbackToDirect(err, strict)`，给剩下 5 个工具复用；顺手把 generate_summary 接上 HTTP。

- **`shouldFallbackToDirect(err, strict)`**（`src/core/daemon-client.ts`）—— 核心判断：**`{error:...}` envelope + 4xx = 应用层拒绝（上抛），无 envelope 的 404/405/501 = 旧 daemon 端点缺失（降级）**。理由：Hono 对未知路由返回纯文本 404（无 envelope），而应用层 404（如 "Session not found"）始终带 envelope。这条规则把 rolling deploy 的行为从每个工具内联判断抽到一处
- **save_insight dispatch refactor**：用 helper 替换 inline 判断。行为不变，`src/index.ts` 中 save_insight 的分支从 28 行缩到 15 行
- **generate_summary 迁移**：MCP dispatch 从 `handleGenerateSummary(db, ...)` 改成 `daemonClient.post('/api/summary', {sessionId})`，返回 `{summary}` 包装进 MCP content 格式。**HTTP 响应形状不动**（Swift `SessionDetailView.swift:446` 依赖 `{summary}`）。审计（`audit`）从 MCP 侧迁到 daemon 侧 —— 一次操作一条审计，原本直写路径会产生两条
- 应用层错误降级为 MCP `isError: true` 而非 `throw`，匹配直接路径的行为
- 新增 `tests/web/summary-contract.test.ts`（3 tests）—— DaemonClient → Hono app 的真实 404/400 envelope 与 helper 判断对齐
- `npm run build` ✓、`npx vitest run` **1194/1194** ✓（+5 helper 单测 + 3 contract 测）、biome 干净
- **不需要 daemon 重新部署**：/api/summary 早就存在，Step 2 只改 MCP 路由代码

### Added — Phase B Step 1：DaemonClient + save_insight 单写者 pilot (2026-04-22)

MCP 从"多写者"改造成"daemon 唯一写者"的基础设施 + 首个 pilot 工具。Survey 发现实际写工具 7 个（非 10），其中 6 个端点已存在，只 save_insight 需新增。

- **`src/core/daemon-client.ts`**（新）：`DaemonClient` 封装 fetch + Bearer 鉴权 + timeout + `fetchImpl` 注入（测试友好）。`DaemonClientError` 带 status + body，4xx 与网络错误语义分离。`createDaemonClientFromSettings()` 固定走 127.0.0.1（即使 daemon 绑 0.0.0.0，MCP 走 loopback）
- **`POST /api/insight`**（`src/web.ts`）：调 `handleSaveInsight(params, { db, vecStore, embedder })`，与 MCP 直写路径共用同一 handler，行为一致。校验错误 400，其他 500
- **`src/index.ts` save_insight dispatch**：HTTP 优先，5 种错误分路：
  - 网络错误 (ECONNREFUSED/AbortError) → 软降级到直写
  - 404/405/501 → 软降级（rolling deploy：旧 daemon 没新端点时 MCP 不挂）
  - 400/409/422 → 直接 throw（避免 MCP 对无效输入静默重试到本地）
  - 500+ → 软降级
  - 任何情况下 `mcpStrictSingleWriter=true` → throw
- **`FileSettings.mcpStrictSingleWriter`**（默认 `false`）：软/硬约束开关，硬约束下 daemon 不可达直接 fail
- **测试 +13**：DaemonClient 单测 7 个（fetch 注入）、`/api/insight` 端点测 4 个、DaemonClient → Hono app 契约测 2 个（通过 fetch-shim 把 app.request 包装成 fetch）
- `npm run build` ✓、`npx vitest run` **1185/1185** ✓、biome 对改动 6 个文件干净

**行为变化**：
- 新 MCP 进程（下次 spawn）save_insight 先 POST 到 daemon，不可达则退回直写
- 现有旧 MCP 进程（session 里已在跑的）不受影响，仍走旧路径
- 部署 daemon 后才真正激活单写者（否则 404→ 降级到直写，等效于 Phase A 行为）

### Fixed — MCP 锁竞争快速止血 Phase A (2026-04-22)

用户报"MCP 又挂了"。排查发现 MCP 其实 `✓ Connected`，真症状是 `database is locked` —— 近 2h 有 29 条 `indexFile failed` 报错，**全部来自 `src=watcher`**。DB 同时有 3 个 node 进程（daemon + 2 MCP）持写句柄，WAL 涨到 137 MB，`busy_timeout=5s` 被突破。

**不是 node 稳定性问题**。换 bun / Swift 原生不治本（SQLite 还是 SQLite）。真因是**多进程并发写同一个 SQLite**。Phase A 先止血，Phase B 改架构（见 `PROGRESS.md`）。

- **busy_timeout 5s → 30s** (`src/core/db/database.ts:48`)：watcher 批事务突破窗口时不抛错
- **`checkpointWal()` helper** (`src/core/db/maintenance.ts`)：暴露 `PRAGMA wal_checkpoint(MODE)`，busy=1 退化为 PASSIVE 不抛错，支持 PASSIVE / FULL / RESTART / TRUNCATE
- **daemon 启动时 TRUNCATE + 每 10 分钟周期** (`src/daemon.ts`)：battery 模式 × 2；观测事件 `wal_checkpoint` + `db.wal_frames` gauge
- MCP 不参与 checkpoint —— 只由 daemon 驱动，避免多进程 pragma 竞争
- 契约测试：`tests/core/maintenance.test.ts` + 3 个 `checkpointWal` 测试（fresh DB / 写后 TRUNCATE / PASSIVE 模式）
- `npm run build` ✓、`npx vitest run` **1172/1172** ✓

**预期效果**：WAL 稳定在几 MB，`database is locked` 频次 ≥ 90% 下降。剩余来自真正长事务（> 30s），需 Phase B 拆小或走单写者。

### Fixed — Project Migration Round 4 (2026-04-20)

Third post-ship review cycle — user 在 Rename UI 上报了两个 UX 缺陷（进度条缺失、受影响文件列表不展开），并再次请 codex + gemini + self-review 三方平行审 `cf91fea..9427021`。合并后去重 4 Critical + 7 Important + 12 Minor/Nit，全修，分 5 个 commit 提交。

**B1: Error envelope 统一 (`cb95811`)**
- 抽出 `src/core/project-move/retry-policy.ts` 作单一事实源 — `classifyRetryPolicy()` / `mapErrorStatus()` / `buildErrorEnvelope()` / `humanizeForMcp()` / `sanitizeProjectMoveMessage()`。MCP (`src/index.ts`) 和 HTTP (`src/web.ts`) 都改调这一个模块
- 修复 **Critical**：未知错误默认 `retry_policy` MCP 为 `never`、HTTP 为 `safe` —— 同一错误两个端客户端行为不一致。现统一为 `never`（让用户决定，不鼓励盲目重试）
- 修复 **Critical**：`DirCollisionError` / `SharedEncodingCollisionError` 的 `sourceId` / `oldDir` / `newDir` / `sharingCwds` 在网络层被拍扁成字符串消息。现通过 `details` 字段透传给 Swift UI + MCP structuredContent，UI 能展示"Source: claude-code / Conflict path: /x/y"结构化行
- 修复 **Minor**：`sanitizeProjectMoveMessage` 的 ENOENT/EACCES/EEXIST 正则用 `[^,]*` 停在第一个逗号 —— 包含逗号的路径（APFS 允许）会被截断。改成匹配到闭合单引号或 EOL
- 修复 **Minor**：Swift `ProjectMoveAPIError.errorDescription` 返回 `"\(name): \(message)"` —— 服务端已剥掉 `project-move:` 前缀，Swift 又拼回 `DirCollisionError:` 变冗余。改返回 `message`
- 修复 **Minor**：MCP humanText 加 `DirCollisionError` / `SharedEncodingCollisionError` 分支 —— 之前 fallback 到 `name: message`，AI agent 没拿到"move aside then retry"具体指导
- 加 19 条 retry-policy 契约测试

**B2: Swift UI 破坏性保护 + issue 暴露 + 输入校验 (`a5c4edf`)**
- **Critical**：`PipelineResult.skippedDirs` 加到响应 + Swift Decodable + RenameSheet 预览显示 —— 之前只记在 `migration_log.detail`，iFlow 有损编码折叠 / 无目录 的源静默跳过，用户以为全部迁移成功
- **Critical**：`perSource[].issues` 加到 Swift Decodable + 预览红色警告 —— 之前 dry-run 期间 EACCES / too_large 被扫描发现但 UI 完全看不到
- **Critical**：ArchiveSheet 加 `.confirmationDialog` + `.role(.destructive)` —— 物理移动项目目录本来一键就能断开用户正在用的编辑器/shell/build
- **Important**：RenameSheet Preview 按钮绑定 `.keyboardShortcut(.defaultAction)`（Enter 键）—— 之前必须鼠标点击
- **Important**：RenameSheet 输入 trim whitespace + 拒绝 src == dst —— 之前只判 `isEmpty`，全空格或同路径都能透传到后端
- **Important**：UndoSheet 禁用行显示红色内联 "Can't undo: reason" —— 之前只是变灰，用户不知为何
- **Important**：ArchiveSheet 横幅 `Will move to …` 改用 `selectedCwd` 实际父目录 —— 之前硬编码 `~/-Code-/_archive/`
- **Minor**：预览失效改用 `opacity(0.5)` + "Path changed" 提示 —— 之前粗暴清空视觉突兀
- **Minor**：UndoSheet 行 accessibilityLabel 包含禁用原因

**B3: 后端正确性 (`c95f788`)**
- **Critical**：`autoFixDotQuote` sweep 折入 `patchFile` 的 CAS 窗口（新 `patchBufferWithDotQuote`）—— 之前 orchestrator step 4 是单独 readFile/writeFile pass，并发写下能静默覆盖另一进程的 append
- **Critical**：补偿自动反转 dot-quote 变换 —— step 4 不存在后，补偿用同一 `patchFile` 替换（src/dst 互换），dot-quote 变换原路回退
- **Critical**：`patchFile` 错误分类硬/软 —— `InvalidUtf8Error` + `ConcurrentModificationError` 向上抛触发整体补偿；软 EACCES / 文件中途消失降级为 `WalkIssue` 给 UI 显示。之前全降级导致 `state='committed'` 却半修
- **Critical**：`ARCHIVE_CATEGORY_ALIASES` 从 `src/tools/project.ts` 迁到 `src/core/project-move/archive.ts` (`normalizeArchiveCategory`)，`suggestArchiveTarget` 统一 normalize —— 之前 HTTP `/api/project/archive` 直接把 `archived-done` 透传产生英文目录 `_archive/archived-done/` 而不是 `/归档完成/`
- **Important**：`/api/project/migrations` 的 state filter 从 JS 层下推到 `listMigrations` —— 之前 `state=committed&limit=5` 在最近 5 行里过滤，失败/待定行消耗窗口导致结果数不足
- **Important**：Archive dry-run 不再 `mkdir` `_archive/<category>/` —— 之前 preview 模式也留空目录在磁盘上
- **Important**：dry-run `filesPatched++` 移到 size + read gate **之后** —— 之前先计再 skip，banner count 含被跳过的文件
- **Critical**：`skippedDirs` 同步 surface 到 CLI dry-run plan（含 per-source role + too_large issues）+ commit 后总结 + Swift UI preview
- **Bonus**：CLI dry-run 输出 per-source 分类（rename+patch vs content patch）+ issues 头 5 个 + skipped + clippy summary

**B4: macOS 大小写 + NFC/NFD (`ff333cb`)**
- **Critical**：preflight 允许 case-only rename（`/X/Foo` → `/X/foo` on APFS default case-insensitive）—— 之前 `stat(newDir)` 返源 inode 误触 `DirCollisionError`。现 `realpath(oldDir) === realpath(newDir)` 则放行
- **Critical**：`patchBuffer` NFC/NFD 回退 —— HFS+ 的文件名 NFD 存储，AI CLI 在该卷写 JSONL 可能把路径 NFD 写入。用户 NFC 输入会漏匹配。主正则 0 命中时自动用 `oldPath.normalize('NFD')` 需要再扫一遍
- 3 条 NFC/NFD 往返 + case-preserve 测试

**B5: Minor 收尾 (`f3e9a5c`)**
- **Minor**：`ProjectsView` 卡片加 `.contextMenu` —— 右键菜单镜像 `⋯` 按钮，新用户更易发现
- **Nit**：MCP tool `src`/`dst` description 加具体例子路径 —— AI agent 有模板不捏造
- **Minor**：`recover.ts` 对 `fs_done / src 消失 dst 存在` 的建议改正 —— 之前说 "re-run project move" 但 src 已不存在会立即失败。现指向手动 mv 回或直接 SQL update `migration_log`
- **Minor**：Gemini projects.json 补偿若发现"engram 创建的 + 移除我们的条目后 map 为空"，直接 `unlink` 文件 —— 之前留空壳
- **Minor**：CLI 错误处理调用共享 `classifyRetryPolicy` 输出重试提示 —— 和 MCP/HTTP 行为一致

测试：1169 passed (+20 since Round 3 landing)。Swift xcodebuild Debug 绿。

### Fixed — Project Migration Review Rounds 2/3 (2026-04-20)

**Round 2**（user 实测 `Pi-Agent` rename 时发现 `buildDryRunPlan` 是 stub，所有 dry-run 永远显示 0/0）:
- `buildDryRunPlan` 从占位 stub 改为真扫描 — `findReferencingFiles` 每源 + `Buffer.indexOf` 统计 occurrences，`renamedDirs`/`perSource` 填真实数据
- `watcher.ts` chokidar `ignored` pattern 加 `/.gemini/tmp/<proj>/tool-outputs/` 等 —— 修历史 `ENFILE: file table overflow` crash（gemini tmp 下工具输出文件堆积几万个）
- `runProjectMove` 入口加空值/自引用 guard 防 `Buffer.indexOf(emptyNeedle)` 无限循环

**Round 3**（codex + gemini 再审，聚焦 "stub-class / silent trust failures"，又抓到 4 Important + 4 Minor + 1 Low，全修）:
- `runProjectMove` 入口用 `path.resolve()` canonicalize src/dst —— 之前只 HTTP 层做，MCP/CLI/batch 通过 `/x/a/../proj` 能绕过 `src===dst` / 自子目录 guard（**Critical 漏洞**）
- MCP tool 成功返回加 `structuredContent` —— 之前只错误路径有，AI 客户端成功时拿不到结构化 `migrationId`/`totalFilesPatched`
- dry-run 超大文件（>50 MiB）和 stat 失败改发 `WalkIssue{too_large, stat_failed}`，`perSource.issues` 真实填充 —— 之前硬编码 `+= 1` 或静默吞
- `recover.ts` `tempArtifacts: []` 改真扫 `.engram-tmp-*` / `.engram-move-tmp-*` 残留；`exists()` 改 `PathProbe` 三态（`exists`/`absent`/`unknown`），区分 ENOENT vs EACCES
- Swift 3 sheets：`res.state === committed` 但 `res.review.own` 非空时展示橙色警告 + 换 "Close" 按钮不再 auto-dismiss，软警告不再被静默
- `ProjectsView.hasRecentMigrations: Bool?` —— nil = daemon 不可达，不再乐观保留旧值误导
- `DaemonClient.fetch<T>` 挂 `freshBearerToken()` —— 之前 GET 漏 bearer，`/api/ai/*` 在 token 保护下会 401
- dry-run 200 contract test 加 `totalFilesPatched ≥ 1` 等真值断言 —— 之前只验类型，stub 降级成 0 仍然过
- Gemini projects.json 与 stale "6 AI session roots" 描述改成 7（`encodeIflow` 加入后陈旧了）

**Learning**: Stub-class bugs（返回类型正确但值硬编码/系统性低估）能避开 3 轮 review + 单测 type-check；只有人肉 UI 实测或强断言数值才能拦。已把"测试必须验 count 真值"纳入新 review 清单。

### Added — Project Directory Migration (2026-04-20)

完整接管原 `mvp.py` 脚本职责，跨 7 个 AI 会话源（Claude Code / Codex / Gemini CLI / iFlow / OpenCode / Antigravity / Copilot）重命名或归档项目目录，同步打 patch 所有 cwd 引用。

- **CLI**：`engram project {move,archive,review,undo,list,recover,move-batch}`（`src/cli/project.ts`）
- **MCP**：7 个工具返回 `structuredContent` + `retry_policy`（`safe` / `conditional` / `wait` / `never`），描述带 `⚠️ Cannot run concurrently`
- **HTTP**：`/api/project/{move,undo,archive,cwds,migrations}`，统一错误 envelope 结构，`$HOME` 前缀保护 + `path.resolve` 收 `..` 穿越
- **Swift UI**：`ProjectsView` `⋯` 菜单（Rename / Archive）+ 顶栏 Undo 按钮；`RenameSheet` 反查 cwd（单/多/空三分支），`ArchiveSheet` 分类选择 + 物理移动警告，`UndoSheet` 最近 5 条 committed
- **Gemini projects.json 同步**：新增 `gemini-projects-json.ts`，`~/.gemini/projects.json` 的 cwd→basename 映射随 tmp 目录 rename 原子更新，补偿可回滚
- **Basename 劫持防护**：`SharedEncodingCollisionError` — Gemini `/a/proj` 和 `/b/proj` 共用 `tmp/proj/` 时拒绝 rename
- **Preflight 冲突检查**：`DirCollisionError` — 目标目录已存在时在 step 1 物理移动 **之前** 拒绝，不需要回滚 GB 级 move
- **iFlow 有损编码**：`encodeIflow` 去端破折号，作为第 7 个源接入 `getSourceRoots`
- **三层错误 envelope**（Swift `DaemonClient.validateResponse`）：structured → legacy string → plain text，所有 HTTP 方法统一解码
- **任务取消**：Swift sheet 存 `@State var activeTask`，`onDisappear` 取消 + `Task.isCancelled` 守卫 + `.interactiveDismissDisabled(isExecuting)` — ESC/swipe 不会让 FS 操作静默继续
- **Per-request bearer token**：服务端中间件 + Swift `freshBearerToken()` 都每次读 settings.json，token rotation 不用重启
- **Task retry_policy 人话化**：`RetryPolicyCopy.swift` 把枚举翻成自然语言 + 条件 Retry 按钮；UndoStale 行级禁用防重复提交
- **Python `mvp` 退役**：`/Users/bing/-Code-/_项目扫描报告/mvp` 变 50 行 bash shim delegating to `engram project`；Python 原版备份为 `mvp.py-retired-20260420`
- **Orphan session 处理**（前置工作）：`SessionAdapter.isAccessible`、`sessions.orphan_status/since/reason`、`watcher.onUnlink`、`detectOrphans` 30 天 grace 状态机
- **救援迁移**：41 Gemini + 1 iFlow 活会话从 `coding-memory` 迁到 `engram`，DB 同步 42 条

### Fixed
- daemon 启动时的首个 `ready.todayParents` 事件现在在父子链接/层级回填后再发出，避免菜单栏 badge 启动瞬间出现旧值
- `ThemeTests` 改为断言本地时区显示结果，不再把 UTC 字符串误当作本地时间
- 文档同步到当前事实：`922 tests`、`save_insight` 默认 importance = `5`、非 localhost + 缺少 `httpAllowCIDR` 时 daemon 直接拒绝启动
- `upsertAuthoritativeSnapshot` ON CONFLICT UPDATE 补 `file_path` 回填条件 —— 修 37 条空 `file_path` 行
- `/api/*` 401 响应改成 JSON envelope（原本 plain-text），Swift 客户端统一解码

### Changed
- **Tests**：1111 → **1146**（+35 新测覆盖 project-move 全路径、Gemini projects.json、envelope contract、$HOME 保护）

## [0.0.1.1] - 2026-04-13

### Added
- **Agent Session Grouping**：父子会话关联，agent 子会话自动归组到父会话
  - Layer 1：从 Claude Code subagent 文件路径提取父 ID（确定性）
  - Layer 1b：Codex `originator === "Claude Code"` 自动标记 dispatched
  - Layer 1c：Gemini sidecar `.engram.json` 文件读取 parentSessionId
  - Layer 2：Dispatch pattern 匹配 + 时间/CWD 打分（启发式 → `suggested_parent_id`）
  - Layer 3：HTTP API 手动确认/解除关联
  - Swift UI：`ExpandableSessionCard` 折叠展开，HomeView/SessionList/Timeline 三处联动
  - Menu bar badge 显示今日父会话数量
- **Insight Hardening**：`save_insight` 输入校验（10~50K 字符）、文本去重、`sourceSessionId` 贯穿、删除双表一致性
- **Bootstrap Factories**：`createMCPDeps()` / `createDaemonDeps()` / `createShutdownHandler()` 统一初始化

### Changed
- **测试覆盖率提升**：767 → 922 tests

### Fixed
- MCP Server idle timeout 导致提前断连（已禁用 `idleTimeoutMs`）
- `importance` 默认值全局统一为 5

---

## [0.0.1.0] - 2026-04-13

### Added
- **本地语义搜索**：Viking/OpenViking 替换为 sqlite-vec + FTS5 trigram + RRF 融合
  - `save_insight` MCP 工具 — 主动记忆写入
  - `chunker.ts` — 消息边界优先的文本分块
  - `vector-store.ts` — chunk + insight 向量表 + model tracking
  - `embeddings.ts` — provider 策略（Ollama / OpenAI / Transformers.js opt-in）
  - `ServerInfo.instructions` — MCP 自描述协议
- **Insights 文本存储 + FTS 搜索**：`insights` 表 + `insights_fts`，无 embedding 也能保存和搜索知识
- **save_insight 优雅降级**：无 embedding → 纯文本保存 + warning；有 embedding → 双写
- **get_memory / search / get_context FTS 回退**：无 embedding provider 时关键词搜索 insights
- **Insight embedding 回填**：daemon 启动时自动将纯文本 insights 升级为向量
- **MCP 工具 API 参考文档**：`docs/mcp-tools.md` 记录全部 19 个 MCP 工具
- **CONTRIBUTING.md**：新增贡献者指南

### Changed
- **db.ts God Object 拆分**：1869 行拆分为 10 个领域模块 + facade 类 + ESM re-export shim（`src/core/db/`）
- **测试覆盖率提升**：691 → 767 tests，67% → 75% lines

### Fixed
- Flaky hygiene test 时间戳竞态条件修复
- CJK insight 搜索增加 LIKE 回退
- Insight FTS 原子性（事务包裹）

### Removed
- **Viking/OpenViking 全部移除**：删除 `viking-bridge.ts`（851 行）、`viking-filter.ts`、7 个 Viking API 路由、Swift 设置页面
- 移除未使用依赖 `js-yaml`
- 清理 14 个未使用导出、53 个未使用导出类型

---

## [0.0.0.9] - 2026-04-09

### Changed
- **Biome 代码规范强制执行**：pre-commit hook（husky + lint-staged），178 个文件 lint 清理
- **安全 + 性能 + DX 综合升级**：code review 修复轮次

---

## [0.0.0.8] - 2026-04-07

### Added
- **AI Audit Log**：所有外部 AI 调用（embedding、摘要、标题生成、Viking）的审计日志
  - `AiAuditWriter` + `AiAuditQuery` + schema migration
  - 自动提取 token 用量（input/output/cost）
  - `/api/ai/*` HTTP 端点查询审计记录
  - VikingBridge observer proxy 方法

### Fixed
- Viking `pushSession` parts 格式修复、`findMemories` URI 修复
- Viking 从 `addResource` 切换到 `pushSession` + composite session ID
- `get_context` 改用 memory snippets 替代 resource URI mapping
- `search` 增加 `vikingMemories` 记忆感知管道

---

## [0.0.0.7] - 2026-03-24

### Added
- **竞争力追赶（Competitive Catch-up）**
  - Health Rules Engine：9 项环境健康检查 + 可注入 `ShellExecutor`
  - Cost Advisor：费用优化引擎 + `get_insights` MCP 工具
  - `get_context` 环境数据块：活跃会话、今日费用、工具使用、告警
  - Hygiene 页面（macOS app）
  - Transcript 工具调用/结果卡片 + 语法高亮
- **可观测性（SP3 系列）**
  - SP3a：结构化日志（ALS 自动关联、stderr JSON、PII 过滤、request-id 贯穿）
  - SP3b：系统指标收集（DB query 自动计时 Proxy、FTS/vector 子查询计时、HTTP 错误计数）
  - SP3b-alerting：AlertRuleEngine + 6 条性能告警规则 + `alerts` 表
  - SP3d：AI 视觉验证（Kimi + Claude VLM 对比截图 AI 审查）
  - SP3e：测试覆盖扩展（33 个新测试，copilot/MCP/indexer/web/viking 错误路径）
- **自动化测试（SP1 + SP2）**
  - 截图对比管线 + baseline 管理
  - Test fixture 自动生成 + schema 校验
  - Viking quality test 脚本

### Fixed
- SQLite busy_timeout=5000ms 防止 `database is locked`
- Keychain 授权对话框问题（Debug 构建跳过 Keychain）
- Settings onChange 在 load 时触发导致 Viking API key 丢失
- Viking 重复推送跳过已发送的会话

---

## [0.0.0.6] - 2026-03-19

### Added
- **macOS App 大重构**
  - 主窗口全新设计：Sidebar + Pages 架构
  - Session Pipeline Tiering：4 级会话分级（skip/lite/normal/premium）
  - Settings 重新设计：General/AI/Network/Sources 分区
  - 8 个 PR 系列功能：
    - PR1：Transcript 增强（颜色条、chips、查找、工具栏）
    - PR2：Session List 重写（SwiftUI Table、agent 过滤、项目搜索）
    - PR3：Top Bar（⌘K 搜索、Resume 按钮、主题切换）
    - PR4：Session Housekeeping（preamble 检测、tier 增强）
    - PR5：Usage Probes（采集器、DB、API、Popover UI）
    - PR6：Workspace（repos、detail、work graph）
    - PR7：Session Resume（GUI 对话框、CLI `engram --resume`、终端启动器）
    - PR8：AI Title（生成器、设置、indexer 触发、regenerate-all）
- **Popover Dashboard**：Menu bar 弹出窗口仪表盘（KPI 卡片、热力图）
- **UI Performance 优化**：虚拟滚动、懒加载、缓存

---

## [0.0.0.5] - 2026-03-16

### Added
- **OpenViking 集成**：外部语义搜索引擎接入（后于 v0.0.1.0 移除）
  - VikingBridge + VikingFilter
  - 会话自动推送到 Viking
  - `get_memory` MCP 工具

---

## [0.0.0.4] - 2026-03-10

### Added
- **AI Summary Redesign**：AI 摘要管线重构（多 provider 支持）
- **Popover Dashboard 设计**：menu bar 弹出窗口交互设计

---

## [0.0.0.3] - 2026-03-03

### Added
- **Web UI + 多机同步**
  - Hono HTTP 服务器 + 纯 HTML/JS 前端
  - `/api/sessions`、`/api/search`、`/api/stats` 等 REST 端点
  - 会话列表、详情、搜索、用量统计页面
  - SQLite-based 多机同步（pull-based，增量同步元数据）
  - 配置文件：`~/.engram/settings.json`
- **RAG 向量搜索基础**
  - sqlite-vec 集成（embedding 向量存储）
  - Ollama + nomic-embed-text 本地 embedding
  - OpenAI embedding fallback
  - 后台异步索引

### Changed
- **消息计数重设计**：精确区分 user/assistant/tool 消息数

---

## [0.0.0.2] - 2026-02-28

### Added
- **macOS SwiftUI 应用**
  - Menu bar 菜单栏应用 + Popover + 独立窗口
  - SessionList、搜索、时间轴、收藏夹、设置 UI
  - GRDB 数据库只读访问（Node 拥有 schema，Swift 只读）
  - Node.js daemon 子进程管理（`IndexerProcess`）
  - MCP Server（Hummingbird 2、TCP + Unix socket）
  - stdio ↔ Unix socket 桥接（CodingMemoryCLI）
  - LaunchAgent 登录自启动
  - 发布脚本（归档、公证、DMG 打包）
- **IDE 适配器（4 个）**
  - Cursor（SQLite cursorDiskKV）
  - VS Code Copilot Chat（JSONL kind:0 格式）
  - Antigravity（gRPC → JSONL cache，cascade client）
  - Windsurf（gRPC cascade adapter）
- **会话浏览增强**
  - Clean/raw 对话视图 + 系统注入过滤
  - Agent badge + 过滤 chips（Claude Code agent 子进程识别）
  - 会话排序、多选过滤、时间轴展开/折叠

### Fixed
- Antigravity gRPC 端口检测（lsof PID 精确过滤、TLS/明文端口区分）
- Antigravity 会话内容读取（GetCascadeTrajectory API、三级降级策略）
- 索引器去重一致性（缓存文件 vs .pb 文件大小）
- 孤儿 Node 进程清理（Xcode SIGKILL 后 pkill 旧进程）
- MCP Server 启动问题（HTTP/1.1 Unix socket、stamp 文件、write pool 泄漏、stdin 关闭退出）

---

## [0.0.0.1] - 2026-02-27

### Added
- **项目初始化**：TypeScript MCP Server 脚手架（Node.js 20+、ES modules、vitest）
- **核心架构**
  - `SessionAdapter` 接口定义（detect/listSessionFiles/parseSessionInfo/streamMessages）
  - SQLite 数据库层（better-sqlite3、WAL 模式、FTS5 全文搜索）
  - 会话索引器（全量扫描 + skip-unchanged 优化）
  - 文件监听器（chokidar 增量更新）
  - 项目名解析器（git remote / basename）
- **CLI 适配器（4 个）**
  - Codex CLI（`~/.codex/sessions/` JSONL 逐行流式读取）
  - Claude Code（`~/.claude/projects/` JSONL，路径编码解析）
  - Gemini CLI（`~/.gemini/tmp/` JSON，projectHash 反推）
  - OpenCode（`~/.local/share/opencode/` SQLite + JSON）
- **第二批适配器（5 个）**
  - iflow、Qwen、Kimi、Cline、MiniMax、Lobster AI
- **MCP 工具（7 个）**
  - `list_sessions` — 列出会话（按来源/项目/时间过滤）
  - `get_session` — 读取会话内容（分页，每页 50 条）
  - `search` — FTS5 全文搜索
  - `project_timeline` — 项目跨工具时间线
  - `stats` — 用量统计（按来源/项目/天/周分组）
  - `get_context` — 智能上下文提取（token 预算控制）
  - `export` — 导出会话为 Markdown/JSON

### Fixed
- Codex `environment_context` 系统注入过滤
- Claude Code `superpowers` skill injection 过滤
- Cline malformed JSON 处理
- Kimi readline stream 提前退出关闭
- Watcher watchMap 非空断言移除
