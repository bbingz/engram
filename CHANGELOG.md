# Changelog

All notable changes to this project will be documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/).

---

## [1.0.2] - 2026-04-29

### Fixed — macOS release builds are warning-clean (2026-04-29)

- Cleared Swift concurrency warnings in the project-move database writer/test helpers.
- Declared the AppIntents SDK dependency for release-built macOS targets so Xcode's metadata extractor stops emitting false-positive warnings.
- Added script phase inputs/outputs and restored dependency analysis for helper/icon bundling, removing Xcode build phase notes from release archives.

---

## [1.0.1] - 2026-04-29

### Fixed — Pi Coding Agent sessions now index as `pi` (2026-04-29)

- Added a first-class `pi` adapter for `@mariozechner/pi-coding-agent` transcripts under `~/.pi/agent/sessions`.
- Registered `pi` across Node scanning, file watching, MCP/search/list-session schemas, Web/macOS labels, transcript readers, and project-move source roots.
- Verified the local machine now indexes 177 Pi sessions, including `Plants-vs-Zombies` and `polycli`.

### Fixed — Remote node visibility for Pi sync (2026-04-29)

- Added `origin` / `node` statistics grouping so synced Raspberry Pi sessions can be counted by device instead of being hidden inside their tool source.
- Added `origin` filtering to session APIs and the Web UI session list, plus non-local node labels on Web/macOS session cards.
- Confirmed current local database has only `local` origin rows; Pi sessions require a configured and reachable sync peer before they can appear.

### Changed — GitHub public presentation refresh (2026-04-29)

- Reworked [README.md](README.md) as an English public landing page with badges, release/source install paths, MCP setup examples, privacy positioning, and Mermaid flow diagrams.
- Added [README.zh-CN.md](README.zh-CN.md) as the Chinese mirror, plus standard MIT [LICENSE](LICENSE) and GitHub issue templates for bug reports and feature requests.
- Restored explicit Web UI documentation and added Raspberry Pi / Linux headless guidance for running the Node daemon, MCP server, and Web UI without the macOS app.
- Updated public-facing metadata and stale docs copy: package description is now English, `CONTRIBUTING.md` no longer carries an old fixed test count, and `docs/mcp-tools.md` reports the current 26-tool surface.

### Shipped — Open-source clean-history publication (2026-04-29)

- **公开仓库切到干净单提交历史** —— 从已清理工作树创建 orphan `public-main`,并 force-push 为远端 `main`(`dadd3362 Initial public release`)。公开前删除旧远端 feature/fix 分支,并把 `v1.0` tag 移到同一个干净提交,避免 release 下载入口继续指向私有历史 refs。
- **Release + 仓库设置已核验** —— `bbingz/engram` 现在是 public repo,默认分支 `main`,description 已更新,GitHub secret scanning + push protection 已开启。`v1.0` release asset 保留;`Engram-1.0-universal.zip` SHA256 仍为 `0ca9e48bc60d62469bf50c90f57e33d4921582089c6987c21bfcc7087c61268e`。
- **公开前安全检查** —— public branch 只有 1 个 root commit;origin 上只保留 `main` 和 `v1.0`。HEAD 敏感字符串扫描未发现个人路径、Apple Team ID、旧私网 IP、Viking/OpenViking 残留或 credential material,仅命中预期的 redaction regex/docs。`npm run lint`、完整 `npm test`(113 files / 1276 tests)、unsigned macOS Debug build 均通过。
- **私有历史只保留在本地** —— 发布前完整历史已备份到 `~/codex-exports/engram-private-full-history-20260429.bundle`;本地 private-history branches 不得推送到 public remote。

### Shipped — Adapter parser hardening via 3-way review + 2 codex follow-ups (2026-04-28)

