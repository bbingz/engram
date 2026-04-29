# Engram 接管项目目录操作 — 实现方案

> **状态**: 已审定 (2026-04-20, rev 2 — 吸收 Codex + Gemini 双轨 review)
> **前置**: `/Users/example/-Code-/_项目扫描报告/engram_接管_项目目录操作_handoff.md`
> **路径**: A (全 TS 原生重写)
> **MVP 产品维度**: undo / audit / archive / Swift UI / batch YAML — 全做，分 phase 交付
> **设计哲学**: engram 提供机制（FS+DB+watcher 一体感知），用户/AI 决定政策（什么时候归档/重命名/撤销）。这是 engram 作为"唯一跨工具聚合器"的自然延伸，不是职责越界。

## Rev 2 变更摘要（2026-04-20 下午）

两位审稿人命中 6 个 blocker + 8 个 major。全部采纳，关键变化：

| 变更 | 原方案 | 修订后 | 来源 |
|---|---|---|---|
| migration_log 写入时机 | FS 完成后写 | **三阶段**：fs_pending (FS 前) → fs_done (FS 后) → committed (DB 事务末) | Codex + Gemini |
| SQL 前缀匹配 | `LIKE @old \|\| '%'` | `= @old OR LIKE @old \|\| '/%'` | Codex |
| Watcher 竞态 | 无保护 | onUnlink 前查 `hasPendingMigrationFor(path)`，命中则跳过标 orphan | Gemini |
| 源覆盖 | 5 源 | **6 源（+copilot）** — mvp.py 本来就 6 个 | Codex |
| 核心表更新 | 只 UPDATE sessions | **+ UPDATE session_local_state.local_readable_path**（UI 读优先） | Codex |
| Swift UI 交互 | 基于 group.project 字段 mv | UI 反查 DB 里该 project 所有 session 的 cwd，一致自动用；不一致 picker；真触发 MCP | Gemini |
| Diff-test 策略 | 仅 Python golden oracle | **golden + 独立 invariant test**（幂等、边界、前缀撞车）；代码规范禁止 JSONL patch 路径上 `JSON.parse` | Codex + Gemini |
| 正则翻译 | `new RegExp(str)` | `/regex literal/` + `Buffer` 字节级替换 | Codex |
| 跨卷 mv | `fs.cp({preserveTimestamps})` | + `lstat` symlink + mode bits + partial-copy 清理 | Codex |
| YAML schema | 未冻结 | 冻结 v1，预留 `continue_from` 字段 | Codex |
| Phase 4 工时 | 1 天 | 拆 4a MCP 0.5d + 4b Swift UI 2d = **2.5d** | Gemini |
| 历史数据修复 | 批量 UPDATE source_locator 到新路径（假装修好） | **诚实**：文件没了的 → `confirmed orphan` + `cleaned_by_source`，audit 报告明写原因 | 本方案决策 |

---

## 1. 架构总览

```
┌─────────────────────────────────────────────────────────┐
│  CLI:  engram project {move,review,audit,archive,undo}  │
│        engram project move-batch <yaml>                  │
└───┬─────────────────────────────────────────────────────┘
    │                                                      
    ├─ MCP tools: project_move / project_review / ...     
    ├─ Swift UI:  菜单栏 "重命名/归档" 按钮                
    │                                                      
    └─▶ src/core/project-move/                             
           orchestrator.ts   # 7-step pipeline             
           fs-ops.ts         # 物理 mv + CC 目录重命名      
           jsonl-patch.ts    # 6 源 JSONL cwd patch (incl. copilot)
           review.ts         # own/other 分类 + .\" auto-fix 
           audit.ts          # SQL → md 表                 
           batch.ts          # YAML 批处理                  
           undo.ts           # 对称回滚                    
                                                            
        src/core/db/migration-log-repo.ts                   
        src/core/db/maintenance.ts  ← applyMigrationDb()   
        src/core/watcher.ts         ← 已加 unlink hook     
```

