# Engram 项目全面审计报告

**审计日期**: 2026-05-03
**审计团队**: 功能设计专家 · 代码实现专家 · 安全专家 · Web API 专家
**项目版本**: HEAD

---

## 执行摘要

本次审计从功能设计、代码实现、安全性、Web API 四个维度对 Engram 项目进行了全面评估。

**总体评分: 8.0 / 10**

| 维度 | 评分 | 亮点 | 主要风险 |
|------|------|------|----------|
| 功能设计 | 8.5/10 | 分层设计精细、降级策略健壮 | 噪声过滤迁移不一致、父子检测覆盖窄 |
| 代码实现 | 8.2/10 | 架构清晰、测试充分(1276个) | N+1查询、同步I/O阻塞事件循环 |
| 安全性 | 7.5/10 | 参数化SQL、PII脱敏、$HOME围栏 | 数据库文件权限宽松、依赖漏洞 |
| Web API | 7.8/10 | 功能丰富、IPC架构合理 | parseInt NaN缺失、错误格式不统一 |

---

## 一、发现总览

### 按严重程度统计

| 严重程度 | 数量 | 说明 |
|----------|------|------|
| 🔴 严重 | **16** | 需要尽快修复，可能影响数据安全或功能正确性 |
| 🟡 中等 | **35** | 建议近期修复，影响用户体验或代码质量 |
| 🟢 建议 | **18** | 可选优化，提升代码质量和可维护性 |

### 🔴 严重问题速查表

| # | 类别 | 问题 | 影响 | 修复量 |
|---|------|------|------|--------|
| 1 | 安全 | **SQLite 数据库文件权限 644，同机用户可读** | 数据泄露 | 30min |
| 2 | 安全 | **settings.json API Key 明文存储** | 凭据泄露 | 1h |
| 3 | 安全 | **依赖项 protobufjs 任意代码执行漏洞(CVE)** | 供应链攻击 | 30min |
| 4 | 安全 | **hono XSS 漏洞** | HTML注入 | 30min |
| 5 | 功能 | **缺少 `delete_insight` MCP 工具** | 用户无法删除错误 insight | 1-2h |
| 6 | 功能 | **缺少 `hide_session` MCP 工具** | AI助手无法管理噪声会话 | 2-3h |
| 7 | 功能 | **OpenAI embedding 缺少 L2 归一化，语义去重误判** | Insight被错误跳过 | 30min |
| 8 | 功能 | **Layer 2 父子检测来源仅限 claude-code/codex** | 遗漏跨工具父子关系 | 2-4h |
| 9 | 功能 | **噪声过滤配置迁移逻辑丢失细粒度控制** | 用户升级后噪声增多 | 1-2h |
| 10 | 代码 | **backfillSuggestedParents N+1 查询(500次循环)** | 大数据量启动缓慢 | 2-3h |
| 11 | 代码 | **backfillCodexOriginator 同步 I/O 阻塞事件循环 + fd 泄漏** | HTTP服务卡顿 | 2-3h |
| 12 | 代码 | **initVectorDeps 吞掉所有异常(含编程错误)** | bug被静默隐藏 | 1h |
| 13 | 代码 | **web.ts CLI 模式缺少 shutdown handler** | 数据库连接泄漏 | 1h |
| 14 | API | **7个端点 parseInt 缺少 NaN 检查** | SQL查询传入NaN | 1-2h |
| 15 | API | **缺少 Insights 查询/搜索 HTTP API** | Swift UI无法搜索insight | 3-4h |
| 16 | API | **缺少 API 文档(OpenAPI)** | 维护和集成成本高 | 4-8h |

---

## 二、功能设计审计（详情见 `functional-design-audit.md`）

### 2.1 会话分层（Session Tiering）

当前 4 层设计（skip/lite/normal/premium）整体合理，但存在以下问题：