- **4 commit 闭环修补 14 个 session adapter** —— 起因是用户问"所有解析器是否都能正确解析 AI sessions 内容"。流程:并行 3-way 静态 review(Claude general-purpose + Codex/GPT + Gemini→挂→Qwen→挂)+ 主对话覆盖度审查 + 真实 `~/.claude` `~/.codex` 数据 cross-check → 13 P1/P2 ship → Codex review 出 3 medium + 1 low → 修 → 再 review 出 3 partial + 1 low + 6 gaps → 再修。最终 `1206 → 1244` tests, biome clean。
  - **`b27af8d`** — 13 parser fixes:
    - codex 4 条:`model` 取自 `response_item.payload.model`(非 `model_provider`,真实数据 `~/.codex/sessions/.../rollout-*.jsonl` 的 `model="gpt-5.3-codex"` 而 `model_provider="openai"`);`lastTimestamp` 任何 ts 行都更新(不止 message payload);`function_call`/`function_call_output` 现在计入 `toolMessageCount` + stream yield `role='tool'`(之前完全丢弃);assistant `payload.usage` 映射到 `Message.usage`。
    - claude-code:`tool_result` 顶层 `type='user'` 的行 yield `role='tool'`(之前 stream 标 user 与 `toolMessageCount` 不一致);引入 `MESSAGE_TYPES Set` 显式登记,sessionId 在 filter 前抓(适配真实数据演进出的 5 类新 type:`attachment` / `queue-operation` / `permission-mode` / `last-prompt` / `file-history-snapshot`)。
    - cline 加 `modelInfo.modelId` 提取;iflow 加 `message.model` 提取;qwen `message.model` fallback;qwen/iflow `extractContent` 改 `parts.join('\n')` 与 gemini-cli 对齐(多 part 不再丢)。
    - kimi `streamMessages` 现在带 timestamp(line ts 优先,否则按 wire turn 配对);`startTime` 兜底 mtime 前先扫 line ts。
    - vscode `assistantMessageCount` 用真实 `extractAssistantText` 非空数(非 1:1 padding);`cwd` 从 `workspaceStorage/<hash>/workspace.json` 读 `folder`/`configuration` URI(配合 `.code-workspace` 多根解析)。
    - cursor `cwd` 从 `composerData.context.folderSelections`/`fileSelections` heuristic 推断(真实 Cursor 不绑 workspace,best-effort)。
    - windsurf/antigravity `readLines` `try/finally` close + destroy(防 fd 泄漏);`JSON.parse(firstLine)` 二级 try。
    - copilot YAML value 剥引号配对。
  - **`f8d7109`** — codex review #1 闭环 3 medium + 1 low:kimi `readTurnTimestamps` 改返 `{begin, end?}[]` paired turns(原独立数组在 TurnEnd 缺失时位移整个尾段);vscode multi-root `.code-workspace` 真解析 `folders[0].path`(原代码把 `.code-workspace` 路径直接当 cwd);claude-code 加 `!startTime` 守卫防 metadata-only 文件污染索引;`readTimestamps` 合并到 `readTurnTimestamps` 排除心跳/元数据。
  - **`fbbc504`** — 测试覆盖 + 顺手修 vscode 2 个 URI bug:`file://localhost/path` 把 localhost 算进路径;`vscode-remote://`、`vsls://` 等非 file URI 被原样当 cwd。`decodeFileUri` 现在严格只接受 `file://`,strip `localhost/` authority,malformed percent-encoding 走 catch 返空。补 codex `function_call` 边界 / kimi 无 wire fallback / vscode workspace.json 边界 / cursor 空 folder 回退 / qwen+iflow 多 part join 共 14 条测试。
  - **`2fa2a2a`** — codex review #2 闭环 3 partial + 4 gaps:kimi `turnIdx` 状态机重写 —— 由 `lastRole` 比较改成 binding-state(`userBoundInTurn`/`asstBoundInTurn`),user 推进当前 turn 任意 slot 已绑定,assistant 仅推进自己 slot 已绑定,handles `u-u-a` / `u-a-a` / `u-a-a-u` 全部正确;vscode `.code-workspace` 现在也接 `{uri: "file://..."}` 形式 folder(非仅 `{path}`)+ Windows-style `file:///C%3A/...` 解码测试;claude-code `startTime` guard 改 `totalMessages > 0`,fallback 到 `fileStat.mtimeMs`(原 guard 误丢无 timestamp 但有有效消息的合法文件);补 codex 重复 `function_call` 不去重 / cursor `folderSelections[1]` 不被扫(fall through 到 file)/ cursor symlink 不 realpath 三条断言现状的测试。
- **覆盖度审查独家发现**(主对话从 user 真实 `~/.claude/projects/-Users-example--Code--ShortcutRadar/...jsonl` 头 200 行抓):claude-code 已演进出 5 类新 record type(`attachment` 10 行 / `queue-operation` 9 / `permission-mode` 6 / `last-prompt` 5 / `file-history-snapshot` 1),adapter 当前显式过滤为非消息 type;5 个 adapter fixture 自 2026-02-27 起未刷新(60+ 天):antigravity / cline / cursor / vscode / windsurf,留作后续独立 task。
- **3-way review 实战观察**:Gemini(`gemini-3.1-pro-preview` HTTP 429 capacity exhausted)和 Qwen(max session turns)两次第三路都失败,主对话兼任第三 reviewer + 用真实数据实证修补;Claude general-purpose 报 14 finding、Codex 报 7 finding,重叠率仅 1 条(kimi timestamp),说明跨模型 review 高互补。`feedback_agent_review_verify_before_trust` memory 的 ~45% 误报率经验在本次再次成立 —— 每条 P0/P1 都独立 Read 源文件 + 用真实 user data cross-check 才接纳。

### Shipped — project_move pipeline port to Swift (2026-04-28)