---

## 2. 数据模型

### 2.1 新增 `migration_log` 表

```sql
CREATE TABLE migration_log (
  id                TEXT PRIMARY KEY,         -- uuid
  old_path          TEXT NOT NULL,            -- absolute src
  new_path          TEXT NOT NULL,            -- absolute dst
  old_basename      TEXT NOT NULL,
  new_basename      TEXT NOT NULL,
  state             TEXT NOT NULL DEFAULT 'fs_pending',
                     -- fs_pending (FS 开始前写入) →
                     -- fs_done    (FS + JSONL patch 成功后写入) →
                     -- committed  (DB 事务内最后一步写入) →
                     -- failed     (任意阶段抛错时写入，保留诊断信息)
  files_patched     INTEGER NOT NULL DEFAULT 0,
  occurrences       INTEGER NOT NULL DEFAULT 0,   -- 总替换数
  sessions_updated  INTEGER NOT NULL DEFAULT 0,   -- DB 侧 UPDATE 的行数
  alias_created     INTEGER NOT NULL DEFAULT 0,   -- 0/1
  cc_dir_renamed    INTEGER NOT NULL DEFAULT 0,   -- 0/1
  started_at        TEXT NOT NULL,
  finished_at       TEXT,                        -- NULL = in-flight / crashed
  dry_run           INTEGER NOT NULL DEFAULT 0,
  rolled_back_of    TEXT,                        -- 另一条 migration_log.id
  audit_note        TEXT,                        -- 来自 batch YAML
  archived          INTEGER NOT NULL DEFAULT 0,   -- archive 语义标记
  actor             TEXT NOT NULL DEFAULT 'cli',  -- cli|mcp|swift-ui|batch
  detail            TEXT,                         -- JSON: per-source patch counts + error trace
  error             TEXT                          -- 最后一个失败原因（state='failed' 时填）
);

CREATE INDEX idx_migration_log_started_at ON migration_log(started_at DESC);
CREATE INDEX idx_migration_log_paths ON migration_log(old_path, new_path);
CREATE INDEX idx_migration_log_state ON migration_log(state);
-- 查 pending migrations（watcher 用）
```

**三阶段写入（关键 — 解决 "先斩后奏" 漏洞）**：

```
Phase A (FS 开始前):  INSERT state='fs_pending', started_at=now, finished_at=NULL
Phase B (FS + patch 成功后):  UPDATE state='fs_done', detail=per-source stats
Phase C (DB 事务末尾):  UPDATE state='committed', finished_at=now, sessions_updated=N
异常:  UPDATE state='failed', error=<msg>, finished_at=now
崩溃恢复: engram project recover  扫 state != 'committed' 的 log 行
```

### 2.2 继续维护 `project_aliases`（已存在）
无 schema 变动。`project move` 在 basename 变化时自动 insert。

### 2.3 `orphan_*` 列（已于 2026-04-20 加）
`project move` 修复旧路径的 session 时，如果文件还在 → 清空 orphan flag；如果文件不在 → 保持 `suspect`（mvp 无法搬丢失的文件）。

---

## 3. 7-Step Pipeline（核心职责）

复刻 mvp.py 的全部步骤 + 加 DB 事务。

