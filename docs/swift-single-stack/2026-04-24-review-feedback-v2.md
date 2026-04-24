# Engram Node→Swift 单栈迁移 Review v2(修正版)

**状态:** 修正 v1 误报 + 新增真实发现,发给 Codex 时请优先以本版为准
**来源:** v1(`2026-04-24-review-feedback.md`)+ 15 路外部 AI 交叉验证(Kimi / MiniMax / Qwen / Gemini / MiMo via polycli-opencode,各 3 路)+ 人工 Read 源码裁定
**Commit:** `6a47273 feat: migrate mac app to swift service stack`
**日期:** 2026-04-24

---

## 第 0 章:给 Codex 的头号提示 —— 先看这段

**v1 报告有 ~45% 误报**。Codex 如果已经按 v1 开始改,请先把以下 v1 条目**全部回滚或停止**,然后再读第二/三章的真实 Critical 清单。

### v1 误报清单(不要白改!)

| v1 编号 | v1 原结论 | 裁定 | 真实情况 |
|---|---|---|---|
| **C1** | `memory_insights` 表 Swift 迁移缺失 | ❌ **误报** | `EngramMigrations.swift:301-311` 明确 `CREATE TABLE IF NOT EXISTS memory_insights`,列与 Node 等价 |
| **C2** | 无 PASSIVE WAL checkpoint | ❌ **误报** | `SQLiteConnectionPolicy.swift:48` 有 `wal_autocheckpoint = 1000`;`EngramServiceRunner.swift:53-65` 有 20s 周期 `checkpointPassive()` Task |
| **C3** | 双栈并发无进程锁 | ❌ **误报** | `ServiceWriterGate.swift:31-36` 已获取 `<db-dir>/.lock` 的 `flock(LOCK_EX\|LOCK_NB)` 作为数据库级顶层锁;Service 是唯一写者(App/CLI/MCP 都不 import EngramCoreWrite) |
| **C5** | Service 死了没人拉 | ❌ **误报** | `EngramServiceLauncher.swift:72-120` 有 `startHealthMonitor` + 5s probe + restartAttempts(默认 3)+ `.degraded` fallback;`App.swift:77-85` 确实调用了 |
| **C6** | FTSRebuildPolicy 用 DELETE 而非 DROP | ❌ **误报** | `FTSRebuildPolicy.swift:14` 就是 `DROP TABLE IF EXISTS sessions_fts` |
| **H2**(前半) | `outputHome` 仅 `hasPrefix("/")` | ❌ **误报** | `TranscriptExportService.swift:39-79` 完整实现:`hasPrefix("/")` + 拒 `..` + HOME 白名单 + `rejectSymlinkAncestors` lstat 逐级检查 |
| **H3** | Gemini originator 大小写不一致 | ❌ **误报** | Swift 两个 adapter 都走 `OriginatorClassifier.isClaudeCode`(`SessionAdapter.swift:21-31`),做 trim+lowercase+`_`→`-`+空格→`-` normalize。**Swift 已经修掉了 Node 两个 adapter 不一致的遗留**,比 Node 更正确 |

**以上 7 条 v1 结论作废,请 Codex 不要动对应代码。**

---

## 第 1 章:v1 中真实成立(或部分成立)的条目