- **MCP behavioural gap closed** —— `project_move` / `project_archive` / `project_undo` / `project_move_batch` 4 个工具从 Swift `EngramMCP` 跑直达 `EngramService` 原生 pipeline,不再 throw `unsupportedNativeCommand`。MCP `tools/list` 工具数 22 → 26。覆盖 `src/core/project-move/` 全部 16 模块 + `src/tools/project.ts` handler 半部 = ~3,455 行 Node port 到 Swift,分 6 commits ship(`9b9233e`/`65d0e97`/`0d6db00`/`d00593a`/`281b687`/`d4ecb9b`):
  - **Stage 4.1** — `MigrationLogStore.swift` (write half) + `MigrationLogReaders.swift` (GRDB-backed read half),三相状态机 startMigration → markFsDone → applyMigrationDb → finishMigration + watcher 守门 + stale 清理。`applyMigrationDb` 用 `:old`/`:new` 命名占位符 + `pathMatch`/`rewrite` SQL helper(避免按位置塞 33 个参数),substr boundary check 防 LIKE 通配符泄漏。Stage 3 协议 `MigrationLogReader` / `SessionByIdReader` 加 `throws`(GRDB 错误不能静默吞)。+16 测试。
  - **Stage 4.2** — `Orchestrator.swift` 7 步 pipeline + LIFO compensation,~700 行单文件。`URL.standardizedFileURL.path` 做 path canonicalize(对齐 Node `path.resolve`,纯 lexical 不解 symlink);`realpath(3)` 在 APFS 大小写不敏感场景区分真碰撞 vs 大小写改名;`withTaskGroup` bounded concurrency(50 worker)patch JSONL;FS 工作不持写事务(每个 `writer.write {}` 即开即关)。SIGINT handler 故意未 port —— launchd helper 无 controlling terminal;`cleanupStaleMigrations` 启动时清理崩溃残留。+10 集成测试(validation / dry-run / happy path / DirCollision / LockBusy / 多源)。
  - **Stage 4.3** — `Archive.swift` 4 条建议规则(YYYYMMDD 前缀 → 历史脚本 / 空 or README → 空项目 / .git+content → 归档完成 / 否则 ambiguous 让用户指定)+ `ArchiveCategory` 枚举(原始 CJK 值)+ aliases 表(`historical-scripts` / `archived-done` 等英文别名也归一到 CJK),Round-4 critical fix 保留:HTTP 层不再因为穿英文别名而创出英文目录。+16 测试。
  - **Stage 4.4** — `Batch.swift` JSON-only(无 Yams SwiftPM 依赖,Swift MCP boundary 本就 JSON);schema v1 严格 parser(version、ops、`dst|archive` XOR、`continue_from` 拒绝)+ runner(`stopOnError` 默认 true、`~/foo` 经 override home 展开、archive ops 自动建 `_archive/<category>/` 父目录)。+14 测试。
  - **Stage 4.5** — `MCPToolRegistry.unavailableNativeProjectOperationTools` 清空,4 个工具走标准 `serviceUnavailable` 路径(operational category)。`mcp-golden/tools.json` 22 → 26;`mcp-golden/initialize.result.json` instructions 同步;`ServiceUnavailableMutatingToolTests` 4 个 `*IsUnavailableInSwiftOnlyRuntime` 重命名为 `*FailsClosedWithoutServiceSocket` 翻测断言。
  - **Stage 4.6** — `EngramServiceCommandHandler` 4 个 `unsupportedNativeCommand` stub 替换为真 pipeline 调用:`projectMove → Orchestrator.run`;`projectArchive → Archive.suggestTarget + Orchestrator.run(archived: true)` + 自动建 `_archive/<category>/` 父目录;`projectUndo → UndoMigration.prepareReverseRequest + Orchestrator.run(rolledBackOf:)`;`projectMoveBatch → Batch.parseJSON + Batch.run`,`yaml` 字段名保留(IPC 兼容),内容改 JSON。`mapPipelineResult` helper 把 `PipelineResult` 翻成 `EngramServiceProjectMoveResult`。`testProjectMigrationCommandsFailClosedWithoutLegacyBridge` 重写为 `testProjectMigrationCommandsSurfacePipelineErrors`(断 commands 走到 pipeline,not UnsupportedNative)。