| # | 动作 | mvp.py 来源 | TS 新增/继承 |
|---|---|---|---|
| -1 | **Phase A: INSERT migration_log (state=fs_pending)** | — | 新写 |
| 0 | Git dirty 检查（警告 + 要求确认；`--force` 越过；v1.1 做智能 stash） | `git_warn_if_dirty` | 继承 |
| 0.5 | **Acquire lock `~/.engram/.project-move.lock`**（防并发） | — | 新写 |
| 1 | 物理 `fs.rename`（EXDEV → cp+rm 回退，保 symlink/mode/mtime） | `shutil.move` | 翻译 + 跨卷细节 |
| 2 | CC 编码目录重命名 `~/.claude/projects/<enc>` | `encode_cc` + `shutil.move` | 翻译 |
| 3 | **6 源** JSONL cwd patch（+copilot；**正则原样搬**，Buffer bytes-level，禁 JSON.parse） | `patch_file` + `grep_files` | **1:1 翻译 + diff-test + invariant test** |
| 4 | `<old>."` 句末 auto-fix | `auto_fix_dot_quote` | 翻译 |
| 4.5 | **Phase B: UPDATE migration_log (state=fs_done)** | — | 新写 |
| 5 | **DB 事务（新增）**: UPDATE sessions (source_locator/file_path/cwd 带 '/' 边界) + UPDATE session_local_state + upsert alias + 清 orphan + UPDATE migration_log (state=committed, sessions_updated) | — | 新写 |
| 6 | Review 扫描（own/other 分类，6 源） | `review_scan` | 翻译 |
| 99 | **异常路径**：任意步失败 → UPDATE migration_log (state=failed, error=...); release lock; 抛给调用方 | — | 新写 |

### Step 5 事务细节（rev 2 — 修复前缀撞车 + 补 session_local_state）

```ts
db.transaction(() => {
  // 5a. UPDATE sessions — 用 '/' 边界避免 /foo/bar 误伤 /foo/barbar
  const boundary = "(source_locator = @old OR source_locator LIKE @old_slash"
                 + " OR file_path = @old OR file_path LIKE @old_slash"
                 + " OR cwd = @old OR cwd LIKE @old_slash)";
  db.raw.prepare(`
    UPDATE sessions
       SET source_locator = CASE WHEN source_locator = @old THEN @new
                                 WHEN source_locator LIKE @old_slash
                                   THEN @new || SUBSTR(source_locator, LENGTH(@old)+1)
                                 ELSE source_locator END,
           file_path      = CASE WHEN file_path = @old THEN @new
                                 WHEN file_path LIKE @old_slash
                                   THEN @new || SUBSTR(file_path, LENGTH(@old)+1)
                                 ELSE file_path END,
           cwd            = CASE WHEN cwd = @old THEN @new
                                 WHEN cwd LIKE @old_slash
                                   THEN @new || SUBSTR(cwd, LENGTH(@old)+1)
                                 ELSE cwd END,
           orphan_status  = NULL,  -- 原路径僵尸自愈
           orphan_since   = NULL,
           orphan_reason  = NULL
     WHERE ${boundary}
  `).run({ old, new, old_slash: `${old}/%` });

  // 5b. UPDATE session_local_state — UI 读 local_readable_path 优先（Codex blocker）
  db.raw.prepare(`
    UPDATE session_local_state
       SET local_readable_path = CASE
             WHEN local_readable_path = @old THEN @new
             WHEN local_readable_path LIKE @old_slash
               THEN @new || SUBSTR(local_readable_path, LENGTH(@old)+1)
             ELSE local_readable_path END
     WHERE local_readable_path = @old OR local_readable_path LIKE @old_slash
  `).run({ old, new, old_slash: `${old}/%` });

  // 5c. basename 变了才加 alias（幂等；alias 是 basename 级别，不是完整路径）
  if (oldBasename !== newBasename) db.addProjectAlias(oldBasename, newBasename);

  // 5d. FTS 不重建（sessions_fts 存 summary+project+model，与路径无关）

  // 5e. UPDATE migration_log: state='committed', finished_at=datetime('now'), sessions_updated=N
}).call();
```

**事务边界**：严格限制在 DB 内。FS 操作（mv、rename CC dir、JSONL patch）发生在事务之前，不在事务里（它们本来就不可回滚）。三阶段 migration_log 写入保证 FS 成功但 DB 事务失败时仍有诊断行。

---

## 4. CLI 形状