| 严重度 | 问题 | 建议 |
|--------|------|------|
| 🟡 | 同步会话缺少 assistantCount，tier 判断不准 | 在 computeTier() 入口推断 assistantCount |
| 🟡 | lite 层混合噪声和有价值的沉默会话 | 拆分为 lite-noise 和 lite-silent |
| 🟢 | Premium 30 分钟阈值可能过低 | 引入"活跃时间"概念，或提升到 60 分钟 |
| 🟢 | 无 summary 的噪声会话 fallback 到 normal | 增加对空 summary 的检测 |

### 2.2 噪声问题

用户反馈"噪声很多"的根因分析：

1. **Codex probe 会话** — "ping"、"What is 2+2?" 探测消息
2. **title 生成泄露** — `"Generate a short, clear title"` 出现在摘要中
3. **/usage 检查会话** — 工具检查用量的瞬时会话
4. **Preamble-only 会话** — 仅有系统提示词的空壳

**关键问题**: 噪声过滤配置从旧版布尔开关迁移到 `noiseFilter` 字符串时，丢失了细粒度控制（🔴 严重）。

**建议**:
- 扩展 `NOISE_PATTERNS` 列表
- 在 `stats` 工具中增加噪声来源统计
- 在 UI 层增加 3 级噪声过滤选择器

### 2.3 父子会话分组

4 层检测（路径/起源/侧车/启发式）设计精良，但 Layer 2 有重要缺陷：

| 严重度 | 问题 | 建议 |
|--------|------|------|
| 🔴 | 父候选限于 claude-code/claude，子候选限于 gemini-cli/codex | 扩展来源或用排除法 |
| 🟡 | 4 小时时间窗口可能过于宽松 | 缩短到 2h，增加连续性信号 |
| 🟡 | `pickBestCandidate()` 永不拒绝模糊匹配 | 增加可配置置信度阈值 |
| 🟡 | Orphan 30 天宽限期无用户通知 | 在 suspect 阶段即提示用户 |

### 2.4 Insight 系统

双层存储（文本+向量）+ daemon 回填的降级设计非常健壮。但存在：

| 严重度 | 问题 | 建议 |
|--------|------|------|
| 🔴 | OpenAI embedding 未做 L2 归一化，cosine 转换不准确 | OpenAI 路径增加归一化 |
| 🟡 | 文本去重仅精确匹配最近 200 条 | 有 embedding 时优先语义去重 |
| 🟡 | get_memory 的 FTS fallback 不按重要性排序 | 按 `importance DESC` 排序 |
| 🟡 | Insight 无过期/衰减机制 | 引入时间衰减权重 |

### 2.5 功能完整性

| 严重度 | 缺失功能 | 建议 |
|--------|----------|------|
| 🔴 | 无 `delete_insight` MCP 工具 | 新增工具，调用已有底层函数 |
| 🔴 | 无 `hide_session` MCP 工具 | 新增工具，设置 `hidden_at` |
| 🟡 | `search` 工具隐藏参数未暴露给 schema | 在 schema 中声明 agents/tools 参数 |
| 🟡 | chunker 800 字符太短，代码块被截断 | 增加到 1500-2000，识别代码块边界 |
| 🟡 | `live_sessions` 在 MCP 模式下不可用 | MCP 模式下不注册该工具 |
| 🟢 | 无批量导出功能 | 新增 `export_project` |
| 🟢 | 工具描述中英文不一致 | 统一为英文 |

---

## 三、代码实现审计（详情见 `code-implementation-audit.md`）

### 3.1 性能问题