- **UI gate flip** —— `ProjectMoveServiceError.swift` `nativeProjectMigrationCommandsEnabled = false → true`;ProjectsView + RenameSheet/ArchiveSheet/UndoSheet 13 处 gate 重新激活。
- **测试矩阵全绿**:`EngramCoreTests` 231(+40 新)/ `EngramServiceCore` 22 / `EngramMCPTests` 39。`ArchiveError` 加 `LocalizedError`(避免 migration_log error 列吞成 generic Cocoa 字符串)。
- **设计决策记录**:
  - **`ProjectMoveError` 协议**做 Node 动态 `err.name` 反射的 Swift 替代;每个具体错误(`LockBusyError` / `DirCollisionError` / `SharedEncodingCollisionError` / `UndoNotAllowedError` / `UndoStaleError` / `InvalidUtf8Error` / `ConcurrentModificationError`)都实现 `errorName` / `errorMessage` / `errorDetails`,`RetryPolicyClassifier` switch on errorName。
  - **mtime-CAS race test 推迟**(`testConcurrentModificationErrorContractFields` 只断错误类型契约,full path 在 orchestrator 集成测试中走过)。Foundation 同步 API 难 deterministic 驱动 Node `queueMicrotask` 的双 stat race。
  - **`SecRandomCopyBytes` 避用** —— `arc4random_buf` 覆盖 temp 名随机性,免 `Security.framework` import。
  - **每个 `MigrationLogStore` 写操作独立 `pool.write {}`** —— 避免 orchestrator 长跑(数十 GB 跨卷复制)期间持写事务阻塞其他 service write 命令。

### Shipped — MCP cutover Node→Swift + observability hardening (2026-04-28)

- **Node MCP 路径退役** — `~/.codex/config.toml` 和 `~/.claude.json` 的 `mcp_servers.engram` / `mcpServers.engram` 切到 `/Applications/Engram.app/Contents/Helpers/EngramMCP`(Swift 原生)。Swift MCP helper 自 commit `46814f9` 起就 ship 了但默认未启用,客户端配置才是真正的 cutover。Node `dist/index.js` 保留作 fallback,生产路径不再 spawn。诊断显示 chokidar 4.x 在 macOS 上非递归监视产生 ~17,727 FSWatcher handle/进程,`process.exit(0)` 在 17K handle teardown 期间挂住导致 SIGTERM 无效退出 — Codex.app spawn-per-tool-call 模式累积出 13 GB 僵尸内存。切换后 RAM 13 GB → 100 MB(单进程 ~470 MB → ~11 MB,~26×)。
- **EngramService 接 os_log**(`74b934a`):新增 `ServiceLogger`(`com.engram.service` subsystem,5 个 category)。之前 `EngramServiceLauncher.drain(pipe:)` 把子进程 stdout/stderr 路由到主 app `EngramLogger.daemon` 的链路在生产无声 4 天 — 改为 Service 进程**直接**走 os_log,不再依赖父 drain。`log show --predicate 'subsystem == "com.engram.service"'` 现可直接用。
- **启动 WAL TRUNCATE**(`74b934a` → `4cc7a34` → `2807259` 三轮修):`PRAGMA wal_checkpoint(PASSIVE)` 永远不收缩 WAL 文件磁盘大小,生产 WAL 4 天累积到 144 MB。`EngramServiceRunner.run()` 在 `ready` event 之后启动 fire-and-forget Task 跑 `wal_checkpoint(TRUNCATE)`(必须在 ready 之后,因为 TRUNCATE 触发 writer busy_handler 最坏等 30s 会撞 launcher 5s 健康探针);shutdown 路径 `await truncateTask.value` 而非 `cancel()`(SQLite PRAGMA 不感知 Task 取消)。WAL 144 MB → 0 B。
- **5 份 stale `.bak` 备份移到 `~/.Trash`**(2026-04-20 zombie-rescue 残留,共 1.7 GB)。
- **Codex 两轮 adversarial review** 全部 adjust 落实:第一轮发现 startup TRUNCATE 同步阻塞 ready 撞 5s 健康检查 + path 用 `.public` 泄漏 + 缺 busy-reader 测试,修了前两个,测试 gap 在 commit message 诚实标注理由(`SQLiteConnectionPolicy.minimumBusyTimeoutMilliseconds = 5000` 强制下限,deterministic 测试需 fork 进程或 30s+ 等待);第二轮发现 Task 创建时序仍靠调度偶然 + cancel 不 await,修齐。
- **测试**:`ServiceWriterGateTests.testCheckpointTruncateShrinksWalAfterPendingWrites`(seed 1,600 INSERT,断言 PASSIVE 后 WAL > 0,TRUNCATE 后 = 0)。
- **未做(单开 plan)**:`project_move/project_archive/project_undo/project_move_batch` 4 个 MCP 工具 — `EngramServiceCommandHandler` 4 个 stub 仍 throw `unsupportedNativeCommand`,需要把 `src/core/project-move/` 整个 pipeline(3,455 行 / 16 模块)port 到 Swift,3-5 天扎实工程。

### Shipped — Swift single-stack migration v3 (2026-04-24)