```bash
# 单次
engram project move <src> <dst>                   # 交互确认
engram project move -y <src> <dst>                # 非交互
engram project move -n <src> <dst>                # dry-run（plan only）
engram project move --force <src> <dst>           # 越过 git dirty 拦截

# 归档语义糖
engram project archive <src>                      # 自动推导 _archive/... 目标
engram project archive <src> --to 历史脚本         # 显式选择子目录

# 审计
engram project review <old-path> <new-path>       # 代替 mvp --review-only
engram project audit --since 2026-04-01 --format md   # 生成归档记录表
engram project audit --batch <id>                 # 查某次批处理

# 撤销
engram project undo <migration-id>                # 对称回滚
engram project list --recent 20                   # 列 migration_log

# 批处理
engram project move-batch <yaml>                  # 多步

# 孤儿
engram project orphan-scan                         # 手动触发（daemon 启动已自动跑）
engram project orphan-list --reason cleaned_by_source
```

### 归档语义推导规则（`--archive`）

参照用户 `/Users/example/-Code-/_项目扫描报告/CLAUDE.md` 的 `_archive/` 结构：

| 源特征 | 自动推导目标 |
|---|---|
| basename 形如 `YYYYMMDD-*` | `_archive/历史脚本/<basename>` |
| 源目录为空或只有 README | `_archive/空项目/<basename>` |
| 有 `.git` 且有实际内容 | `_archive/归档完成/<basename>`（新增） |
| 其它 | 要求 `--to` 显式指定 |

推导逻辑单独成函数 `suggestArchiveTarget(srcPath)`，可单测。

---

## 5. MCP 工具

直接镜像 CLI：

```ts
project_move(src, dst, { dry_run?, yes?, force?, archive? })
project_review(old_path, new_path)
project_audit({ since?, until?, format?, batch_id? })
project_undo(migration_id)
project_archive(src, { to? })
project_move_batch(yaml_content, { dry_run? })
project_orphan_scan()
project_list_migrations({ recent?, since? })
```

每个工具返回结构化 JSON（session 更新数、occurrence 数、review 的 own/other 列表等），供调用方自行格式化。

---

## 6. Swift UI 暴露（rev 2 — 反查 cwd 而非 group.project）

**关键修正（Gemini blocker）**：
`ProjectsView.swift:67` 的 `group.project` 是 DB `sessions.project` 字段的聚合 key，**不是物理绝对路径**。直接拿它当 mv 源会错。

**正解**：点"重命名"时：
1. 从 DB 查该 project 下所有 session 的 `cwd` 字段（distinct）
2. 只有一个 distinct cwd → 自动作源路径
3. 多个 distinct cwd（很少但可能，比如 project 名相同但跨 `/Users/example/-Code-/foo` 和 `/Users/example/-Automations-/foo`）→ 弹 picker 让用户选
4. 全部为空 → 禁用"重命名"菜单项 + 提示"此 project 无 cwd 记录，无法定位物理路径"

**v1 MVP（Phase 4b，2 天）**：
- ProjectsView card `⋯` 菜单 → "重命名" / "归档" / "撤销移动"
- "重命名"：反查 cwd → 弹 sheet → 输入新路径 → 预览影响 session 数 → 确认后调 MCP `project_move` → spinner → 完成后 refresh
- "撤销移动"：读 `migration_log` 最近 5 条（state='committed'），单选 → 调 MCP `project_undo`
- 进度：只用 `ProgressView()` spinner，不做精细进度条
- 错误：完成回调里若 state='failed'，展示 `error` 字段

**v1.1**：
- 精细进度（daemon emit `project_move_progress` 事件，IndexerProcess 订阅）
- 主窗口加 Migrations 页面（表格：时间/旧路径/新路径/影响数/状态）
- "导出今日归档 md" 按钮 → `project audit --format md` 写剪贴板

实现放在 `macos/Engram/Views/Pages/ProjectsView.swift` 扩展 + 新增 `Views/Projects/RenameSheet.swift`、`Views/Projects/UndoSheet.swift`。

---

## 7. 测试策略（rev 2 — 双层保障）

路径 A 的最大风险是 JSONL patch 正则移植出 bug。**不能只用 Python mvp 做 golden oracle**（会把 mvp 的潜在 bug 固化）。双层保障：