| 严重度 | 问题 | 文件 | 建议 |
|--------|------|------|------|
| 🔴 | N+1 查询：500 个候选各执行一次独立 SQL | maintenance.ts:440 | 预计算时间范围，单次批量查询 |
| 🔴 | 同步 I/O (openSync/readSync/closeSync) 阻塞事件循环 + fd 泄漏风险 | maintenance.ts:395 | 改用 async fs/promises |
| 🟡 | MetricsCollector.rollup() 全量加载到内存 | metrics.ts:139 | SQL 窗口函数或增量 rollup |
| 🟡 | detectOrphans 全量加载 + 逐条 await | maintenance.ts:313 | 批量检查 + 并发限制 |
| 🟡 | findDuplicateInsight 每次加载 200 行比对 | insight-repo.ts:53 | 存储 content hash，SQL 索引查找 |
| 🟡 | Watcher 缺少去抖/并发限制 | watcher.ts:103 | 工作队列 + max 3 concurrent |
| 🟡 | indexAll 完全串行处理 14 个适配器 | indexer.ts:250 | 适配器间并行 |
| 🟢 | getSourceStats 双查询可合并 | session-repo.ts:261 | 一次 JOIN 完成 |

### 3.2 代码质量

| 严重度 | 问题 | 文件 | 建议 |
|--------|------|------|------|
| 🔴 | initVectorDeps catch 吞掉所有异常 | bootstrap.ts:73 | 区分预期错误和编程错误 |
| 🟡 | ai-audit.ts 6 处 `as any` 类型断言 | ai-audit.ts:218 | 定义 Row 接口类型 |
| 🟡 | Database facade 80+ 纯转发方法(350行) | database.ts | 考虑直接使用 repo 模块 |
| 🟡 | web.ts 单文件 1978 行 | web.ts | 按功能域拆分路由 |
| 🟢 | watcher handleChange 无顶层 catch | watcher.ts:103 | 添加 try/catch 防 unhandled rejection |

### 3.3 资源管理

| 严重度 | 问题 | 文件 | 建议 |
|--------|------|------|------|
| 🔴 | web.ts CLI 入口无 SIGTERM/SIGINT handler | web.ts:1944 | 添加 signal handler + db.close() |
| 🟡 | daemon 9 个定时器未 unref() | daemon.ts:295 | 在 shutdown 中确保 unref |
| 🟡 | shutdownHandler 中 metrics.flush() 依赖 db 顺序 | bootstrap.ts:272 | 添加注释说明顺序依赖 |

### 3.4 数据库设计

| 严重度 | 问题 | 建议 |
|--------|------|------|
| 🟡 | 缺少 `sessions.project` 索引 | `CREATE INDEX idx_sessions_project ON sessions(project)` |
| 🟡 | 缺少 `sessions.origin` 索引 | 针对高频过滤字段建索引 |

### 3.5 测试质量

| 严重度 | 问题 | 建议 |
|--------|------|------|
| 🟡 | 缺少 daemon.ts 集成测试 | 创建 integration/daemon.test.ts |
| 🟡 | 缺少竞态条件测试 | watcher/indexer 并发场景 |

**亮点**: 1276 个测试用例，真实 fixtures，无 mocking 策略，覆盖所有 15 个 adapter。

---

## 四、安全审计（详情见 `security-audit.md`）

### 4.1 安全亮点 ✅

- 参数化 SQL 查询，未发现 SQL 注入
- 日志系统自动 PII/API Key 脱敏 (sanitizer.ts)
- HTTP API 的 `$HOME` 路径围栏 + `pathResolve()` 防路径遍历
- 非 localhost 绑定时自动生成 Bearer Token
- CORS 严格限制为 localhost
- `execFileSync` 而非 `execSync`，避免 shell 注入

### 4.2 数据安全

| 严重度 | 问题 | 建议 |
|--------|------|------|
| 🟡 | SQLite 数据库文件权限 644（同机用户可读） | 创建后 chmod 600 |
| 🟡 | settings.json 明文存储 API Key | writeFileSettings 设置 mode 0o600 |
| 🟢 | SQLite 未加密 | 文档说明，依赖 FileVault |
| 🟢 | 导出目录 ~/codex-exports/ 无权限控制 | mkdir 设置 mode 0o700 |

### 4.3 供应链安全