- **Node daemon 全量迁成 Swift 原生 EngramService**(单 commit `6a47273` + 3 轮 review 修复 `6d732ca` → `3e3d45c` → `88d5e01`)。新增 `EngramService` helper(Unix socket IPC)/ `EngramCoreRead` + `EngramCoreWrite` 双模块(read-only 给 App/MCP/CLI,write 仅给 Service)/ `Shared/EngramCore` 12 个 Swift adapter / 27 个 MCP 工具契约保持。Node `src/` 保留作 parity baseline,计划 2026-06-01 前分 3 阶段删除。
- **多 AI 交叉 review(15 路并行 Kimi/MiniMax/Qwen/Gemini/MiMo-via-polycli)+ 人工裁定**,证实第一轮 Explore agent review 有 ~45% 误报(C1/C2/C3/C5/C6/H2/H3)。教训:大规模 review 不能信单轮 agent 的 file:line 断言,必须独立 Read 原文。v2→v3 修复过程与方法论记录在 `docs/swift-single-stack/2026-04-24-review-feedback{,-v2,-v2-followup,-v3}.md`。
- **v3 三轮修复核心**:
  - **Dead Node HTTP 链路清零**(`DaemonClient.swift` -433 / `DaemonHTTPClientCore.swift` -192 / `EngramLogger.forwardToDaemon` -21 / `AppEnvironment.daemonPort` 字段删除),App/MCP/CLI 全部走 Unix socket;`EngramServiceLauncher.drain(pipe:)` 用 `readabilityHandler` 消费 stdout/stderr 防止子进程写阻塞死锁。
  - **IPC 安全加固**:`UnixSocketServiceServer` 的共享 JSONEncoder/Decoder 改 per-request 新建(消除数据竞争);加 `ServiceConnectionLimiter(value: 32)` 并发上限 + 10s socket timeout;frame max length 从 32MB 降到 256KB(X6 防嵌套 DoS);`TranscriptExportService` 3 条正则脱敏(api_key/bearer/sk-/ghp_/xoxb-)+ 写入后 chmod 0600;`linkSessions` 按 source 白名单 + `.ssh`/`.aws`/`.gnupg`/`.kube`/`.docker`/`.1password`/`Keychains` 黑名单防 symlink 攻击。
  - **辅助表 schema 幂等迁移**(`EngramMigrations.migrateAuxTablesToV2`):10 张表(session_tools/session_files/logs/traces/metrics_hourly/alerts/ai_audit_log/git_repos/session_costs/insights)每张都走 `__engram_<t>_v2` shadow + `INSERT ... FROM old` + `columnExpr(..., fallback:)` 逐列兼容 + DROP+RENAME。`logs.source CHECK` 用 `CASE WHEN IN (...)` 防违反值;`traces.span_id` 空则补 `hex(randomblob(16))` UUID;`ai_audit_log.total_tokens` 按 `prompt+completion` 重算。写 `metadata.swift_aux_schema_version=2` 不污染 Node 的 `schema_version`,保留双向兼容。
  - **insights 软删下线**:对齐 Node 当前行为,迁移时 `DELETE FROM insights_fts WHERE insight_id IN (SELECT id FROM insights WHERE deleted_at IS NOT NULL)` 清 FTS,再 `INSERT ... WHERE deleted_at IS NULL` 跳过软删行。
  - **SwiftIndexer 流式化**(`streamSnapshots()` public + `continuation.onTermination = scanTask.cancel()` + `try Task.checkCancellation()`),session-level 不再 collect-to-array;`indexAll`/`collectSnapshots` 复用同一流。单文件(如 Gemini JSON 全 load)OOM 是 adapter 内部独立问题,留待后续。
  - **测试**:`MigrationRunnerTests.testMigratesLegacyAuxiliaryTablesToCurrentWritableSchema` 预填 v1 schema + 数据 → 跑迁移 → 逐表断言新列可写 + 老列已消;`StartupBackfillTests` 的 quality score 从 magic number 72 改为 `expectedQualityScore(...)` 可计算期望 + codex originator 加反例(`originator="Codex CLI"` 不应触发 `dispatched`);`IndexerParityTests.testIndexAllFlushesSnapshotsInBoundedBatches` 断言 205 session / batchSize 100 → `[100, 100, 5]`。
- **Project UI 按钮冻结**(`ProjectMoveServiceError.swift` `let nativeProjectMigrationCommandsEnabled = false`):ProjectsView + Archive/Rename/UndoSheet 共 13 处 gate,在 Swift 原生 project migration pipeline port 完前 UI 入口不可见。Service 层对应 `projectMove/projectArchive/projectUndo/projectMoveBatch` 仍抛 `unsupportedNativeCommand`(fail-closed)。
- **CI 门禁**:`.github/workflows/test.yml` swift-unit job 后跑 `scripts/db/check-swift-schema-compat.ts --fixture-root tests/fixtures`,老改 Swift schema 不同步 Node 直接红灯。
- **Stage 5 文档诚实化**:`docs/verification/swift-single-stack-stage4.md` 承认 projectMove 等 "intentionally unavailable until native migration pipeline is ported";`app-write-inventory.md` 从 "Conflict" 改为 "Resolved"。
- **已知未做(不阻塞 ship)**:L-1 JSON 嵌套深度硬检查(Unix socket 仅本用户可达,defense-in-depth,可进安全加固 PR);单文件级 OOM(GeminiCliAdapter.parseSessionInfo 全 load JSON,属 adapter 内部重构)。

