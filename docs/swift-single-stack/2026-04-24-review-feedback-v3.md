# v3 —— 继续修的单一指令清单(v2 + followup 去重版)

**日期:** 2026-04-24
**已合并的 commit:** `6d732ca`(主体修复)、`3e3d45c`(测试加固)
**本清单覆盖:** v2 里未完成/部分完成的 + v2-followup 新发现的回归,合并成 **单一 actionable 清单**
**历史文档:** `v2` / `v2-followup` 可不看。本清单自包含

---

## 零、合并前必修(Critical —— 不修就会让用户数据坏或 UX 破损)

### [C-1] 辅助表 schema 大改但没加升级迁移 → 老用户升级必炸

**文件:** `macos/EngramCoreWrite/Database/EngramMigrations.swift`

**问题:** 本次把 8 张辅助表 schema 朝 Node 对齐(方向对),但 `createOrUpdateBaseSchema` 里全是 `CREATE TABLE IF NOT EXISTS` —— 对老用户已有的表是 no-op。老库里依然是旧 schema,新代码访问新列会炸。`addSessionColumnsIfNeeded` 只覆盖了 `sessions` 一张表。

**老用户升级后的实际报错清单:**

| 表 | 变化 | 老用户运行报错 |
|---|---|---|
| `session_tools` | `count` → `call_count`(列名改) | `SELECT call_count FROM session_tools` → `no such column` |
| `session_files` | `action` 从 nullable → NOT NULL | INSERT 旧代码允许的 `action=NULL` → `NOT NULL constraint failed` |
| `logs` | 加 `span_id / error_name / error_message / error_stack`,`source CHECK IN ('daemon','app')` | INSERT 包含新字段 → `no such column` |
| `traces` | 加 `id AUTOINCREMENT / source`,`kind`→`module`,`duration_ms REAL`→`INTEGER`,`status NOT NULL DEFAULT 'ok'` | 结构全变,旧索引/写入路径断 |
| `metrics_hourly` | 主键 `(name,hour)` → 加 `id AUTOINCREMENT / type / tags + UNIQUE(name,type,hour,tags)`;min/max NOT NULL;去 p50/p99 | 插入旧列 p50/p99 → `no such column`;INSERT 不带 id → OK 但 UNIQUE 冲突行为变 |
| `alerts` | `id TEXT PRIMARY KEY / data / ts NOT NULL` → `id INTEGER AUTOINCREMENT / severity CHECK / value / threshold / dismissed_at / resolved_at` | id 类型变、severity CHECK 拒绝旧值(如 'info'/'low') |
| `ai_audit_log` | 结构完全重写 | 读旧行 `request / response / input_tokens / output_tokens / cost_usd` 全不存在 |
| `git_repos` | 去 `dirty_count / untracked_count / unpushed_count / last_commit_hash / last_commit_msg / last_commit_at / updated_at NOT NULL`;加 `session_count / probed_at` | 旧查询全断 |
| `session_costs` | `computed_at NOT NULL` → nullable | 插入 NULL 在老库会被拒绝(NOT NULL 约束) |

**修复方向(推荐方案):**

在 `EngramMigrations.swift` 引入 **schema version 机制 + idempotent 迁移**:

```swift
enum EngramMigrations {
    static let currentSchemaVersion = 2  // 本次改动 = v2

    static func createOrUpdateBaseSchema(_ db: GRDB.Database) throws {
        // ... 现有 CREATE TABLE IF NOT EXISTS ...
        try addSessionColumnsIfNeeded(db)
        try migrateAuxTablesToV2(db)  // ← 新增
    }

    private static func migrateAuxTablesToV2(_ db: GRDB.Database) throws {
        let version = try Int.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='schema_version'").flatMap(Int.init) ?? 1
        guard version < 2 else { return }

        // session_tools: count → call_count
        if try columnExists(db, table: "session_tools", column: "count"),
           try !columnExists(db, table: "session_tools", column: "call_count") {
            try db.execute(sql: "ALTER TABLE session_tools RENAME COLUMN count TO call_count")
        }

        // session_files.action: nullable → NOT NULL
        // SQLite 不支持直接改约束,需要 CREATE NEW + INSERT + DROP + RENAME
        // 或者:NULL 行先补默认值再加检查(软约束)
        // 建议:后续写入强制非空,老 NULL 行不强制迁移,代码层防御

        // logs: 加 span_id / error_name / error_message / error_stack
        try addColumnIfNeeded(db, table: "logs", column: "span_id", type: "TEXT")
        try addColumnIfNeeded(db, table: "logs", column: "error_name", type: "TEXT")
        try addColumnIfNeeded(db, table: "logs", column: "error_message", type: "TEXT")
        try addColumnIfNeeded(db, table: "logs", column: "error_stack", type: "TEXT")
        // source CHECK 约束加不了,SQLite ALTER TABLE 不支持修改 CHECK
        // 可选:新增 logs_v2 表 + 迁移数据 + DROP old + RENAME,或代码层白名单

        // traces: 加 id AUTOINCREMENT / source / module(rename from kind)
        try addColumnIfNeeded(db, table: "traces", column: "module", type: "TEXT")
        try addColumnIfNeeded(db, table: "traces", column: "source", type: "TEXT NOT NULL DEFAULT 'daemon'")
        // duration_ms REAL → INTEGER:SQLite 动态类型,REAL 值会被隐式转,不致命
        // kind → module:若两列都存在,回填 module = kind 后允许 kind 为 NULL;新代码只读 module

        // metrics_hourly: 加 id / type / tags,unique 约束变
        try addColumnIfNeeded(db, table: "metrics_hourly", column: "id", type: "INTEGER")
        try addColumnIfNeeded(db, table: "metrics_hourly", column: "type", type: "TEXT DEFAULT 'counter'")
        try addColumnIfNeeded(db, table: "metrics_hourly", column: "tags", type: "TEXT")

        // alerts: 结构变动大 → 建议新建 alerts_v2 + 迁移现有数据(只保留最近 30 天)
        // 或者代码层先检查列是否存在再查询(最保守)

        // ai_audit_log: 字段大改 → 同 alerts,建议 _v2 表
        try addColumnIfNeeded(db, table: "ai_audit_log", column: "operation", type: "TEXT NOT NULL DEFAULT 'unknown'")
        try addColumnIfNeeded(db, table: "ai_audit_log", column: "request_source", type: "TEXT")
        try addColumnIfNeeded(db, table: "ai_audit_log", column: "method", type: "TEXT")
        try addColumnIfNeeded(db, table: "ai_audit_log", column: "url", type: "TEXT")
        try addColumnIfNeeded(db, table: "ai_audit_log", column: "status_code", type: "INTEGER")
        try addColumnIfNeeded(db, table: "ai_audit_log", column: "duration_ms", type: "INTEGER")
        try addColumnIfNeeded(db, table: "ai_audit_log", column: "provider", type: "TEXT")
        try addColumnIfNeeded(db, table: "ai_audit_log", column: "prompt_tokens", type: "INTEGER")
        try addColumnIfNeeded(db, table: "ai_audit_log", column: "completion_tokens", type: "INTEGER")
        try addColumnIfNeeded(db, table: "ai_audit_log", column: "total_tokens", type: "INTEGER")
        try addColumnIfNeeded(db, table: "ai_audit_log", column: "request_body", type: "TEXT")
        try addColumnIfNeeded(db, table: "ai_audit_log", column: "response_body", type: "TEXT")
        try addColumnIfNeeded(db, table: "ai_audit_log", column: "meta", type: "TEXT")

        // git_repos: 结构变动 → 同样策略
        try addColumnIfNeeded(db, table: "git_repos", column: "session_count", type: "INTEGER DEFAULT 0")
        try addColumnIfNeeded(db, table: "git_repos", column: "probed_at", type: "TEXT")

        try db.execute(sql: "INSERT INTO metadata(key,value) VALUES ('schema_version','2') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
    }

    private static func columnExists(_ db: GRDB.Database, table: String, column: String) throws -> Bool {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return rows.contains { ($0["name"] as String?) == column }
    }

    private static func addColumnIfNeeded(_ db: GRDB.Database, table: String, column: String, type: String) throws {
        if try !columnExists(db, table: table, column: column) {
            try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
        }
    }
}
```

**验收标准:**
1. 新增测试:用 v1 fixture `.sqlite`(预填旧 schema + 数据)跑 `createOrUpdateBaseSchema`,然后对每张表 INSERT 一行 + SELECT,全部成功,无 `no such column` / `NOT NULL constraint failed`
2. 全新 DB 场景仍通过(已有的 MigrationRunnerTests)
3. `scripts/db/check-swift-schema-compat.ts` 通过