| v1 编号 | 裁定 | 如何保留/调整 |
|---|---|---|
| **C4** | ✅ **真实且严重** | `EngramServiceCommandHandler.swift:814-836` 四个 `project*` 方法确实抛 `unsupportedNativeCommand(...)`。v1 对这点判断正确。**但 v1 忽略了更糟的事**:App UI 层根本没走 Service,走的是 `DaemonClient`(见新增 **X2** / **X3**) |
| **H1** | ✅ **真实** | Stage 5 gate 文档与实际不符,保留 |
| **H4** | ✅ **真实** | 大文件 OOM,保留(参考 Qwen C 的 `AsyncStream` 改造方案) |
| **H5** | ⚠️ **小问题** | `SessionAdapter.swift:12-13` 有 `case minimax / lobsterai` 枚举但无 Adapter 文件。SwiftIndexer 查 AdapterRegistry 失败会静默跳过,非紧急。降级为 **Medium** |
| **H6** | ⚠️ **措辞夸大** | MiniMax C 实证:`IndexerParityTests.swift:212-214` 和 `AdapterParityTests.swift:162-163` **有字段级比较**,通过 Equatable/stableString JSON 序列化。v1 说"只比行数"不准。**真正的问题是 stub-class bug 模式**(见新增 **X10**) |
| **H7** | ✅ **真实** | schema-compat 不在 CI 门禁,保留 |
| **Medium M1-M9** | 保留 | 基本不受影响 |

---

## 第 2 章:新 Critical(多 AI 交叉发现 + 人工验证)

### X1. App 日志 HTTP 发到已下线的 Node :3457 → 全部静默丢失

**文件:** `macos/Engram/Core/EngramLogger.swift:44-60`

```swift
private static func forwardToDaemon(level: String, module: LogModule, message: String, ...) {
    ...
    Task.detached {
        guard let url = URL(string: "http://127.0.0.1:3457/api/log") else { return }
        ...
        request.timeoutInterval = 2
        _ = try? await URLSession.shared.data(for: request)  // 丢错
    }
}
```

**问题:** 每次 `EngramLogger.warn(...)` / `.error(...)` 都会 POST 到 `:3457`。Node daemon 已下线,没有 Swift 服务监听 TCP 3457(Service 用 Unix socket,MCPServer 用 :3456)。`try?` + 2s timeout 吞错,用户看不到日志。线上出问题 debug 完全抓瞎。

**修复:** 移除 `forwardToDaemon`,或改为写入 Service(新增 `logForward` command)。同时检查所有 `EngramLogger.warn/error` 调用,确认仅 `os.Logger` 足够(Console.app 能看)。

---

### X2. `DaemonClient.swift`(433 行)整个类全是死代码 + AppEnvironment 仍暴露 daemonPort

**文件:** `macos/Engram/Core/DaemonClient.swift` + `macos/Engram/Core/AppEnvironment.swift:19`

```swift
// DaemonClient.swift:10
init(port: Int = 3457, session: URLSession = .shared) { ... }

// AppEnvironment.swift:19
daemonPort: 3457, // matches DaemonClient default
```

**问题:** DaemonClient 每个方法仍发往 `http://127.0.0.1:3457/api/*`。包括(节选):`projectMove` / `projectArchive` / `projectUndo` / `listProjectMigrations` / `projectCwds` / `linkSession` / `unlinkSession` / `confirmSuggestion` / `dismissSuggestion` / `fetchHygieneChecks` / `resumeCommand` / etc.

**真相:** 这是 v1 **C4 真正严重的那一面**。v1 只说 Service 层抛 Unsupported,但用户点 UI 按钮(ArchiveSheet、RenameSheet、UndoSheet、HygieneView...)走的根本不是 Service,而是 `DaemonClient` → HTTP → **黑洞**。用户体验 = URLSession 超时 → UI 永久卡或弹红字错误。

**修复:**
1. 把 DaemonClient 里所有方法改为调 `EngramServiceClient`(Unix socket),或改为"明确不可用"的占位
2. 从 App Target 里移除 DaemonClient.swift,只留测试
3. `AppEnvironment.daemonPort` 字段删除
4. **逐一核查**所有 View 里的 DaemonClient 调用点,按调用映射:
   - `projectMove/Archive/Undo/MoveBatch` → 目前 Service 也抛 Unsupported(v1 C4 真实),**要么补实现要么 UI 下线按钮**
   - `linkSession/unlinkSession/confirmSuggestion/dismissSuggestion` → Service `confirmSuggestion` 已实现(见 `EngramServiceCommandHandler.swift:346-402`),其他需要添加
   - `fetchHygieneChecks` → Service `hygiene` 已实现(`CommandHandler.swift:64-69`)
   - `resumeCommand` → Service `resumeCommand` 已定义但 EmptyReadProvider 返回错误,需看 Sqlite 实现