### Shipped — Phase C Swift MCP helper (2026-04-23)

- **Native Swift MCP helper bundled into `Engram.app/Contents/Helpers/EngramMCP`**（`macos/EngramMCP/`, `macos/project.yml`, `macos/scripts/copy-mcp-helper.sh`）：26 个 MCP 工具全量 port 到 Swift,读走 GRDB readonly pool,写经 daemon HTTP API (`actor: "mcp"`,strict 模式无 direct-SQLite fallback)。Engram target 声明 `EngramMCP` 为非链接依赖,postbuild 脚本在 Xcode codesign 前把 helper ditto 到 `Contents/Helpers/`,外层签名天然覆盖。Node `dist/index.js` 保留作 fallback;用户改 `.claude/mcp.json` 的 `command` 就能切换(参见 `docs/mcp-swift.md`)。
- **29 个 byte-equivalent contract 测试**(`macos/EngramMCPTests/EngramMCPExecutableTests.swift`):把 helper 作为 subprocess 起,灌 JSON-RPC,断言字节级等同于 check-in 的 `tests/fixtures/mcp-golden/*.json`;写类工具通过 `MockDaemonServer` 拦截 HTTP 流量。Generator (`scripts/gen-mcp-contract-fixtures.ts`) **必须用 `TZ=UTC` 跑**,否则 golden 时间戳按 host TZ 产生 (+8h CST) 而 xctest 在 UTC 下输出,5 个涉及 startTime/endTime 的 golden 会静默偏移 → 已在 generator header 注明。
- **Release 部署 & 回归全绿**:`/Applications/Engram.app` Release 构建含 EngramMCP 10.6M helper,codesign `--validated` Helpers/EngramMCP;EngramMCPTests 29/29 + `npm test` 1210/1210 在 main 上均绿。
- **2 个 MVP TODO 带标注**(`macos/EngramMCP/MCPStdioServer.swift`):`TODO(mcp-version-negotiation)` 目前 hardcode `"2025-03-26"` 协议版本,`TODO(swift6-async-loop)` `DispatchSemaphore` stdio 异步-同步桥接 —— 留到 Swift 6 迁移再动,非 ship 阻塞。

### Fixed — monitor/session-repo start_time 字符串格式跨日比较 (2026-04-23)

- **`checkDailyCost` / `checkCostBudget` / `countTodayParentSessions` 4 处 SQL 双侧包 `datetime()` 归一**(`src/core/monitor.ts:141,190,231`, `src/core/db/session-repo.ts:422-423`)。`start_time >= ? AND start_time < ?` 之前做纯字符串 lex 比较,参数来自 `Date.toISOString()`(`"2026-04-22T16:00:00.000Z"`)而 `datetime('now')` 返 `"2026-04-22 22:46:15"`;UTC 日期前缀相同时退化到 char-10 `' '(0x20)` vs `'T'(0x54)`,SQLite 格式行被判更小漏掉。本地 CST 00:00–08:00(UTC 日期与 `startUtcIso` 前缀同步)的 8 小时窗口周期性触发,monitor cost 告警和菜单栏 today-parent 徽章产生假零。
- **回归用例保留不改**:`tests/core/monitor.test.ts` 的 3 个失败用例(用 `datetime('now')` 插 session)恰好暴露此缺陷,是天然的回归守护。
- **索引权衡**:`idx_sessions_start_time` 在这 4 处查询里本就不起决定性作用(均带 JOIN 聚合或复合 filter),`datetime(start_time)` 包裹不可走索引的代价可忽略。

### Fixed — defensive logging + daemon auto-restart (2026-04-22)