### 7.1 Golden Samples（回归 baseline）

```
tests/fixtures/project-move/
  golden/
    coding-memory-to-engram/
      input/           # 匿名化的 JSONL 子集
      expected/        # Python mvp 产物
    invoice-space-rename/
      input/
      expected/
    cross-parent-glm/
      input/
      expected/
  diff-test.ts
```

流程：
1. 当前 git branch 用 Python mvp 对 input 跑一次，生成 expected，提交
2. TS 版每次跑 `npm test -- project-move/diff-test`，bytes 比对
3. 任何差异都是回归信号（可能是 TS bug，也可能是 mvp 被发现 bug，需要人工判断）

### 7.2 Independent Invariant Tests（不依赖 Python）

直接写 TS 断言验证**性质**，不依赖外部 oracle：

1. **幂等**：`patch(patch(X)) === patch(X)`（同一替换跑两次 = 一次）
2. **对称**：`patch(A→B); patch(B→A)` 还原到 bytes 级
3. **前缀边界**：`/foo/bar` 的替换 **不触及** `/foo/barbar` / `/foo/bar-baz`
4. **终止符全列举**：`" ' / \ < > ] ) } backtick \s EOF` 逐个构造 case
5. **排除符**：`.` `,` `;` `-` `_` 后面的不替换（保 `.bak` `.py`）
6. **UTF-8 边界**：路径含中文字符时，字节正则依然按 UTF-8 字节精确匹配
7. **`."` auto-fix**：纯单元测试，不走 grep

### 7.3 代码规范硬约束

- **JSONL patch 路径禁止 `JSON.parse(line)`**（Gemini 提醒的次生风险）
- 正则用 **regex literal** `/.../`，不用 `new RegExp(str)`
- 字节级替换走 `Buffer`，不走字符串

### 7.4 Golden 样本覆盖清单

- 普通路径 `/Users/example/-Code-/X` → `/Users/example/-Code-/Y`
- 跨父目录 `-Code-/X` → `-Automations-/X`
- basename 含空格和尾部空格 `-Invoice Management-   ` → `Invoice-Management`
- `."` 句末
- 连续 `-` 的 CC 编码边界 `coding-memory` → `engram`
- 前缀撞车 `/foo/bar` 存在于含 `/foo/barbar` 的上下文
- 6 源全覆盖（Claude CC / Codex / Gemini / OpenCode / Antigravity / **Copilot**）

---

## 8. mvp 退役节奏（用户定 "激进"）

| Phase | 时间 | mvp 状态 |
|---|---|---|
| 0 | 立刻 | mvp.py 原样保留，engram 新增 DB 事务 + migration_log + CLI 骨架 |
| 1 | +1 周 | `/Users/example/-Code-/_项目扫描报告/mvp` 变 shim：`exec engram project move "$@"`；Python 代码搬到 `engram/archive/mvp-reference.py` 作 diff-test 锚点 |
| 2 | +2 周 | 所有功能 TS 原生，Python 不再需要 runtime 依赖；mvp.bak-20260419 保留 |
| 3 | +1 月 | mvp shim 加 `echo "deprecated, invoking engram..."` banner |

---

## 9. TODO（v1 不做，明确延后）

每条 CLI / MCP 工具输出里要明文告知用户"此局限 v1 未实现"。

1. **虚拟路径 adapter 覆盖**（opencode / cursor）：
   - opencode: `UPDATE session SET directory = ... WHERE directory LIKE @old || '/%'`（注意 '/' 边界）
   - cursor: composer data 的 cwd 字段在 `cursorDiskKV` JSON blob 里
   - v1 CLI 输出：**明文警告** "OpenCode / Cursor 路径未更新，请手动处理"
   - v1.1 加 `--write-external-dbs` opt-in 开关
   - 道德红线：默认不改别家 DB
