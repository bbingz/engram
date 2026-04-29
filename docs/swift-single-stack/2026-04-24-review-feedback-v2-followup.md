# v2 Review Follow-up —— 针对 6d732ca + 3e3d45c 两个修复 commit

**日期:** 2026-04-24
**对应 commits:**
- `6d732ca fix: address swift single stack v2 review`
- `3e3d45c test: harden swift backfill parity coverage`
**对应 review:** `docs/swift-single-stack/2026-04-24-review-feedback-v2.md`

---

## TL;DR

**v2 里 12 条 Critical/High 里,9 条完美完成,3 条部分,2 条未修。**额外发现 **2 条回归(N1/N2)**,都是本次修复引入的新问题,**必须在合 main 前处理**。

---

## 一、完美完成(9 条) — 无需再动

| v2 # | 状态 | 关键证据 |
|---|---|---|
| **X1** | ✅ | `EngramLogger.swift` -21 行,`forwardToDaemon` 整个删除,warn/error 只走 `os.Logger`。`App.swift` + `ProjectsView.swift` 里残留的 `print("...")` 也改成了 `EngramLogger.error(..., module: .ui, error:)` |
| **X2** | ✅ | `DaemonClient.swift`(-433) + `DaemonHTTPClientCore.swift`(-192) + `DaemonClientTests.swift`(-184) + `DaemonHTTPClientCoreTests.swift`(-127) + `MockDaemonFixtures.swift`(-86) + `MockURLProtocol.swift`(-51) 整体移除。`AppEnvironment.daemonPort` 字段删除。Xcode target 清理 |
| **X4** | ✅ | `EngramServiceLauncher.swift:140-159` `drain(pipe:, level:)` 用 `readabilityHandler` 消费 stdout/stderr,分别走 `EngramLogger.debug`/`.error`。`stopProcessOnly` 里把 `readabilityHandler = nil` 并释放 pipe 引用,防 leak |
| **X5** | ✅ | `UnixSocketServiceServer.swift` / `UnixSocketEngramServiceTransport.swift` / `EngramServiceCommandHandler.swift` 三处删除 shared `JSONEncoder()` / `JSONDecoder()` 实例,改成 per-call 新建。CommandHandler 抽了 `private static func encode<T: Encodable>(_ value: T) throws -> Data`。数据竞争解决 |
| **X7** | ✅ | `TranscriptExportService.swift:140-158` `redactSensitiveContent(_:)` 3 条正则:(a) generic key=value 模式;(b) Authorization: Bearer;(c) sk-/ghp_/xoxb- 特定前缀。JSON 和 markdown 导出都过过滤。`setAttributes([.posixPermissions: 0o600])` 写入后 chmod |
| **X8** | ✅ | `FTSRebuildPolicy.swift:22` `UPDATE sessions SET size_bytes = 0` 整行删除 |
| **X10** | ✅ | `StartupBackfillTests.swift`:<br>• codex originator 加反例 `codex-2`(originator="Codex CLI",期望不触发 dispatched),并断言 `agent_role` 和 `tier` 均为 nil<br>• quality score 从 1 个硬编码 72 扩到 3 cases(balanced-tool-session / short-chat-no-tools / long-tool-heavy-session)+ 新增 `expectedQualityScore(...)` 函数按公式计算期望值(turn 30% + tool 25% + density 20% + project 15% + volume 10%),彻底替代 magic number |
| **X11** | ✅ | `EngramServiceCommandHandler.swift:887-980` `isAllowedSessionFilePath(path:, source:)` 白名单 + `containsSensitivePathComponent` 黑名单(.ssh/.aws/.gnupg/.kube/.docker/.1password/Library/Keychains)。linkSessions 循环里先 guard,拒绝时写入 errors 并 continue |
| **H1** | ✅ | `stage4.md` 诚实重写,明确 "Project move/archive/undo/batch execution remains intentionally unavailable... until the native migration pipeline is ported"。`app-write-inventory.md` 从 "Conflict" 改为 "Resolved" |