**注:** 对 `alerts` / `ai_audit_log` / `metrics_hourly` 如果 ALTER TABLE 无法完整表达新约束(SQLite 限制),可接受"代码层防御 + 新数据走新 schema,旧数据保留"的混合策略,但至少要保证**不 crash**。

---

### [C-2] `insights.deleted_at` 被删除,软删功能消失 —— 需要确认意图

**文件/行号变动:**
- `EngramMigrations.swift:289`(CREATE TABLE 去掉 `deleted_at TEXT`)
- `EngramServiceCommandHandler.swift:493`(同表冗余定义,也去了)
- `EngramServiceCommandHandler.swift:679`(UPSERT 去掉 `deleted_at = NULL` 重置)
- `EngramServiceCommandHandler.swift:757 / 769`(查询去掉 `WHERE deleted_at IS NULL`)

**两种可能:**

**(a) 有意对齐 Node 当前 schema**:如果 Node 那边已经不再用 `deleted_at`,软删改成了别的机制(独立 `deleted_insights` 表、或者 `hidden_at` 等),那就需要在 Swift 侧也 port 对应机制。

**(b) Regression**:老用户本地 DB 里有 `deleted_at != NULL` 的 insight(已软删),新 schema 不认这列 → **已经删掉的 insight 会重新出现在 UI 里**。

**请 Codex 回答 + 执行:**

1. 对照 `src/core/db/insight-repo.ts` 或 Node 最新 migration,确认当前是否仍支持软删
2. 如果 Node 支持但 Swift 不支持 → **这是 regression,回滚 `deleted_at` 列和相关查询**
3. 如果 Node 也不支持 → 在 [C-1] 的升级脚本里,对老用户做 `DELETE FROM insights WHERE deleted_at IS NOT NULL`(把软删的 insight 真删掉),然后 ALTER 去掉列;**且在 CHANGELOG 明确记录"insight 软删机制下线"**

---

### [C-3] project UI 按钮行为 smoke test(不是改代码,是验证)

**现状:**
- Service 层 `EngramServiceCommandHandler.swift:814-836` 四个 `project*` 仍抛 `unsupportedNativeCommand(...)`(这符合 stage4.md 的决定)
- UI 依赖 `nativeProjectMigrationCommandsEnabled` gate(`ProjectsView.swift:218` 附近)

**需要验证(不要改代码,只跑 Release build 看):**

1. 打开 Release build 里 ProjectsView
2. 确认 **Archive / Rename / Undo 三个按钮都不可见**(或灰态禁用)
3. 如果按钮仍可见 → 用户点了会收到 `UnsupportedCommand` 红字错误 → UX 破损

**如果按钮仍可见,需要改的地方:**
- `macos/Engram/Views/Projects/ArchiveSheet.swift` / `RenameSheet.swift` / `UndoSheet.swift`:入口处加同一 gate
- 或 `ProjectsView` 的顶层按钮用 `.hidden(!nativeProjectMigrationCommandsEnabled)` 包住

---

## 一、合并前强烈建议(High —— 可进 follow-up PR 但不能拖太久)

### [H-1] `AdapterRegistry.collectSnapshots` 大文件 OOM

**文件:** `macos/Shared/EngramCore/Adapters/AdapterRegistry.swift`(~L92-96)+ `macos/EngramCoreWrite/Indexing/SwiftIndexer.swift`

**问题:** 当前实现把整个适配器的 `AsyncThrowingStream<NormalizedMessage, Error>` collect 进 `[NormalizedMessage]` 数组。150MB 的 Cursor/Codex session 会把 Service RSS 打爆。Node 侧的 async generator 是真流式,Swift 这里退化了。

**修复方案(Qwen C 给的代码骨架,供参考):**