2. **Git dirty 智能前置**：纯 whitespace 或全 untracked → 用户同意下自动 stash；其它仍拒绝
3. **跨 host 迁移**：Time Machine 恢复场景 → `project remap-host <old-prefix> <new-prefix>`
4. **chokidar 原生 rename 事件**：比 unlink + add 更准确（fsevents 支持）；实验支持度后决定
5. **TUI 勾选界面**：代替 YAML 批处理（Gemini 建议；v1.2）
6. **精细进度条**：daemon emit `project_move_progress` 事件，Swift 订阅（v1.1）
7. **`project migrations` 主窗口页**：类 activity 页的表格化展示（v1.1）

---

## 10. 风险清单 + Mitigations

| 风险 | 概率 | 影响 | Mitigation |
|---|---|---|---|
| JSONL 正则移植 bug | 中 | 严重（数据损坏） | Diff-test + golden samples + CI |
| DB 事务部分完成后 FS 操作失败 | 低 | 中（DB 指向不存在路径） | FS 先做完再开事务；事务失败有 migration_log.finished_at=NULL 可人工清理 |
| Claude CC 目录编码歧义（连续 `-`） | 低 | 中（decoding 不可靠） | 只做单向 encoding；decode 不实现；用户永不该从 CC 目录名反推原路径 |
| 跨卷 mv 权限/时间戳丢失 | 低 | 低 | `fs.cp({ preserveTimestamps: true })` + 测试 |
| 批处理中途失败 | 中 | 低 | `stop_on_error: true` 默认；已完成的有 migration_log，可继续从下一条 |
| 用户在 project move 进行中手动动文件 | 低 | 中 | 加 advisory lock 文件 `~/.engram/.project-move.lock`，已有就拒绝启动 |
| DB UPDATE 匹配到不该改的 session（同名其他项目） | 低 | 严重 | 用 `LIKE @old || '/%'` 而非 `LIKE @old || '%'`（带斜杠，避免前缀撞车）；加测试 case `/foo/bar` vs `/foo/barbar` |

---

## 11. 交付顺序（细化 handoff §6）

**Phase 0（今天）**: 方案对齐 + 2 个 agent review

**Phase 1（1.5 天）— DB 事务 + 三阶段 log + watcher guard**
- [ ] Schema migration: `migration_log` 表 + 3 个索引
- [ ] `migration-log-repo.ts`: insert/update/find/listRecent/hasPendingFor(path)
- [ ] `applyMigrationDb(old, new, meta)` 函数（Step 5，修 SQL 边界 + session_local_state）
- [ ] `startMigration/finishMigration/failMigration` 三阶段 API
- [ ] Watcher `onUnlink` 加 `hasPendingMigrationFor(path)` 前置检查
- [ ] `engram project commit-migration <old> <new>` CLI 子命令（Python mvp 过渡期调用）
- [ ] 单元测试：正常 / basename 不变 / 前缀撞车（`/foo/bar` vs `/foo/barbar`）/ 幂等 / state 转换 / pending-migration watcher 跳过

**Phase 2（3 天）— FS + Patch 层 + Diff-test + Invariant test**
- [ ] `encode_cc` / `grep_files` / `patch_file` / `auto_fix_dot_quote` TS 翻译（6 源 incl. copilot）
- [ ] 代码规范：禁止 JSONL patch 路径 `JSON.parse`；regex literal；Buffer 字节级
- [ ] `safeMoveDir` 跨卷回退（symlink lstat / mode / partial-copy 清理）
- [ ] Golden samples: 用 Python mvp 跑 3-5 case 生成 expected，提交
- [ ] Independent invariant test：幂等 / 对称 / 前缀边界 / 终止符 / 排除符 / UTF-8 / `."`
- [ ] 对 coding-memory→engram 的 golden 回归测试