### X3. UI 四个 project 操作按钮必红字报错(C4 真实面)

**文件:** `macos/EngramService/Core/EngramServiceCommandHandler.swift:814-836`

```swift
private static func projectMove(...) throws -> ... {
    try unsupportedNativeCommand("projectMove")
}
// 同样:projectArchive / projectUndo / projectMoveBatch
```

**UI 面文件**(同时受影响):`macos/Engram/Views/Projects/ArchiveSheet.swift`、`RenameSheet.swift`、`UndoSheet.swift`、`ProjectsView.swift`

**选择:**
- **选 A(优先):** 补 Swift 原生实现,把 Node `src/cli/project.ts` 或 `src/tools/project_*` 逻辑 port 过来(正式退出 Node 之前本来就要做)
- **选 B(临时):** UI 禁用按钮 + 显示"Project migration 暂未在 Swift 版启用,请暂回 Node 分支使用",同时 MCP 工具也要下线这些 tool(避免外部 Claude Code 调用踩坑)

---

### X4. EngramServiceLauncher 未消费子进程 Pipe → Service stdout 写阻塞死锁

**文件:** `macos/Engram/Core/EngramServiceLauncher.swift:61-70`

```swift
func start(configuration: EngramServiceLaunchConfiguration) throws {
    ...
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: configuration.executablePath)
    proc.arguments = Self.arguments(for: configuration)
    proc.standardOutput = Pipe()  // ❌ 无 readabilityHandler
    proc.standardError = Pipe()   // ❌ 无 readabilityHandler
    try proc.run()
    process = proc
}
```

**问题:** `EngramServiceRunner.swift:58-62` 每 20s `print(checkpoint event)` + 每次错误 print。Darwin Pipe 缓冲区 16-64KB,**Service 写满后阻塞在 `write(stdout)`**,整个 Service Task 冻结 → health probe 失败 → Launcher 触发重启 → 新 Service 又继续阻塞。循环直到 `maxRestarts` 达到,永久 `.degraded`。

这是 v1 C5 "无 health check" 被驳倒后留下的**真正的进程生命周期 bug**。v1 完全漏了。

**修复:**
```swift
let stdoutPipe = Pipe()
let stderrPipe = Pipe()
proc.standardOutput = stdoutPipe
proc.standardError = stderrPipe
stdoutPipe.fileHandleForReading.readabilityHandler = { h in
    if let line = String(data: h.availableData, encoding: .utf8), !line.isEmpty {
        // 解析 JSON event 或转发 os_log
    }
}
stderrPipe.fileHandleForReading.readabilityHandler = { ... }
```

或把 Service 的 `print()` 全换成 `os_log` 并移除 Pipe 设置。

---

### X5. `UnixSocketServiceServer` + `EngramServiceCommandHandler` 共享 JSONEncoder/Decoder + `@unchecked Sendable` → 数据竞争

**文件:**
- `macos/EngramService/IPC/UnixSocketServiceServer.swift:4, 9, 32-49`
- `macos/EngramService/Core/EngramServiceCommandHandler.swift:6, 8-9`

```swift
final class UnixSocketServiceServer: @unchecked Sendable {
    private let encoder = JSONEncoder()  // 实例级共享
    private let decoder = JSONDecoder()
    ...
    acceptTask = Task.detached {
        while !Task.isCancelled {
            let client = accept(...)
            Task.detached {
                // ❌ 并发访问 encoder/decoder
                let request = try decoder.decode(..., from: frame)
                try UnixSocketEngramServiceTransport.writeFrame(try encoder.encode(response), ...)
            }
        }
    }
}
```