- **ai-audit silent catch 除掉**（`src/core/ai-audit.ts`）：constructor prepare / record() / cleanup() 三处 `catch {}` 改成 `console.error('[ai-audit] ...', err)`。daemon stderr 经 IndexerProcess 转发到 os_log（subsystem `com.engram.app`, category `daemon`），Console.app 可见。历史上 audit 写失败纯静默，只有 `return -1` 一个几乎没人查的返回值暴露
- **metrics.flush() 加外层 try/catch**（`src/core/metrics.ts`）：batch INSERT throw 不再 propagate 到 setInterval 的 uncaughtException。失败时 `console.error('[metrics] flush failed, dropped N entries', err)`，buffer 已 `splice(0)` 所以下个周期干净重试
- **IndexerProcess 自动重拉 daemon**（`macos/Engram/Core/IndexerProcess.swift`）：之前 daemon 崩溃 `terminationHandler` 只设 `status = .stopped`，需要用户手动重启 Engram.app 才能恢复。加 `userInitiatedStop` / `restartAttempts` / `restartTask` / `lastStartArgs` 字段 + `scheduleAutoRestart()` 方法：非 user-initiated 退出时 5 秒 backoff 后 `start()`，上限 5 次，稳定 tick（`ready/indexed/rescan/sync_complete/watcher_indexed`）重置计数。实测 `kill daemon-pid` → ~10 秒内新 daemon 在 3457 listen 就绪
- 单测 +2：`tests/core/ai-audit.test.ts` "logs to console.error when record fails" + `tests/core/metrics.test.ts` "does not throw on flush failure and logs the drop"
- **时区陷阱教训**：SQLite `datetime('now')` 返回 UTC，所有 engram ts 列（ai_audit_log、metrics、insights.created_at、sessions.indexed_at、git_repos.probed_at、session_index_jobs）均 UTC ISO-8601。debug 本轮 30 分钟 false alarm "daemon 没写 audit/metrics" 根因就是 `WHERE ts > '2026-04-22T16:00'`（当 CST 写）vs UTC ts 静默对错零匹配。lesson 记在 memory/feedback_timezone_trap.md
- `npm run build` ✓、`npm test` 全过、`xcodebuild` SUCCEEDED、`/Applications/Engram.app` 重部署 + daemon auto-restart 生产实测

### Fixed — 6-way Review Round 3：envelope 统一 + 并发回归测试 (2026-04-22)

- **R3a 并发回归测试**（`tests/web/insight-api.test.ts`）：Kimi Important 指 save_insight dedup→write 有 race。代码审查后结论：**不存在**。text-only 路径里 `findDuplicateInsight` 到 `saveInsightText` 之间没 await，better-sqlite3 同步 + Node 单线程 = 原子。embedded 路径本就不 reject 重复（只 warn），也不是 race 场景。**加一个 concurrent Promise.all 回归测试**钉死这个不变量，未来改动引入异步间隙会立即暴露
- **R3b `/api/insight` 错误 envelope 统一**（`src/web.ts`）：Superpowers Important 指 `/api/insight` 返回 `{error: "string"}`，与 `/api/project/*` 的 `{error: {name, message, retry_policy}}` 不一致。改成统一 envelope：400 validation 走 `validationError('MissingParam'/'InvalidInsight', msg)`、500 server error 用 `{name:'InsightSaveFailed', retry_policy:'safe'}`。两个 insight-api 测试更新为断言 envelope 形状
- **Defer 不修项**（文档化，不在这次改动）：
  - orchestrator dry_run 遇 git-dirty 先抛异常（Gemini Important）—— pre-existing 行为，属于 orchestrator-level UX bug，单独 ticket
  - `mcpStrictSingleWriter` toggle 不热更新（Superpowers）—— UI 帮助文案已声明 "Takes effect on next MCP spawn"
  - Step 4 commit 先于 Step 3 land（Superpowers Nit）—— 历史不重写
  - DELETE with body 在代理下的剥离风险（Kimi Nit）—— loopback 不触发
- `npm run build` ✓、`npx vitest run` **1208/1208** ✓（+1 并发回归测试）、biome 干净

Phase A + Phase B + 6-way review triage **全部完工**。剩下被动观察 24h 锁错误收敛。

### Fixed — 6-way Review Round 2：batch 迁移 + dst 透出 + 声明前置 (2026-04-22)

- **M3 `project_move_batch` 接入 HTTP**（6-way review 发现的 Phase B 漏网第 7 个写工具）：
  - 新增 `POST /api/project/move-batch`（`src/web.ts`）：调 `runBatch(db, doc, {force})`，actor 由 runBatch 内部硬编码为 `'batch'`（符合原有审计语义）
  - MCP dispatch `src/index.ts` `project_move_batch` 改走 HTTP，带 fallback helper
  - 契约测 2 个：缺 yaml → 400 MissingParam、dry-run 完整管道 smoke
  - DB 写工具覆盖从 6/6 升级为 **7/7** ✅（至此 Phase B 真正完整）
- **S2 archive 响应补 `dst`**（`src/tools/project.ts:242, 224` + `src/index.ts:544-553`）：MCP callers（AI agents）原本拿不到归档落地目录。直接路径、dry_run 路径、HTTP 转换路径三处同步加 `dst`，形状对齐（`archive: {category, reason, dst}`）。Swift UI 走的是 `suggestion.dst`，独立字段不受影响
- **S3 `strictSingleWriter` 声明前置**（`src/index.ts:93`）：从 line 412 挪到 `daemonClient` 旁边，消除"先用后声明"的 TDZ 依赖，读起来自然
- `npm run build` ✓、`npx vitest run` **1207/1207** ✓（+2 batch 契约测）、biome 干净
- **需要 daemon 重新部署**：新增 `/api/project/move-batch` 端点