| 严重度 | 问题 | 建议 |
|--------|------|------|
| 🔴 | protobufjs < 7.5.5 任意代码执行漏洞 | `npm audit fix` |
| 🟡 | hono < 4.12.14 XSS 漏洞 | `npm audit fix` |
| 🟡 | postcss < 8.5.10 XSS 漏洞 | `npm audit fix` |

### 4.4 Web API 安全

| 严重度 | 问题 | 建议 |
|--------|------|------|
| 🟡 | GET 端点无认证（localhost 绑定时） | 添加 `httpAuthAllEndpoints` 配置 |
| 🟡 | 仅语义搜索有 Rate Limiting | 对所有 POST 端点添加 |
| 🟡 | 无请求体大小限制 | 添加 10MB 中间件限制 |
| 🟡 | Sync API GET 端点无认证 | 非 localhost 时要求认证 |
| 🟡 | timeline API 错误泄露原始异常 | 使用 `safeErrorMessage()` |
| 🟡 | /api/lint cwd 路径验证可被符号链接绕过 | 改用 `pathResolve()` |
| 🟢 | HTML 路由缺少 CSP 头 | 添加 Content-Security-Policy |

### 4.5 进程安全

| 严重度 | 问题 | 建议 |
|--------|------|------|
| 🟡 | lint_config MCP 工具 cwd 参数无路径验证 | 添加 $HOME 围栏检查 |
| 🟡 | 审计日志 logBodies=true 时可能记录敏感信息 | 确保经过脱敏处理 |

---

## 五、Web API 审计（详情见 `web-api-audit.md`）

### 5.1 API 设计

| 严重度 | 问题 | 建议 |
|--------|------|------|
| 🟡 | URL 单复数混用（`/api/session/` vs `/api/sessions/`） | 统一为复数 |
| 🟡 | 路径层级不一致（`project-aliases` vs `project/migrations`） | 统一风格 |
| 🟡 | 错误响应格式至少 3 种（简单字符串/结构化包络/混合） | 统一为结构化包络 |
| 🟢 | DELETE 端点用 body 传参（跨平台兼容性隐患） | 改为路径/查询参数 |

### 5.2 接口完整性

| 严重度 | 缺失接口 | 建议 |
|--------|----------|------|
| 🔴 | 无 Insights 查询/搜索 HTTP API | 添加 `GET /api/insights` |
| 🔴 | 无 `get_context` HTTP API | 添加 `GET /api/sessions/:id/context` |
| 🟡 | 无 `export` HTTP API | 添加 `GET /api/sessions/:id/export` |
| 🟡 | 分页格式不统一（hasMore/total/两者都有/两者都没有） | 定义统一 `PaginatedResponse<T>` |
| 🟡 | 缺少批量操作端点 | 考虑 batch/link, batch/hide |

### 5.3 数据一致性

| 严重度 | 问题 | 建议 |
|--------|------|------|
| 🔴 | 7 个端点 `parseInt` 缺少 NaN 检查 | 统一 `parseLimit/parseOffset` 工具函数 |
| 🟡 | 后台任务无并发保护（regenerate-all） | 添加 in-flight 标志 |
| 🟡 | JSON 解析错误被 `.catch(() => ({}))` 静默吞掉 | 区分 JSON 格式错误和缺失字段 |

### 5.4 性能

| 严重度 | 问题 | 建议 |
|--------|------|------|
| 🟡 | `/api/live` N+1 查询（每个 session 单独 SQL） | 批量 `WHERE file_path IN (...)` |
| 🟡 | `/api/costs/sessions` 绕过 Database facade | 移入 metrics-repo |
| 🟡 | 无 HTTP 层 Cache-Control | 对低频变化端点添加 max-age |
| 🟢 | `/api/repos` 无分页 | 添加 LIMIT |

### 5.5 文档

| 严重度 | 问题 | 建议 |
|--------|------|------|
| 🔴 | 无 OpenAPI/Swagger 文档 | 使用 `@hono/zod-openapi` |
| 🟡 | 无 API 版本管理策略 | 至少文档声明稳定性 |

---

## 六、修复优先级路线图