**问题:** Apple 文档明确 `JSONEncoder` / `JSONDecoder` 不是 Sendable;类用 `@unchecked Sendable` 绕过编译器检查。多连接并发时可能:(a) 编码结果错乱(request A 的数据用 request B 的日期策略);(b) 内部 cache / 状态损坏导致 crash。

**修复:** 每个请求新建 encoder/decoder,或用 `@ThreadLocal`;类推到 `CommandHandler.swift:8-9` 的同样问题。

---

### X6. JSONDecoder 无嵌套/数组/字符串长度限制 → DoS

**文件:** `macos/EngramService/IPC/UnixSocketServiceServer.swift:35-36`
**文件:** `macos/EngramService/Core/EngramServiceCommandHandler.swift:310-314`

**问题:** Frame 已限 32MB(`UnixSocketEngramServiceTransport`),但 32MB 内可构造 10^6 层嵌套 JSON `{"a":{"a":...}}`。`JSONDecoder` 递归解析触发栈溢出,或巨大数组/字符串导致 OOM。

**攻击面:** 任何能连到 Unix socket 的本地进程(socket 在 `~/.engram/run/`,同用户进程都可达)。

**修复:** 要么自定义 `JSONDecoder` wrapper 做深度/长度统计,要么限制单 frame payload 到 ≤ 256KB(99% 合法请求都在这以内)。

---

### X7. TranscriptExport 不过滤 API key / token → 敏感凭证明文泄露到 `~/`

**文件:** `macos/EngramService/Core/TranscriptExportService.swift:100-134`

```swift
for message in messages {
    lines.append("### \(message.role == "user" ? "👤 User" : "🤖 Assistant")")
    lines.append("")
    lines.append(message.content)   // ❌ 无过滤,原样写入
    ...
}
try content.write(to: outputURL, atomically: true, encoding: .utf8)
```

**问题:** Codex/Claude Code 会话内容中经常包含 `export ANTHROPIC_API_KEY=sk-ant-...` / `Authorization: Bearer ...` / DB 密码等。导出后文件落到 `~/codex-exports/`(或用户指定路径),文件权限跟随 umask(通常 644),其他用户可读。

**修复方向:**
1. 导出前运行正则扫描:`(?i)(api[_-]?key|bearer|password|secret|credential|token)[=:\s]+[A-Za-z0-9_\-+=/.]{10,}`,匹配项替换为 `[REDACTED]`
2. `FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)` 确保仅 owner 可读
3. UI 加一行警告:"导出前会自动脱敏,若需原文请在 settings 中关闭 redaction"

---

### X8. `size_bytes = 0` 在 FTS 重建时被强制清零

**文件:** `macos/EngramCoreWrite/Database/FTSRebuildPolicy.swift:22`

```swift
try db.execute(sql: "UPDATE sessions SET size_bytes = 0")
```

**问题:** FTS 重建跟 session 文件大小完全无关,但这行清零了所有 session 的 `size_bytes`。后续 indexer 运行时会重算并填回,但窗口期内:
- `hideEmptySessions` 用 `size_bytes < 1024 AND message_count = 0` 双条件,因为 message_count 不受影响所以不会误隐藏**已有数据**
- 但 UI 如果单独依赖 `size_bytes` 显示文件大小,会短暂显示 0(Kimi A 报告的风险比实际更 narrow)

**严重性:** 原报"误隐藏 session"不成立(有 AND message_count 保护),但**语义错误**仍在 —— FTS 重建不应该动 session 元数据。降为 **High**。

**修复:** 去掉 L22,或把它挪到一个独立的 `SessionSizeRefreshPolicy`。

---

### X9. 辅助表 Swift/Node schema 漂移 → 回滚不可行

**文件:** `macos/EngramCoreWrite/Database/EngramMigrations.swift:174-250` vs `src/core/db/migration.ts`