### Fixed — 6-way Review Round 1：安全 + 锁 + fallback 三个 Must-fix (2026-04-22)

6 家独立 review（codex / gemini / kimi / minimax / qwen / superpowers-reviewer）出来的 critical / important 里合并同类项抽了最紧要的三个。

- **M1 撤销 `actor:'mcp'` 的 `$HOME` bypass**（`src/web.ts` 的 /api/project/{move,archive}）：原设计让 actor='mcp' 跳过 $HOME 约束，理由是"MCP 是本地信任对等"。4 家 reviewer 同时标为 Critical：**trust 从不可信 body 字符串派生** —— 任何本地进程都能 POST `{actor:'mcp', src:'/etc/...'}` 绕过。改法：`actor` 字段保留作 audit（已透传到 `migration_log.actor`），但所有 actor 都受 `$HOME` 约束。MCP 调 project_move 本来就在 `~/-Code-/` 之下，不影响正常使用
- **M2 周期 WAL checkpoint 改 `PASSIVE`，启动保留 `TRUNCATE`**（`src/daemon.ts:454`）：原代码周期 `TRUNCATE` 跑在 daemon 主连接上，better-sqlite3 同步 API + 30s `busy_timeout` → 最坏阻塞事件循环 30s。`PASSIVE` 不阻塞，能搬多少搬多少。启动时仍 `TRUNCATE`（此时我们独占 DB）
- **S1 `shouldFallbackToDirect` envelope 判断放宽**（`src/core/daemon-client.ts:155`）：原来只看 `{error:...}`，旧 daemon 返 `{message:...}` 结构 404 会被误判成"端点缺失"静默降级。改成 **任何 JSON object body 的 404/405/501 都 bubble up**，只有 body 为 undefined/字符串才算 Hono 默认的未命中路由
- 测试更新 `project-api.test.ts` `actor:mcp still respects $HOME`（原来测 bypass 存在，现在测 bypass 已撤）+ 3 个新 `shouldFallbackToDirect` 单测覆盖 `{message}` / 空对象 / string-body 分支
- `npm run build` ✓、`npx vitest run` **1205/1205** ✓（+3）、biome 干净

### Added — Phase B Step 6B：mcpStrictSingleWriter 开关上 Swift UI (2026-04-22)

`mcpStrictSingleWriter` 原本只能手改 `~/.engram/settings.json`，现在 Settings → Network 新增 `MCP` GroupBox 里有个 Toggle。

- `macos/Engram/Views/Settings/NetworkSettingsSection.swift` 加 `MCP` GroupBox + `Strict single writer` Toggle
- 走现成的 `readEngramSettings()` / `mutateEngramSettings()`、`isLoadingSettings` 防抖模式（与同文件里的 Sync 设置一致）
- Help text 解释 trade-off：ON = daemon 不可达时 MCP 写直接失败（零锁竞争，依赖 daemon 可用性）、OFF（默认）= 降级到本地直写（resilient）
- 生效时机：下次 MCP spawn（MCP 启动读 `fileSettings` 一次，保留到进程结束）
- `xcodebuild Release` ✓、TS `npm test` **1202/1202** ✓、已部署

Phase A + Phase B **正式全部完工**。剩下 Step 6A 是跑 24h 观察锁错误是否归零——被动的。

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
- **Python `mvp` 退役**：`/Users/example/-Code-/_项目扫描报告/mvp` 变 50 行 bash shim delegating to `engram project`；Python 原版备份为 `mvp.py-retired-20260420`
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
- **本地语义搜索**：切换到 sqlite-vec + FTS5 trigram + RRF 融合
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
- **外部语义搜索集成全部移除**：删除旧 bridge/filter、HTTP 路由和 Swift 设置页面
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
- **AI Audit Log**：所有外部 AI 调用（embedding、摘要、标题生成）的审计日志
  - `AiAuditWriter` + `AiAuditQuery` + schema migration
  - 自动提取 token 用量（input/output/cost）
  - `/api/ai/*` HTTP 端点查询审计记录

### Fixed
- `get_context` 改用 memory snippets 替代 resource URI mapping
- `search` 增加 memory snippets 记忆感知管道

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
  - SP3e：测试覆盖扩展（33 个新测试，copilot/MCP/indexer/web 错误路径）
- **自动化测试（SP1 + SP2）**
  - 截图对比管线 + baseline 管理
  - Test fixture 自动生成 + schema 校验

### Fixed
- SQLite busy_timeout=5000ms 防止 `database is locked`
- Keychain 授权对话框问题（Debug 构建跳过 Keychain）

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