---

## 二、部分完成(3 条) — 建议补强

### X3 project UI 按钮(部分)

**现状:** Service 层 `EngramServiceCommandHandler.swift:814-836` 四个 `project*` **仍然抛 `unsupportedNativeCommand(...)`**(没改),这符合 stage4.md 的"intentionally unavailable"策略。

**但 UI 侧:**
- `ProjectsView.swift` 只改了 2 处 print → EngramLogger,**没看到 ArchiveSheet / RenameSheet / UndoSheet 的 diff**
- 能看到 `nativeProjectMigrationCommandsEnabled` gate(L218 附近),若此 flag 为 false 则不加载 migrations

**建议:**
1. 确认 `nativeProjectMigrationCommandsEnabled` 当前为 `false` 且完整覆盖所有 Archive / Rename / Undo 按钮的可见性 → Smoke test:构建 Release,打开 ProjectsView,验证不出现"归档/重命名/撤销"按钮
2. 若 gate 只管部分 entry,剩下的按钮需要加同一 gate
3. **不然用户点按钮会收到 `UnsupportedCommand` 错误**,体验破损

### X6 JSON DoS(frame 限 256KB,深度未限)

**改了:** `UnixSocketEngramServiceTransport.swift:4` `maximumFrameLength = 256 * 1024`(从 32MB 降下来),显著收窄攻击面。

**未改:** JSON 嵌套深度 / 数组长度 / 字符串长度无硬限。256KB payload 内 `{"a":` 重复 ~50000 次可触发 Foundation JSONDecoder 递归栈溢出。

**实用影响:** Unix socket 在 `~/.engram/run/`,权限 0700,只有同 user 进程可达 → 攻击面限本机。对正常用户场景,不是 blocker。

**建议(可做可不做):** 自定义 JSONDecoder wrapper 预扫描深度,或单独起一个 `JSONDecoder.allowsJSON5 = false` + 做 `try JSONSerialization.jsonObject(with: frame, options: [.fragmentsAllowed])` 前置深度统计。低优先级。

### X12 socket DoS(部分)

**改了:** `UnixSocketServiceServer.swift` `ServiceConnectionLimiter(value: 32)` 限制并发;`setSocketTimeout(client, seconds: 10)` 设置 SO_RCVTIMEO/SO_SNDTIMEO。

**已够用:** per-read 字节超时虽未显式实现,但连接级 10s timeout 已经防住最慢的 slow-read(每连接最多拖 10s 再被强制断开)。

---

## 三、未修(2 条)

### H4 大文件 OOM(未修)

- `macos/Shared/EngramCore/Adapters/AdapterRegistry.swift` 无变化
- `macos/EngramCoreWrite/Indexing/SwiftIndexer.swift` 无变化

v2 明确列在"合并前强烈建议"里。建议按 Qwen C 在 v2 review 讨论里给的 `AsyncStream<SnapshotBatch>` 改造方案,把 collect-to-array 改成分批 1000 条 flush。

### H7 Schema compat CI 门禁(脚本加强但未接 CI)

`scripts/db/check-swift-schema-compat.ts` +108 行加了:
- `nodeCompatibleTables` 清单(sessions / sync_state / metadata / project_aliases / session_local_state / session_index_jobs / migration_log / usage_snapshots / git_repos / session_costs / session_tools / session_files / logs / traces / metrics / metrics_hourly / alerts / ai_audit_log)
- `ColumnSignature` 和 `ColumnInfoRow` 做列级对比

但 **没看到 `.github/workflows/` 改动**,脚本仍需手跑。建议加一个 CI step,在 swift-unit job 后:

```yaml
- name: Swift vs Node schema compatibility gate
  run: npx tsx scripts/db/check-swift-schema-compat.ts
```

---