**Kimi C 报告的漂移点**(我没有再次对 Node 侧逐行验证,但 Swift 侧已确认):
- `session_tools` Swift 用 `count INTEGER`(L177),Node 历史上用 `call_count`
- `session_files` Swift `action TEXT` 可空(L185),PK 含 `action` → 不同 action 独立行
- `logs` Swift 列集:`data / trace_id / request_id / request_source / source`(L191-202);Node 的 logs 历史上还有 `span_id / error_name` 等
- `traces` / `metrics_hourly` / `alerts` 同类差异

**问题:** 如果上线后想回滚到 Node,Node 迁移不会 DROP+重建现有表,而是调 `CREATE TABLE IF NOT EXISTS`(no-op),随后 INSERT 时列不匹配报错。**回滚不是换 bundle 那么简单,需要手写数据修补脚本**。

**请 Codex 做:**
1. 针对每张漂移表,把 Node 侧 schema 对齐过来(或反过来),保持 source-of-truth 一致
2. `scripts/db/check-swift-schema-compat.ts` 应该能抓到这个,看下为什么没挡住(可能压根没覆盖这些辅助表)
3. 在 `docs/swift-single-stack/cli-replacement-table.md` 或新建 rollback-plan.md 里明确标注"回滚需要 X 步数据修补"

---

### X10. 测试里的 Stub-class bug(MiniMax C 实证)

**文件:** `macos/EngramCoreTests/StartupBackfillTests.swift`

MiniMax C 给的具体反例:
- **L322** 硬编码 `XCTAssertEqual(..., 72)`,若评分公式改成 `userMsg*10 + asstMsg*7 + toolMsg*6 + sysMsg*1 = 69` 这种细微 bug,测试**不会 fail 对数值,但会 fail 对算法表达**;测试**过分信任 magic number**
- **L109-110** 只校验 backfill 后 DB 里 `agent_role = "dispatched"`。如果 backfill 代码写成硬编码 return "dispatched"(完全绕过 originator 解析),测试依然绿
- **`IndexerParityTests.swift:162`** 只用 `tier=normal` 的单一快照测 `enqueuedJobs = ["embedding", "fts"]`,无 tier-gating 覆盖

**这是 v1 H6 "只比行数"说错的方向,但本质问题(测试不验算法)仍在。**

**修复:** 对评分/ tier / backfill 这类算法,每个 testcase 应至少覆盖 2-3 种输入组合,并让测试函数接受**期望公式 output** 而非 magic number,便于未来 refactor。

---

## 第 3 章:新 High

### X11. linkSessions 可创建指向任意文件的 symlink

**文件:** `macos/EngramService/Core/EngramServiceCommandHandler.swift:906`

```swift
try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: filePath)
```

**问题:** `filePath` 来源于 `SELECT COALESCE(ls.local_readable_path, s.file_path) FROM sessions`。这两个字段都可能被 adapter 层污染(如构造一个 `file_path=/Users/<u>/.ssh/id_rsa` 的假 session 记录)。一旦用户点 "Link project" 按钮,就会在 `targetDir/conversation_log/source/id_rsa` 创建指向敏感文件的 symlink,第三方工具顺着目录读取可能泄露。

**攻击前提:** DB 被写入恶意 session 记录 —— 目前 DB 只有 Service 能写,但 Service 接受来自 adapter 的 filePath(adapter 扫描用户文件系统,不验证路径)。

**修复:** 在 `linkSessions` 里白名单校验 `filePath` 必须落在 `~/.codex/` / `~/.claude/` / `~/.gemini/` 等已知 session root 里;拒绝 `.ssh` / `.aws` / `~/.config/` 等敏感目录。

---

### X12. Unix socket 无连接数上限 + readFrame 无 per-byte 超时 → slow-read DoS

**文件:**
- `macos/EngramService/IPC/UnixSocketServiceServer.swift:27-52`(accept 循环无 semaphore)
- `macos/Shared/Service/UnixSocketEngramServiceTransport.swift`(readFrame 在 32MB 内没有读字节数-时间 guard)

**问题:** 恶意进程对 socket 建数百个连接,每个以 1 byte / 10s 速率发 32MB → 耗尽文件描述符 + 每连接占用一个 Handler Task。