### Phase 1 — 紧急修复（1-2 天）

**目标**: 消除安全隐患和数据正确性风险

1. `npm audit fix` 修复 protobufjs + hono 漏洞 (30min)
2. Database constructor + writeFileSettings 设置 600 权限 (30min)
3. OpenAI embedding 路径增加 L2 归一化 (30min)
4. 7 个端点添加 parseInt NaN 检查 (1h)
5. initVectorDeps 区分预期错误和编程错误 (1h)
6. backfillCodexOriginator 改用 async I/O (2h)
7. 添加全局错误处理中间件 `app.onError` (30min)

### Phase 2 — 短期改进（1 周）

**目标**: 补齐核心功能缺失和性能瓶颈

1. 新增 `delete_insight` MCP 工具 (1-2h)
2. 新增 `hide_session` MCP 工具 (2-3h)
3. backfillSuggestedParents N+1 查询优化 (2-3h)
4. 添加 `sessions.project` 索引 (30min)
5. web.ts CLI 添加 shutdown handler (1h)
6. 添加请求体大小限制中间件 (30min)
7. 统一错误响应格式 (2-3h)
8. 添加 `GET /api/insights` 端点 (2h)
9. 噪声过滤配置迁移逻辑修复 (1-2h)

### Phase 3 — 中期优化（2-4 周）

**目标**: 提升代码质量和可维护性

1. web.ts 按功能域拆分路由 (4-8h)
2. 添加 OpenAPI 文档 (4-8h)
3. Watcher 添加去抖/并发限制 (2-3h)
4. chunker 策略优化（代码块完整性） (3-4h)
5. Layer 2 父子检测扩展来源 (2-4h)
6. 添加 Rate Limiting 到所有 POST 端点 (1-2h)
7. daemon.ts 集成测试 (3-4h)
8. 统一 URL 命名规范 (2-3h)
9. MetricsCollector 增量 rollup (2-3h)

### Phase 4 — 长期改进

**目标**: 架构优化和功能完善

1. Insight 过期/衰减机制 (3-5h)
2. lite 层拆分为 noise/silent (2-3h)
3. 分页响应格式统一 (2-3h)
4. 批量操作 API (3-4h)
5. API 版本管理策略 (文档)
6. 批量导出功能 (2-3h)

---

## 七、架构亮点（值得保持）

审计过程中发现以下设计亮点：

1. **Bootstrap 工厂模式** — `createMCPDeps()` / `createDaemonDeps()` 清晰分离依赖初始化
2. **Insight 降级设计** — text-only → embedding 双层存储 + daemon 回填，确保无 embedding provider 时可用
3. **Preamble 检测器** — 多级策略（标记+正则+结构化行比例）覆盖全面
4. **项目迁移管道** — dry_run → 执行 → undo → recover 补偿事务设计成熟
5. **SQLite-vec 模型感知** — dimension/model 变化自动重建向量表
6. **MCP 进程生命周期** — 4 层保护（stdin/parent PID/idle/signal）+ unref() 使用正确
7. **Swift IPC 架构** — 读操作直连 SQLite，写操作通过 IPC 单写者纪律
8. **测试质量** — 1276 个测试、真实 fixtures、无 mocking，覆盖所有 15 个 adapter

---

## 八、附录

### 分项报告索引

| 报告 | 文件 | 大小 |
|------|------|------|
| 功能设计审计 | `docs/reviews/2026-05-03-functional-design-audit.md` | 26KB |
| 代码实现审计 | `docs/reviews/2026-05-03-code-implementation-audit.md` | 24KB |
| 安全审计 | `docs/reviews/2026-05-03-security-audit.md` | 21KB |
| Web API 审计 | `docs/reviews/2026-05-03-web-api-audit.md` | 27KB |
| **汇总报告** | **`docs/reviews/2026-05-03-audit-summary.md`** | 本文 |

---

*报告由 4 位领域专家 Agent 并行审计生成，由 Team Leader 汇总。*