## 四、🚨 本次修复引入的回归(2 条,必修)

### 🔴 N1(Critical)—— 辅助表 schema 大改,老用户升级会崩

**文件:** `macos/EngramCoreWrite/Database/EngramMigrations.swift`(+51/-36)

**改动清单(朝 Node 对齐,意图正确):**
| 表 | 变化 |
|---|---|
| `session_tools` | `count INTEGER NOT NULL DEFAULT 0` → `call_count INTEGER DEFAULT 0`(列名改) |
| `session_files` | `action TEXT / count NOT NULL DEFAULT 0` → `action TEXT NOT NULL / count DEFAULT 1`(可空性 + 默认值改) |
| `logs` | 加 `span_id / error_name / error_message / error_stack`;去掉 `request_id / request_source`;`source` 加 `CHECK IN ('daemon','app')`;`ts` 加 `DEFAULT strftime(...)` |
| `traces` | 加 `id INTEGER AUTOINCREMENT`;`kind` → `module`;`duration_ms REAL` → `INTEGER`;`status` 加 `NOT NULL DEFAULT 'ok'`;加 `source CHECK` |
| `metrics_hourly` | 主键 `(name, hour)` → 加 `id AUTOINCREMENT / type / tags + UNIQUE(name,type,hour,tags)`;列 min/max 从 nullable 改 NOT NULL;去掉 p50/p99 |
| `alerts` | `id TEXT PRIMARY KEY / data / ts NOT NULL` → `id INTEGER AUTOINCREMENT / ts DEFAULT strftime(...) / severity CHECK / value / threshold / dismissed_at` |
| `ai_audit_log` | 结构完全重写:加 `operation / request_source / method / url / status_code / duration_ms / provider / prompt_tokens / completion_tokens / total_tokens / request_body / response_body / meta`,删 `request / response / input_tokens / output_tokens / cost_usd` |
| `git_repos` | 去 `dirty_count / untracked_count / unpushed_count / last_commit_hash / last_commit_msg / last_commit_at / updated_at NOT NULL`;加 `session_count / probed_at` |
| `session_costs` | `computed_at NOT NULL` → nullable |

**问题:** `EngramMigrations.createOrUpdateBaseSchema` 里全是 `CREATE TABLE IF NOT EXISTS`,`addSessionColumnsIfNeeded` **只处理 `sessions` 一张表**。

**后果:** 老用户 `~/.engram/index.sqlite` 里这些表已经按旧 schema 建好。新 Swift 启动时 `IF NOT EXISTS` no-op。然后:
- 查 `session_tools.call_count` → "no such column: call_count"
- INSERT `session_files.action = NULL` → `NOT NULL constraint failed`
- INSERT `logs.source = 'app'` → 老表没 CHECK 约束不炸,但读取时看到有 'daemon' 之外的值
- INSERT `traces.module` → "no such column"
- ai_audit_log 几乎每个字段都断

一次升级,整个 observability + tool/file 统计全部 broken。

**修复方向(2 选 1):**
1. **推荐**:加 `addLogsColumnsIfNeeded` / `addTracesColumnsIfNeeded` / `addSessionToolsColumnsIfNeeded` 等 `ALTER TABLE` 迁移函数,逐列 `PRAGMA table_info` + `ADD COLUMN` 或 rename。对于重命名列(session_tools.count → call_count)需要 `ALTER TABLE ... RENAME COLUMN` (SQLite 3.25+,macOS 系统 sqlite 2020+ 版本都有)
2. **激进**:metadata 加 `schema_version=2`,若检测到旧版本则 `DROP + CREATE` 重建这些表(**丢失历史 logs/traces/costs 数据**,慎重)

**补充 CI 保护:** `scripts/db/check-swift-schema-compat.ts` 现在只对比 **schema 定义**,不验证 **升级路径**。建议加一个 "fixture: 预填 v1 schema 的 sqlite → Swift 启动 → 查各列不报错" 的端到端测试。