**修复:** accept 循环加 `ServiceAsyncSemaphore(value: 32)`(类似现有 writeSemaphore);`readExact` 里加总字节读取时间上限(如 10s / MB)。

---

### X13. UI 层 40+ 处 `catch { print(...) }` → 静默失败(Gemini A 报告)

**文件:** 散落在 `macos/Engram/Views/Pages/*.swift`、`Components/*.swift`

**示例模式:**
```swift
do {
    let rows = try db.loadSomething()
    ...
} catch {
    print("... error:", error)  // 用户完全看不到
}
```

**问题:** DB 查询失败(损坏、schema drift、Service 不可用) → UI 显示空白或死 loading,无 error banner / toast。

**修复:** 全局引入一个 `ErrorBanner` / `Toast` 机制,所有 catch 调用 `AppErrorReporter.report(error, context:)` 而不是 print;至少把关键页面(HomeView / SessionListView / ProjectsView / SearchPageView)的 catch 改成显式 UI。

---

### X14. 其余 v1 保留条目

- H1:Stage 5 gate 文档撤销"通过"(文档修正 30min)
- H4:大文件 OOM,`AdapterRegistry.collectSnapshots` 改 AsyncStream 分批(见 Qwen C 的 patch 方案)
- H7:schema-compat check 接入 CI

---

## 第 4 章:Medium(保留 v1,略调整)

- **M1** `Shared/Service` 被 App/CLI 直接 import,协议边界泄漏(Gemini B 建议拆 `EngramServiceContracts` + 实现两包)
- **M2** Node 5 个 CLI 命令无 Swift 替代(logs/traces/health/diagnose/resume)
- **M3** `ParentDetection.detectionVersion` 硬编码常量
- **M4** `events()` AsyncStream 空实现(`UnixSocketEngramServiceTransport.swift:36-40`)—— UI 依赖 `for try await event in serviceClient.events()`(`App.swift:165`),这条 stream 永远不产出事件,UI 拿不到 Service 推送
- **M5** `ParserLimits` 未知 JSON 字段静默丢弃
- **M6** 非监视源 rescan 10 分钟
- **M7** Swift 性能 baseline 16 行空壳(`scripts/measure-swift-single-stack-baseline.sh`)
- **M8** Boundary 脚本正则脆弱,Gemini B 建议换 SwiftLint AST custom_rules
- **M9** Adapter malformed fixture 只有 manifest 无 input

---

## 第 5 章:修复优先级与 PR 拆分建议(整合 MiMo C + Gemini C)

### 合并前必须修(Critical)

| # | 条目 | 代价 | 备注 |
|---|---|---|---|
| 1 | **X2+X3** DaemonClient 死代码链路 + project UI 按钮下线 | 4-8h | 最痛的用户路径 |
| 2 | **X1** EngramLogger 去 HTTP :3457 | 1h | 改成 os_log + 可选 Service forward |
| 3 | **X4** EngramServiceLauncher Pipe 消费 | 2h | 避免长期运行后 Service 死锁 |
| 4 | **X5** 共享 Encoder/Decoder 改为 per-request | 1h | 消除数据竞争 |
| 5 | **X6** JSON frame payload 上限 256KB(或深度 check)| 1h | 防 DoS |
| 6 | **X7** TranscriptExport 敏感凭证过滤 + `chmod 0600` | 2h | 防泄露 |
| 7 | **X11** linkSessions filePath 白名单 | 1h | 防 symlink 攻击 |
| 8 | **X12** socket 并发上限 + per-read 超时 | 2h | 防 slow-read |
| 9 | **H1 / 文档** Stage 5 gate 修正为"未完成" | 30min | 文档诚实性 |

### 合并前强烈建议