```swift
struct SnapshotBatch {
    let snapshots: [NormalizedSnapshot]
    let totalProcessed: Int
}

extension AdapterRegistry {
    func streamSnapshots(batchSize: Int = 1000) -> AsyncThrowingStream<SnapshotBatch, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                var buffer: [NormalizedSnapshot] = []
                var total = 0
                do {
                    for session in sessions {
                        for try await msg in session.streamMessages(...) {
                            buffer.append(normalize(msg))
                            total += 1
                            if buffer.count >= batchSize {
                                continuation.yield(SnapshotBatch(snapshots: buffer, totalProcessed: total))
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(SnapshotBatch(snapshots: buffer, totalProcessed: total))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

消费侧 `SwiftIndexer`:

```swift
func indexAllSessions() async throws {
    for try await batch in registry.streamSnapshots(batchSize: 1000) {
        try await writerGate.performWriteCommand(name: "indexBatch") { writer in
            try writer.write { db in
                for snap in batch.snapshots { try upsertSnapshot(db, snap) }
            }
        }
    }
}
```

**验收:** 加一个 stress 测试,用 150MB 合成 jsonl 喂给 adapter,Service RSS peak < 100MB。

---

### [H-2] schema-compat 接入 CI 门禁

**现状:** `scripts/db/check-swift-schema-compat.ts` 已经有 `nodeCompatibleTables` + `ColumnSignature` 对比逻辑,但没接 CI。

**修复:** 在 `.github/workflows/test.yml`(如果没有则新建)的 `swift-unit` job 之后加:

```yaml
- name: Swift vs Node schema compatibility gate
  run: |
    xcodebuild -scheme EngramCoreSchemaTool -configuration Debug build
    npx tsx scripts/db/check-swift-schema-compat.ts
```

如果用的是 husky pre-push / pre-commit hook,也可以加到那里,但 CI 门禁更稳。

**验收:** PR 里故意改 Swift 某个表 schema 不同步 Node,CI 红灯。

---

## 二、可选(Low —— 不做也不影响合并,只是深度防御)

### [L-1] JSON decode 嵌套深度限制

**文件:** `UnixSocketServiceServer.swift:35-36` 和 `EngramServiceCommandHandler.swift:309-311`

frame 已经限到 256KB,但 256KB 内可构造 ~50000 层嵌套 JSON 触发 `JSONDecoder` 递归栈溢出。Unix socket 只本用户可达,攻击面小,但建议加一层:

```swift
// 简易前置检查
private static func checkJSONDepth(_ data: Data, maxDepth: Int = 64) throws {
    var depth = 0, maxSeen = 0
    for byte in data {
        switch byte {
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            depth += 1
            maxSeen = max(maxSeen, depth)
            if maxSeen > maxDepth {
                throw EngramServiceError.invalidRequest(message: "JSON depth exceeds \(maxDepth)")
            }
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
            depth -= 1
        default:
            break
        }
    }
}
```

在 `decodePayload` 前调用。**低优先级**,可放入后续安全加固 PR。

---

## 三、确认已完成(无需再动)

这些 v2 里的条目本次 review 验证过,已完美完成 —— 不要再碰:

- X1 EngramLogger dead HTTP → `forwardToDaemon` 整个删除 ✅
- X2 DaemonClient 死代码 → 文件 + 测试 + mock 全删 + Xcode target 清理 ✅
- X4 Launcher Pipe 阻塞 → `drain(pipe:)` + readabilityHandler ✅
- X5 共享 Encoder/Decoder 数据竞争 → per-call 新建 ✅
- X7 TranscriptExport 凭证泄露 → 3 条正则脱敏 + chmod 0600 ✅
- X8 FTS size_bytes=0 → L22 删除 ✅
- X10 测试 stub-class bug → `expectedQualityScore(...)` 替代 magic 72 ✅
- X11 linkSessions symlink → 白名单 + 黑名单 ✅
- X12 socket 并发 → `ServiceConnectionLimiter(value: 32)` + 10s timeout ✅
- H1 Stage 5 文档修正 → stage4.md 诚实重写 ✅

---

## 四、执行建议

按优先级一气呵成:

1. **今天做**:[C-2] 确认 `insights.deleted_at` 的意图(只是查 Node 侧 schema,几分钟)
2. **今天做**:[C-3] smoke test(5 分钟,跑 Release build)
3. **这周做**:[C-1] 辅助表迁移(这是最大块,2-4h)
4. **这周做**:[H-1] AdapterRegistry AsyncStream 改造(2-3h)+ [H-2] CI 门禁(30min)
5. **Optional**:[L-1] JSON 深度检查(30min,任何时候加都行)

合并 main 的阈值:C-1 / C-2 / C-3 三条全绿。H-1/H-2 可以放在同一 PR 或紧跟的 follow-up,但必须在推用户更新前完成。