---

### 🔴 N2(Critical)—— `insights.deleted_at` 被删除,软删功能消失

**文件/行:**
- `EngramMigrations.swift:284-293` `CREATE TABLE insights` 不再有 `deleted_at TEXT` 列
- `EngramServiceCommandHandler.swift:493` 同表建表冗余定义也去掉了 `deleted_at`
- `CommandHandler.swift:679` UPSERT `ON CONFLICT DO UPDATE` 去掉了 `deleted_at = NULL` 重置
- `CommandHandler.swift:757 / 769` 两个查询去掉了 `WHERE deleted_at IS NULL`

**后果:**
- CLAUDE.md 明确指出 insights 支持软删("`deleteInsight()` helper 从两张表里删")。删除这列等于 **软删功能失效**
- 老用户若有 `deleted_at != NULL` 的 insight,新 schema 下这列不存在(或查询绕过),这些"已删除" insight 会重新出现,**UI 上看到已经删掉的记忆回来了**
- `save_insight` 工具行为改变:v1 支持软删除-恢复,v2 只能硬删

**需要 Codex 回答:**
1. 这是**有意对齐 Node 当前 schema**(Node 那边已经没有 `deleted_at`)吗?
2. 如果是,软删功能是在 Node 侧通过其他机制实现(比如独立 `deleted_insights` 表 / application-level filter)?
3. 如果不是,这就是 regression,必须回滚

---

## 五、综合建议

### 合并前必修

1. **N1** 辅助表 schema migration 路径(`ALTER TABLE` 式或 schema_version 机制)
2. **N2** 确认或回滚 `insights.deleted_at` 的删除
3. **X3** smoke test `nativeProjectMigrationCommandsEnabled=false` 真的禁用了 UI 按钮(简单验证,不是改代码)

### 强烈建议(但可进下一个 PR)

4. **H4** `AdapterRegistry.collectSnapshots` AsyncStream 改造
5. **H7** `scripts/db/check-swift-schema-compat.ts` 接入 `.github/workflows/test.yml`

### 可选防御加强

6. **X6** JSON 嵌套深度 check(defense-in-depth,低优先级)

---

## 六、Codex 做得特别好的地方 🎉

1. **测试加固质量高**:commit 2(`3e3d45c`)的 `expectedQualityScore(...)` 把硬编码 magic number 替换为**可计算的期望公式**,这正是 MiniMax C 在 review 里指出的 stub-class bug 模式的正确修复方式。以后 quality score 公式变,测试自动跟着更新,不会成为阻碍重构的僵尸断言
2. **linkSessions 白名单分 source 定义**,比单一全局白名单更细粒度,且黑名单覆盖了所有常见敏感目录
3. **drain Pipe 机制**清晰,stop 时正确解绑 readabilityHandler,避免了 Swift Process 常见的 pipe retain cycle
4. **stage4.md 诚实重写**,没有粉饰 projectMove 这类 "intentionally unavailable",对后续 maintainer 友好
5. **schema compat 脚本加了 `nodeCompatibleTables` + `ColumnSignature`**,虽然没接 CI 但工具本身是就位了,接 CI 是最后一步

---

**发给 Codex 的精简操作清单:**

- [ ] **N1**:为 session_tools / session_files / logs / traces / metrics_hourly / alerts / ai_audit_log / git_repos 等表加 `addXxxColumnsIfNeeded` 风格的 idempotent migration,或引入 `metadata.schema_version=2` 机制
- [ ] **N2**:确认 `insights.deleted_at` 删除的意图。如果是 regression,回滚列和相关查询
- [ ] **X3**:smoke test ProjectsView,确认 Archive/Rename/Undo 按钮在当前 gate 下真的不可见
- [ ] **H4**:AdapterRegistry collect-to-array → AsyncStream(可放 follow-up PR)
- [ ] **H7**:接 CI(可放 follow-up PR)