**Phase 3（2.5 天）— Orchestrator + CLI 外壳 + Undo**
- [ ] 7-step orchestrator（含三阶段 log + lock file）
- [ ] `engram project move/review/audit/archive/undo/list/recover/orphan-scan` 子命令
- [ ] `project move-batch` + YAML schema v1 parser（预留 `continue_from`）
- [ ] Undo：读 migration_log.state='committed' 的行 → 反向 move（src ↔ dst 交换）
- [ ] 归档启发式猜 + y/N 确认
- [ ] `project recover` 处理 crash 残留（state != 'committed'）

**Phase 4a（0.5 天）— MCP 工具**
- [ ] 8 个 MCP 工具注册（project_move / review / audit / undo / archive / move_batch / orphan_scan / list_migrations）

**Phase 4b（2 天）— Swift UI**
- [ ] DB 读方法：`listDistinctCwdsForProject(name)` 给 UI 反查
- [ ] ProjectsView card `⋯` 菜单 + RenameSheet + UndoSheet
- [ ] MCPServer 侧方法映射
- [ ] spinner + 完成刷新；错误 banner

**Phase 5（1 天）— mvp 退役 + 历史回归**
- [ ] `/Users/example/-Code-/_项目扫描报告/mvp` → shim: `exec engram project move "$@"`
- [ ] mvp.py 源码搬到 `engram/archive/mvp-reference.py` 作 diff-test 锚点
- [ ] 对 coding-memory → engram 这次历史迁移跑 `project audit`
- [ ] 251 条僵尸：确认没人能修好 → 批量标 `confirmed orphan` + `cleaned_by_source`
- [ ] 用户 CLAUDE.md 里 `$MVP` 兼容性验证

**预计总时长**: 10.5 工作日

---

## 12. 成功标准

离"完成"的定义：
1. `/Users/example/-Code-/_项目扫描报告/mvp -y /old /new` 和 `engram project move -y /old /new` 的**产物 bytes 完全一致**（diff-test 全过；注意：必须走 Buffer 字节路径，不经 JSON.parse）
2. Independent invariant tests 全绿（幂等 / 对称 / 前缀边界 / 终止符枚举 / UTF-8 / `."`）
3. `engram project move` 后跑 `detectOrphans` → 相关 session 全部可访问（如果有新增 orphan，说明 FS 操作或 Step 5 漏了源）
4. **Watcher 在 move 期间不误标 orphan**（通过 pending-migration guard；有专项测试）
5. **Crash 测试**：故意在 Phase B 后抛错，state='failed' 的行存在，`engram project recover <id>` 能诊断 + 修复
6. `engram project undo <id>` 后，FS + DB + 所有 JSONL 回到 move 之前的状态（bytes 级需要持平原始 mtime 等元数据，不强求；语义等价是硬要求）
7. 对 coding-memory → engram 那次历史迁移跑 `engram project audit`，产物与用户手写的归档记录表字段匹配
8. 923+ 现有测试全绿 + 新增 ≥ 50 条针对 project move 的测试（rev 2 加了 pending guard / three-phase state / local_readable_path / 6-source copilot 等新测试面）
9. `~/.engram/.project-move.lock` 在进程 crash 后能被 recover 命令清理（stale lock 检测）
10. Swift UI：ProjectsView rename sheet 在 distinct cwd 不一致时弹 picker（不是沉默用 group.project）

## 13. 与两位审稿人的分歧/澄清

**我 vs Gemini（1 条）**
- Gemini: "Diff-test bytes 一致是伪命题（TS JSON.stringify vs Python json.dumps 格式差异）"
- 回应: mvp.py `patch_file` 是纯字节操作（`data.replace(old_bytes, new_bytes) + write_bytes`），不经过 JSON 解析。TS 如果走 `Buffer` 字节级替换（见 §7.3 代码规范），bytes 一致是可达的。**但** Gemini 提醒的次生风险成立：如果 TS 手贱 `JSON.parse` 就破功。因此加代码规范硬约束。

**完全采纳（不赘述）**
- Codex 的 6 条 Blocker/Major + Gemini 的 5 条 Critical/Major 全部在 Rev 2 变更表里落地。