| # | 条目 | 代价 |
|---|---|---|
| 10 | **H4** 大文件 OOM(AdapterRegistry AsyncStream)| 4h |
| 11 | **H7** schema-compat CI gate | 1h |
| 12 | **X8** FTSRebuildPolicy 去掉 size_bytes=0 | 10min |
| 13 | **X9** 辅助表 schema 对齐到 Node | 2-4h |
| 14 | **M4** events() 真实实现(Service → App 推送) | 3h |

### PR 拆分建议(参考 MiMo C / Gemini C)

- **PR-A(紧急)**:X1 + X2 + X3 + X4 —— Dead HTTP 链路 + Pipe 阻塞 + UI 按钮。这些不修用户开箱 broken
- **PR-B(安全)**:X5 + X6 + X7 + X11 + X12 —— 并发/DoS/路径攻击
- **PR-C(数据 & 测试)**:X8 + X9 + X10 + H7 + M4
- **PR-D(体积 & 文档)**:H1 + H4 + Medium 杂项

---

## 第 6 章:方向性讨论(保留 v1 + 修正)

1. **单 commit 33k 行仍建议拆分** —— bisect 能力不可替代。`git rebase -i` 按 Stage 0-5 切 6 个 commit
2. **Node 代码删除时间表**(MiMo C 版):
   - Phase 1(到 05-01):删 `web.ts` / `daemon.ts` / `index.ts`。前置:X4 X5 稳定
   - Phase 2(到 05-15):删 `adapters/` / `tools/` / `core/indexer.ts`。前置:H4 + H6 深化测试
   - Phase 3(到 06-01):清 `package.json` / `src/` 残余 / 更新 boundary 脚本
3. **Staged rollout**(Gemini C 版):
   - 在 `EngramServiceStatusStore` 增加 `crashCount` / `restartCount` 字段便于观测
   - 内部 dogfood(前 3 天)重点观察 X4(Pipe)+ X2(DaemonClient 路径)—— 最容易让人 brick 的两个路径
   - TestFlight(4-14 天)关注 X7(凭证泄露:看 UI 是否暴露任何 export 按钮)、H4 大文件场景
   - 回滚阈值:X4 / X9 踩一次就暂停放量(X9 会让数据变脏,回滚困难;X4 表示工程流程有死锁)
4. **老用户首启 UX**(Gemini C 版):
   - 给 App 加一个 "首次迁移检查" toast:"Engram 已升级到原生版本,如遇搜索暂时为空请等待 ~3 分钟完成索引"

---

## 第 7 章:给 Codex 的操作建议

1. **先读本文档第 0 章**,把 v1 C1/C2/C3/C5/C6/H2/H3 的修改**全部还原**(如果已经动了)
2. 从 **第 5 章 PR-A(X1/X2/X3/X4)** 开始,因为这 4 条不修用户装上 App 就踩坑
3. 每个 PR 合并前,**对应测试必须 fail→pass 对照**(X4/X5 可通过 stress 测试 + 连发 100 万行 stdout;X6 可以发 10 层嵌套 JSON)
4. 不确定的地方,**优先 ping 我**而不是猜 —— v1 有 ~45% 误报,证明"读源码差几行上下文"会导致诊断错误。宁可多问

---

## 第 8 章:Review 方法论记录(供将来复盘)

- **v1 来源**:第一轮 6 路 Explore subagent,信息有限,误读代码
- **v2 来源**:15 路外部 AI(Kimi/MiniMax/Qwen/Gemini/MiMo via polycli)交叉验证 + 人工 Read 16 个关键源文件裁定
- **教训**:大规模 review 不能信一轮 agent 的 file:line 断言,必须独立 Read 原文。下一轮 review 应当把"我自己 Read 的文件 + 每条断言的原始行"作为证据 appendix 附在 review 里,让下游 reviewer 能快速验证

---

**v1 文件位置**:`docs/swift-single-stack/2026-04-24-review-feedback.md`(保留作为历史参照)
**v2 文件位置**:`docs/swift-single-stack/2026-04-24-review-feedback-v2.md`(本文件,发给 Codex 的真实工作清单)
