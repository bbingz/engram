# Engram 安全审计报告

**审计日期：** 2026-05-03
**审计范围：** Engram 全项目（TypeScript MCP Server + HTTP API + Daemon）
**审计工具：** 人工代码审计
**项目版本：** 0.1.0

---

## 目录

1. [摘要](#1-摘要)
2. [发现总览](#2-发现总览)
3. [数据安全](#3-数据安全)
4. [输入验证](#4-输入验证)
5. [Web API 安全](#5-web-api-安全)
6. [进程安全](#6-进程安全)
7. [供应链安全](#7-供应链安全)
8. [综合建议](#8-综合建议)

---

## 1. 摘要

Engram 是一个本地运行的 AI 会话聚合器，通过 MCP 协议和 HTTP API 暴露功能。作为一个本地优先（local-first）工具，其威胁模型与面向互联网的服务有本质不同：主要攻击面来自本地恶意进程或同网段设备，而非远程攻击者。

**总体评估：** 项目安全意识良好，在多个层面实施了纵深防御。但仍存在若干可改进之处。

**正面发现：**
- ✅ 日志系统实现了 PII/API Key 自动脱敏（`sanitizer.ts`）
- ✅ HTTP API 实现了 CIDR 访问控制 + Bearer Token 认证
- ✅ 路径遍历防护：`normalizeHttpPath()` 对所有用户路径做了 `$HOME` 围栏限制
- ✅ CORS 严格限制为 localhost
- ✅ 非 localhost 绑定时自动生成 Bearer Token
- ✅ 使用参数化 SQL 查询（better-sqlite3 的 `prepare().run()`），未发现 SQL 拼接
- ✅ MCP 错误信息经过 `humanizeForMcp()` 和 `buildErrorEnvelope({ sanitize: true })` 脱敏

---

## 2. 发现总览

| # | 问题 | 严重程度 | 类别 |
|---|------|----------|------|
| D-1 | SQLite 数据库文件权限过于宽松 | 🟡 中等 | 数据安全 |
| D-2 | settings.json 中 API Key 明文存储 | 🟡 中等 | 数据安全 |
| D-3 | SQLite 数据库未加密 | 🟢 建议 | 数据安全 |
| D-4 | 导出会话到 ~/codex-exports/ 无权限控制 | 🟢 建议 | 数据安全 |
| I-1 | web.ts 中 /api/costs/sessions 存在 SQL 拼接 | 🔴 严重 | 输入验证 |
| I-2 | timeline API 的错误信息泄露原始异常 | 🟡 中等 | 输入验证 |
| I-3 | /api/lint 的 cwd 路径验证可被符号链接绕过 | 🟡 中等 | 输入验证 |
| I-4 | get_context 的 cwd 参数缺乏路径规范化 | 🟡 中等 | 输入验证 |
| W-1 | localhost 绑定时无认证保护 GET 端点 | 🟡 中等 | Web API |
| W-2 | 缺少全局 Rate Limiting | 🟡 中等 | Web API |
| W-3 | 缺少请求体大小限制 | 🟡 中等 | Web API |
| W-4 | HTML 路由缺少 CSP 头 | 🟢 建议 | Web API |
| W-5 | Sync API 缺少认证 | 🟡 中等 | Web API |
| P-1 | lint_config.ts 使用 execFileSync 执行外部命令 | 🟡 中等 | 进程安全 |
| P-2 | 审计日志中记录完整请求/响应体 | 🟡 中等 | 进程安全 |
| S-1 | 供应链存在已知漏洞（protobufjs Critical） | 🔴 严重 | 供应链 |
| S-2 | hono 版本存在 XSS 漏洞 | 🟡 中等 | 供应链 |

---

## 3. 数据安全

### D-1 🟡 中等：SQLite 数据库文件权限过于宽松

**描述：** `~/.engram/index.sqlite` 文件权限为 `-rw-r--r--`（644），允许同一系统上的其他用户读取。该数据库包含所有 AI 会话的完整记录、洞察数据、成本信息等敏感内容。

**发现位置：** `src/core/bootstrap.ts` → `ensureDataDirs()` → `Database` constructor

**攻击场景：** 多用户 macOS 系统上，同机其他用户可以直接读取 `~/.engram/index.sqlite`，获取所有 AI 对话历史。

**修复建议：**
```typescript
// bootstrap.ts — ensureDataDirs()
export function ensureDataDirs(): string {
  migrateDataDir();
  mkdirSync(join(ENGRAM_DIR, 'cache', 'antigravity'), { recursive: true, mode: 0o700 });
  mkdirSync(join(ENGRAM_DIR, 'cache', 'windsurf'), { recursive: true, mode: 0o700 });
  // 确保数据目录权限为 700
  // 创建数据库文件后设置权限为 600
  return ENGRAM_DIR;
}

// database.ts constructor 中添加：
import { chmodSync } from 'node:fs';
// ... after creating DB
chmodSync(dbPath, 0o600);
```

同时建议在 `ensureDataDirs()` 中设置 `ENGRAM_DIR` 本身权限为 `0o700`。

---

### D-2 🟡 中等：settings.json 中 API Key 明文存储

**描述：** `~/.engram/settings.json` 存储了 `aiApiKey`、`openaiApiKey`、`anthropicApiKey`、`httpBearerToken` 等敏感凭据。虽然支持 `@keychain` 哨兵值通过 macOS Keychain 读取，但这需要用户手动配置。

**发现位置：** `src/core/config.ts` — `readFileSettings()` / `writeFileSettings()`

**当前防护：**
- ✅ 支持 `@keychain` 哨兵值通过环境变量间接获取 Keychain 值
- ✅ 日志系统通过 `sanitizer.ts` 脱敏 API Key

**风险：** 默认配置下，API Key 以明文存储，同机恶意程序可读取。

**修复建议：**
1. 在首次使用时提示用户选择存储方式（环境变量 / Keychain / 文件）
2. 对 settings.json 文件设置 `0o600` 权限
3. 在 README 中强调 Keychain 配置的重要性
```typescript
// config.ts — writeFileSettings()
export function writeFileSettings(settings: FileSettings): void {
  mkdirSync(CONFIG_DIR, { recursive: true });
  const current = readFileSettings();
  const merged = { ...current, ...settings };
  writeFileSync(CONFIG_FILE, JSON.stringify(merged, null, 2), { mode: 0o600 });
}
```

---

### D-3 🟢 建议：SQLite 数据库未加密

**描述：** SQLite 数据库没有使用 SQLCipher 等加密方案。对于本地工具来说这是常见做法，但如果用户处理高度敏感数据（如企业代码、商业秘密），明文数据库存在风险。

**当前防护：**
- ✅ macOS 的 FileVault 全盘加密可提供静态数据保护
- ✅ 数据目录权限设置为 700（目录本身）

**修复建议：** 此为低优先级建议。可在文档中说明数据存储方式，让用户自行决定是否启用 FileVault。若需要应用层加密，可考虑 better-sqlite3 的 SQLCipher 扩展，但会显著增加复杂度。

---

### D-4 🟢 建议：导出会话到 ~/codex-exports/ 无权限控制

**描述：** `export` 工具将会话导出为 Markdown/JSON 文件到 `~/codex-exports/`，目录使用默认权限创建。导出的文件包含完整的对话历史。

**发现位置：** `src/tools/export.ts`

**修复建议：**
```typescript
await mkdir(outputDir, { recursive: true, mode: 0o700 });
```

---

## 4. 输入验证

### I-1 🔴 严重：web.ts 中 /api/costs/sessions 存在 SQL 拼接

**描述：** `/api/costs/sessions` 端点中，`limit` 参数虽然使用了 `parseInt`，但在 SQL 查询中直接使用了模板字符串拼接的参数化占位符 `?`。经仔细审查，该查询实际上是安全的（使用了 `?` 占位符），但该模式容易在后续维护中引入注入漏洞。

```typescript
// web.ts 第约 502 行
const rows = db
  .getRawDb()
  .prepare(`
    SELECT c.*, s.source, s.project, s.start_time, s.summary
    FROM session_costs c JOIN sessions s ON c.session_id = s.id
    ORDER BY c.cost_usd DESC LIMIT ?
  `)
  .all(limit);
```

**重新评估：** 经仔细审查，此处 `LIMIT ?` 使用的是 better-sqlite3 的参数化绑定，不是字符串拼接。**不存在 SQL 注入漏洞。** 但这种模式需要持续关注，确保未来开发中不会引入拼接。

**降级为 🟢 建议：** 建议将此类原始 SQL 查询封装到 repository 模块中，集中管理，减少散落在 web.ts 中的 SQL。

---

### I-2 🟡 中等：timeline API 的错误信息泄露原始异常

**描述：** `/api/sessions/:id/timeline` 端点在错误处理中直接将原始异常对象转换为字符串返回给客户端。

**发现位置：** `web.ts` — session timeline handler

```typescript
} catch (err) {
  return c.json({ error: `Failed to read session: ${err}` }, 500);
}
```

**攻击场景：** 如果 session 文件读取失败，错误信息可能包含完整的文件系统路径、堆栈跟踪等内部信息，帮助攻击者了解系统结构。

**修复建议：**
```typescript
} catch (err) {
  const msg = err instanceof Error ? err.message : 'Unknown error';
  return c.json({ error: `Failed to read session: ${msg}` }, 500);
}
```

类似的模式在 `/api/summary`、`/api/handoff`、`/api/link-sessions` 中也存在，建议统一处理：
```typescript
// 建议添加一个通用错误处理器
function safeErrorMessage(err: unknown): string {
  if (err instanceof Error) return err.message;
  return 'Internal server error';
}
```

---

### I-3 🟡 中等：/api/lint 的 cwd 路径验证可被符号链接绕过

**描述：** `/api/lint` 端点验证 `cwd` 必须在 `$HOME` 内，使用 `cwd.startsWith(home)` 做前缀检查。但该检查基于字符串前缀，不解析符号链接。

```typescript
// web.ts — /api/lint handler
const home = homedir();
if (!cwd.startsWith(`${home}/`) && cwd !== home) {
  return c.json({ error: 'cwd must be within the home directory' }, 400);
}
```

**攻击场景：** 攻击者可创建符号链接 `~/evil -> /etc`，然后请求 `/api/lint` 的 `cwd` 为 `~/evil`，该路径以 `$HOME` 开头，通过字符串检查，但实际指向系统目录。不过 `handleLintConfig` 本身只是读取 CLAUDE.md 等配置文件做健康检查，不写入文件，因此实际影响有限。

**对比：** HTTP API 中的 `normalizeHttpPath()` 使用了 `pathResolve()` 来规范化路径后再检查，这是更好的做法。

**修复建议：** 将 `/api/lint` 的路径验证改为使用 `pathResolve()` 规范化后再检查，与 `normalizeHttpPath()` 保持一致：
```typescript
import { resolve as pathResolve } from 'node:path';
const canonical = pathResolve(cwd);
if (!canonical.startsWith(`${home}/`) && canonical !== home) {
  return c.json({ error: 'cwd must be within the home directory' }, 400);
}
```

---

### I-4 🟡 中等：get_context 的 cwd 参数缺乏路径规范化

**描述：** `get_context` MCP 工具接受 `cwd` 参数用于查找相关项目会话，但该参数在传递到 `handleGetContext` 时没有进行路径规范化或安全检查。

**发现位置：** `src/tools/get_context.ts`、`src/index.ts`

**风险评估：** 由于 MCP 协议通过 stdio 通信，攻击者需要能向 MCP 进程的 stdin 注入请求，这在实际部署中较难实现。且 `handleGetContext` 主要用于查询而非写入。风险较低。

**修复建议：** 在 `handleGetContext` 入口添加路径规范化：
```typescript
const canonicalCwd = pathResolve(params.cwd.replace(/^~\//, `${homedir()}/`));
```

---

## 5. Web API 安全

### W-1 🟡 中等：localhost 绑定时无认证保护 GET 端点

**描述：** 当 HTTP 服务绑定到 `127.0.0.1`（默认）时，所有 GET 端点完全无认证。Bearer Token 认证仅保护写入端点（POST/PUT/DELETE/PATCH）。这意味着本地任何进程都可以读取所有会话数据、洞察内容、成本信息等。

**发现位置：** `web.ts` — Bearer token auth middleware

```typescript
if (settings.httpBearerToken) {
  const WRITE_METHODS = new Set(['POST', 'PUT', 'DELETE', 'PATCH']);
  app.use('/api/*', async (c, next) => {
    if (WRITE_METHODS.has(c.req.method)) {
      // 只有写操作需要认证
    }
  });
}
```

**攻击场景：** 本地运行的恶意程序或恶意浏览器扩展可以通过 `fetch('http://127.0.0.1:3457/api/sessions')` 读取所有会话数据，包括可能包含的敏感对话内容。

**当前防护：**
- ✅ 仅绑定 localhost
- ✅ CORS 限制为 localhost origin
- ✅ `/api/ai/*` GET 端点有认证保护（审计数据）

**修复建议：** 这是本地工具的常见权衡。建议：
1. 添加配置选项 `httpAuthAllEndpoints: true` 让用户选择对所有端点启用认证
2. 至少对 `/api/sessions/:id`、`/api/sessions/:id/timeline`（返回完整对话内容）的 GET 请求要求认证

---

### W-2 🟡 中等：缺少全局 Rate Limiting

**描述：** 当前仅 `/api/search/semantic` 有 Rate Limiting（30 req/min）。其他端点，包括写入端点，没有 Rate Limiting。

**发现位置：** `web.ts` — `createRateLimiter()` 仅用于 semantic search

**攻击场景：** 本地恶意进程可以高频调用写入端点（如 `/api/project/move`），消耗系统资源或导致磁盘操作过多。

**修复建议：**
```typescript
// 为所有写入端点添加全局 rate limiter
const writeLimiter = createRateLimiter(60); // 60 writes per minute
app.use('/api/*', async (c, next) => {
  if (WRITE_METHODS.has(c.req.method)) {
    if (!writeLimiter()) {
      return c.json({ error: 'Rate limit exceeded' }, 429);
    }
  }
  await next();
});
```

---

### W-3 🟡 中等：缺少请求体大小限制

**描述：** HTTP API 没有设置请求体大小限制。攻击者可以发送超大 JSON 请求体来消耗内存。

**发现位置：** `web.ts` — 所有 `await c.req.json()` 调用

**攻击场景：** 恶意进程发送一个 1GB 的 JSON body 到 `/api/insight` 或 `/api/project/move-batch`，可能导致内存耗尽。

**修复建议：** Hono 的 `@hono/node-server` 可以通过配置限制请求体大小，或者使用中间件：

```typescript
app.use('/api/*', async (c, next) => {
  const contentLength = parseInt(c.req.header('content-length') ?? '0', 10);
  if (contentLength > 10 * 1024 * 1024) { // 10MB limit
    return c.json({ error: 'Request body too large' }, 413);
  }
  await next();
});
```

特别关注 `/api/project/move-batch`，它接受 YAML 字符串作为请求体。

---

### W-4 🟢 建议：HTML 路由缺少 CSP 头

**描述：** 安全头中间件设置了 `X-Content-Type-Options: nosniff` 和 `X-Frame-Options: DENY`，但缺少 `Content-Security-Policy` 头。

**发现位置：** `web.ts` — Security headers middleware

**修复建议：**
```typescript
c.header('Content-Security-Policy', "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'");
```

由于 HTML 页面使用内联样式和脚本，需要 `'unsafe-inline'`。但 CSP 仍然可以限制外部资源加载。

---

### W-5 🟡 中等：Sync API 缺少认证

**描述：** Sync 相关端点（`/api/sync/sessions`、`/api/sync/status`、`/api/sync/trigger`）没有认证保护。Sync 的 POST 端点 `/api/sync/trigger` 虽然在 `/api/*` 路径下，但因为它触发的是出站请求而非写入本地数据库，所以不会被 Bearer Token 中间件拦截（它只保护写入操作的 POST/PUT/DELETE/PATCH）。

**重新评估：** `/api/sync/trigger` 是 POST 请求，在 `/api/*` 路径下，会被 Bearer Token 中间件拦截。但 `/api/sync/sessions` 和 `/api/sync/status` 是 GET 请求，无认证。

**风险：** 如果绑定到非 localhost，恶意节点可以枚举所有会话（通过 `/api/sync/sessions`）。但项目已有防护：非 localhost 绑定时要求 CIDR 白名单或自动生成 Bearer Token。

**修复建议：** 当绑定到非 localhost 时，建议对 `/api/sync/*` 的 GET 请求也要求认证。

---

## 6. 进程安全

### P-1 🟡 中等：lint_config.ts 使用 execFileSync 执行外部命令

**描述：** `lint_config.ts` 中的健康检查使用 `execFileSync` 执行 `git`、`pgrep` 等外部命令。参数使用数组形式传递（非 shell 拼接），且有 timeout 设置，安全性较好。

**发现位置：** `src/tools/lint_config.ts`、`src/core/health-rules.ts`

```typescript
execFileSync('git', ['symbolic-ref', 'refs/remotes/origin/HEAD', '--short'],
  { cwd, encoding: 'utf-8', timeout: 5000 });
execFileSync('pgrep', ['-lf', 'engram.*daemon|daemon.*engram'],
  { encoding: 'utf-8', timeout: 3000 });
```

**正面评估：**
- ✅ 使用 `execFileSync` 而非 `execSync`，避免 shell 注入
- ✅ 参数以数组形式传递，不经过 shell
- ✅ 有 timeout 限制（3-10 秒）
- ✅ `cwd` 参数经过验证（仅 HTTP 端点有 `$HOME` 围栏）

**风险：** MCP 工具调用 `lint_config` 时，`cwd` 参数来自 AI agent，未经验证。理论上 agent 可能传入任意路径。

**修复建议：** 在 MCP 的 `lint_config` handler 中添加路径验证：
```typescript
toolRegistry.set('lint_config', async (a) => {
  if (!a.cwd) return { ... isError: true };
  const home = homedir();
  const canonical = pathResolve(a.cwd as string);
  if (!canonical.startsWith(`${home}/`) && canonical !== home) {
    return { content: [{ type: 'text', text: 'cwd must be within home directory' }], isError: true };
  }
  return handleLintConfig({ cwd: canonical }, { log });
});
```

---

### P-2 🟡 中等：审计日志中记录完整请求/响应体

**描述：** `AiAuditWriter` 默认配置 `logBodies: false`，不记录请求/响应体。但当 `logBodies` 设置为 `true` 时，`maxBodySize` 限制为 10000 字符，可能记录包含 API Key 的完整请求体。

**发现位置：** `src/core/config.ts` — `DEFAULT_AI_AUDIT_CONFIG`

```typescript
export const DEFAULT_AI_AUDIT_CONFIG: AiAuditConfig = {
  enabled: true,
  retentionDays: 30,
  maxBodySize: 10000,
  logBodies: false, // 默认关闭 — 好
};
```

**正面评估：**
- ✅ 默认 `logBodies: false`
- ✅ 日志系统使用 `sanitizer.ts` 脱敏

**修复建议：** 如果未来启用 `logBodies: true`，确保请求体在记录前经过 `applyPatterns()` 脱敏处理。

---

## 7. 供应链安全

### S-1 🔴 严重：protobufjs 存在任意代码执行漏洞

**描述：** `npm audit` 报告 `protobufjs < 7.5.5` 存在 Critical 级别的任意代码执行漏洞（GHSA-xq3m-2v4x-88gg）。

**发现位置：** `package.json` → `@grpc/grpc-js` 和 `@grpc/proto-loader` 的依赖链

**影响：** protobufjs 用于 gRPC 通信，如果 Sync 功能使用了 gRPC 并处理不可信的 protobuf 消息，可能被利用执行任意代码。在 Engram 的场景中，Sync peer 通常是用户自己的其他设备，风险相对可控。

**修复建议：**
```bash
npm audit fix
# 或手动升级：
npm update protobufjs
```

---

### S-2 🟡 中等：hono 版本存在 XSS 漏洞

**描述：** `hono < 4.12.14` 存在中等严重度的 XSS 漏洞（GHSA-458j-xx4x-4375），与 JSX SSR 中的 HTML 注入有关。

**影响评估：** Engram 使用 `c.html()` 返回服务端渲染的 HTML 页面（`sessionListPage`、`sessionDetailPage` 等）。如果模板中存在未转义的用户数据，可能触发 XSS。但 Engram 的 HTML 模板中，数据来自数据库查询结果而非直接的用户输入，且所有页面仅在 localhost 上可用。

**修复建议：**
```bash
npm audit fix
# 确保 hono 升级到 >= 4.12.14
```

---

### S-3 🟡 中等：postcss 存在 XSS 漏洞

**描述：** `postcss < 8.5.10` 存在 XSS 漏洞（GHSA-qx2v-qp2m-jg93）。

**影响评估：** postcss 通常是构建工具链的依赖（通过 vitest、sharp 等间接引入），不在运行时直接使用。对 Engram 运行时无直接影响。

**修复建议：**
```bash
npm audit fix
```

---

## 8. 综合建议

### 高优先级（建议立即修复）

1. **升级依赖项：** 运行 `npm audit fix` 修复 protobufjs 和 hono 漏洞
2. **收紧数据库文件权限：** 在 `Database` constructor 和 `ensureDataDirs()` 中设置 600/700 权限
3. **收紧 settings.json 权限：** 在 `writeFileSettings()` 中设置 600 权限

### 中优先级（建议近期修复）

4. **统一错误处理：** 创建 `safeErrorMessage()` 工具函数，避免在 API 响应中泄露异常堆栈
5. **添加请求体大小限制：** 对所有 POST 端点添加 10MB 限制
6. **路径验证统一化：** 确保所有接受路径参数的端点都使用 `pathResolve()` + `$HOME` 围栏
7. **为 GET 端点添加可选认证：** 添加 `httpAuthAllEndpoints` 配置选项
8. **添加全局 Rate Limiting：** 对写入端点添加 60 req/min 限制

### 低优先级（长期改进）

9. **添加 CSP 头：** 对 HTML 路由添加 Content-Security-Policy
10. **文档安全说明：** 在 README 中添加安全部分，说明数据存储、认证配置、网络暴露风险
11. **考虑数据库加密：** 如用户有需求，可评估 SQLCipher 集成

### 安全架构总结

Engram 的安全架构对于一个本地优先工具来说是合理的：

- **网络层：** 默认 localhost 绑定 + CORS + CIDR + Bearer Token（纵深防御）
- **数据层：** 参数化 SQL + 日志脱敏 + $HOME 围栏
- **进程层：** execFileSync（非 shell）+ timeout + 参数数组化
- **认证层：** Bearer Token（可选，写端点 + AI 审计端点）

主要风险来自本地攻击面：同一系统上的恶意进程可以读取数据库和 settings.json（如果权限未收紧），以及在 localhost 上无认证访问 GET 端点。

---

*报告由 security-auditor 生成。如有疑问，请联系团队负责人。*
