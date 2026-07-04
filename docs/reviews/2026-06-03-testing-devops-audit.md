# Engram 项目测试工程与 DevOps 审查报告

**审查日期**: 2026-06-03
**审查人**: 测试工程与 DevOps 专家
**项目**: Engram (TypeScript + Swift 混合项目)

---

## 执行摘要

| 维度 | 评分 | 说明 |
|------|------|------|
| 测试覆盖率与质量 | 6/10 | 核心模块覆盖良好，但关键入口文件被人为排除出覆盖率；CLI 覆盖极差 |
| 测试设计 | 7/10 | Fixture 管理成熟，测试命名清晰，但存在轻微共享状态风险和潜在 flaky 阈值 |
| CI/CD | 6/10 | 工作流完整且分门别类，但缺少安全扫描、npm audit、覆盖率上传 |
| 构建系统 | 8/10 | XcodeGen + TypeScript 构建链路清晰，产物验证脚本完善 |
| 工程实践 | 6/10 | Husky/Biome/Knip 齐全，但 lint 规则过松、无 pre-push 测试、缺少 AGENTS.md |
| 文档与可维护性 | 7/10 | CHANGELOG 维护积极，README 详尽 |
| 性能测试 | 4/10 | 有基准捕获脚本，但 CI 中零运行 |
| **总体健康度** | **6.5/10** | 基础扎实，但存在覆盖率失真、安全缺口和 runner 资源浪费等可修复问题 |

---

## 1. 测试覆盖率与质量

### P1 — Coverage 配置人为排除核心入口文件，导致报告失真
- **文件**: `vitest.config.ts` (第 12–18 行)
- **问题**: `coverage.exclude` 明确排除了 `src/daemon.ts` (530 行)、`src/web.ts` (1430 行)、`src/cli/index.ts`、`src/cli/resume.ts` 和 `src/types/**`。`src/web.ts` 实际有测试覆盖（`tests/web/` 下 12 个测试文件），但因其被排除，它的低覆盖率（65.6% 行覆盖）不影响 threshold 达标。`daemon.ts` 作为守护进程入口几乎没有直接单元测试，却被隐藏。
- **修复建议**: 将 `src/daemon.ts` 和 `src/web.ts` 移出 `exclude`，仅排除纯类型声明目录。若 CLI 入口确实难以测试，可单独排除但需记录技术债务。
- **影响**: 团队可能误以为总体覆盖率达 79.2%，但实际若计入被排除文件，真实行覆盖率可能降至 72–75% 以下，低于设定的 75% threshold。

### P1 — CLI 模块覆盖率仅 18.6%，关键命令零测试
- **文件**: `src/cli/project.ts` (494 行)、`src/cli/resume.ts` (153 行)
- **问题**: `tests/cli/` 仅包含 `health.test.ts`、`logs.test.ts`、`traces.test.ts`，`project.ts`（项目迁移核心命令）和 `resume.ts` 完全没有单元测试。`src/cli/` 整体行覆盖 18.6%，分支覆盖 81.1%（高分支覆盖是因为少量被测代码的分支简单）。
- **修复建议**: 为 `project.ts` 的迁移逻辑和 `resume.ts` 添加最小 CLI 集成测试；或者将核心逻辑抽离到 `src/core/` 或 `src/tools/` 中以便复用现有测试基础设施。
- **影响**: 项目迁移是产品的核心卖点之一，该命令无测试意味着 regressions 无法被 CI 捕获。

### P1 — Web 层分支覆盖率仅 66.8%，低于 threshold
- **文件**: `src/web/` (78.5% 行覆盖, 66.8% 分支覆盖)
- **问题**: `web.ts` 被排除出 coverage 后，`src/web/` 的分支覆盖 66.8% 仍低于 threshold（70%），但由于 `web.ts` 不计入，整体分支覆盖才勉强达标（76.6%）。HTTP 路由中的错误处理分支、鉴权失败分支、参数校验边界缺乏覆盖。
- **修复建议**: 为 `web/routes/` 中的错误路径（400/401/403/500）补充测试；将 `web.ts` 重新纳入 coverage 并提升其分支覆盖。
- **影响**: API 边界是外部攻击面，低分支覆盖意味着错误处理路径未经测试验证。

### P2 — Swift 侧零覆盖率收集
- **文件**: `.github/workflows/test.yml` (第 94–114 行)
- **问题**: Swift 单元测试（EngramTests 290 个、EngramCoreTests 341 个、EngramMCPTests 58 个、EngramServiceCoreTests 108 个）在 CI 中运行，但 `xcodebuild test` 未启用 `-enableCodeCoverage YES`，也无可视化报告上传。
- **修复建议**: 在 `xcodebuild test` 中添加 `-enableCodeCoverage YES`，并使用 `xcresultparser` 或 `slather` 生成覆盖率报告；上传至 Codecov 或作为 artifact 保留。
- **影响**: 无法评估 Swift 侧测试质量，无法识别未覆盖的关键路径（如 VectorRebuildPolicy、MigrationRunner）。

### P2 — Adapter 分支覆盖率 70.9%，接近 threshold
- **文件**: `src/adapters/` (72.3% 行覆盖, 70.9% 分支覆盖)
- **问题**: 15 个适配器的 parity 测试覆盖了解析路径，但边缘情况（ malformed JSON、空文件、权限错误）的分支覆盖不足。`tests/adapters/edge-cases.test.ts` 只覆盖了 Codex 和 Copilot，其他 13 个适配器没有统一的边缘情况测试。
- **修复建议**: 将 `edge-cases.test.ts` 参数化，循环所有适配器进行空文件、损坏 JSON、权限拒绝的统一测试。
- **影响**: 新增适配器或修改解析逻辑时， malformed 输入可能导致未处理的异常。

---

## 2. 测试设计

### P2 — `mock-data.test.ts` 使用 `beforeAll` + `afterEach` 组合，存在隐式顺序依赖
- **文件**: `tests/core/mock-data.test.ts` (第 8–14 行)
- **问题**: `db` 在 `beforeAll` 中创建并在所有测试中共享；`afterEach` 只调用 `clearMockData(db)`。如果某个测试意外调用了 `db.close()` 或修改了 schema，后续测试会失败。Vitest 默认按文件串行执行，但文件内测试理论上可并行（`sequence.concurrent`）。
- **修复建议**: 将 `beforeAll` 改为 `beforeEach`，每个测试使用独立的 `:memory:` 数据库，成本极低（SQLite 内存实例）。
- **影响**: 测试间隐式耦合，增加调试难度，长期可能引入 flaky test。

### P2 — `live-sessions.test.ts` 使用全局临时目录，未隔离测试间状态
- **文件**: `tests/core/live-sessions.test.ts` (第 13–36 行)
- **问题**: `TEST_DIR` 在模块级通过 `Date.now()` 定义，所有测试共享同一目录。虽然 `LiveSessionMonitor` 实例在每次测试新建，但文件系统状态是共享的。
- **修复建议**: 使用 `beforeEach` 生成唯一子目录，或在 `afterEach` 中清理每个测试创建的具体文件。
- **影响**: 文件系统残留可能导致跨测试污染，尤其在并行执行时。

### P2 — Logger 性能测试阈值可能在 CI runner 上 flaky
- **文件**: `tests/core/logger.test.ts` (第 436 行)
- **问题**: `expect(avgUs).toBeLessThan(process.env.CI ? 500 : 250)` 使用绝对时间阈值。GitHub Actions 的 `ubuntu-latest` runner 是共享资源，CPU 抖动可能导致偶发超时失败。
- **修复建议**: 改为相对基准比较（如与上一次 baseline 的 ±20% 比较），或增加阈值到 CI 下 1000μs；或者将性能测试移至独立 CI job 并标记为 `continue-on-error`。
- **影响**: 偶发的 CI 失败会降低团队对测试结果的信任度。

### P2 — `ai-client.test.ts` 全局 `fetch` mock 未在所有路径恢复
- **文件**: `tests/core/ai-client.test.ts`
- **问题**: 多处直接赋值 `globalThis.fetch = vi.fn()`，但仅在某些测试末尾恢复为 `originalFetch`。Vitest 的 isolate 机制在进程级隔离，可能缓解问题，但如果在同一 worker 内串行执行且某个测试抛异常提前退出，`fetch` 可能保持 mock 状态。
- **修复建议**: 统一使用 `vi.stubGlobal('fetch', mock)` 配合 `vi.unstubAllGlobals()` 在 `afterEach` 中恢复。
- **影响**: 全局状态泄漏可能导致难以复现的测试失败。

### P3 — `route-modules.test.ts` 为浅层 smoke test，无实际行为验证
- **文件**: `tests/web/route-modules.test.ts`
- **问题**: 仅验证 `registerXxxRoutes` 是函数，不测试路由注册是否成功、路径是否正确、中间件是否生效。
- **修复建议**: 至少验证每个路由模块导出的函数在传入 mock app 后能调用 `app.get`/`app.post` 等；或合并到 `server.test.ts` 做集成验证。
- **影响**: 路由模块重命名或导出方式变更时，此测试无法捕获实际 regressions。

---

## 3. CI/CD

### P1 — CI 中完全缺少依赖安全扫描
- **文件**: `.github/workflows/test.yml`, `package.json`
- **问题**: 无任何 `npm audit`、`pnpm audit`、Snyk、Trivy 或 Dependabot 配置。项目依赖包括 `better-sqlite3`、`sharp`、`@grpc/grpc-js` 等原生/C++ 模块，这些是高危漏洞常见点。
- **修复建议**:
  1. 在 `test.yml` 的 `lint` job 或新增 `security` job 中运行 `npm audit --audit-level=moderate`。
  2. 启用 Dependabot（`.github/dependabot.yml`）每周扫描 npm 和 SPM 依赖。
  3. 对 Swift SPM 依赖，考虑使用 `swift-package-scan`。
- **影响**: 无法及时发现供应链攻击或已知 CVE，发布版本可能携带漏洞。

### P1 — Fixture-check job 浪费 macOS runner 资源
- **文件**: `.github/workflows/test.yml` (第 116–135 行)
- **问题**: `fixture-check` job 使用 `runs-on: macos-15`，但它只运行 `npm run build`、`npm run check:adapter-parity-fixtures` 和 `npm exec tsx scripts/check-fixture-schema.ts`——纯 Node 脚本，无需 macOS 或 Xcode。
- **修复建议**: 将 `fixture-check` 改为 `runs-on: ubuntu-latest`，仅保留需要 `xcodebuild` 的 job 在 macOS 上。
- **影响**: macOS runner 成本是 Ubuntu 的 10 倍，每个 PR 和 push 都浪费约 2–3 分钟宝贵的 macOS 并发额度。

### P2 — Biome `noExplicitAny` 为 warn，且 CI 无 `--error-on-warnings`
- **文件**: `biome.json` (第 21 行), `.github/workflows/test.yml` (第 24 行)
- **问题**: `suspicious.noExplicitAny` 设为 `warn`，`npm run lint`（即 `biome check .`）在 CI 中不会因为 `warn` 而失败。这意味着新增 `any` 类型不会被 CI 拦截。
- **修复建议**: 要么将 `noExplicitAny` 改为 `"error"`，要么在 CI 中运行 `biome check . --error-on-warnings`。
- **影响**: 类型安全性随时间退化，TypeScript 的严格模式价值被削弱。

### P2 — 无覆盖率上传与趋势追踪
- **文件**: `.github/workflows/test.yml` (第 52–56 行)
- **问题**: Coverage 报告作为 artifact 上传（`actions/upload-artifact@v4`），但没有解析、评论或趋势服务（Codecov、Coveralls、PR 评论）。团队无法直观看到 PR 对覆盖率的影响。
- **修复建议**: 集成 `codecov/codecov-action@v4` 或 `romeovs/lcov-reporter-action`，在 PR 中评论覆盖率变化。
- **影响**: 代码审查时无法快速判断新增代码是否被测试覆盖。

### P2 — UI 测试无重试机制，截图比较可能 flaky
- **文件**: `.github/workflows/test.yml` (第 137–209 行)
- **问题**: `ui-test-smoke` 在 PR 上运行 XCUITest 和 screenshot 比较，但 `xcodebuild test` 没有 `-testRetryOnFailure` 或 `-testRepetitionPolicy`；截图比较的 AI triage 依赖 `DASHSCOPE_API_KEY`，如果 API 限流或网络抖动，会导致 PR 被阻塞。
- **修复建议**:
  1. 为 XCUITest 添加 `-testRetryOnFailure 3`（Xcode 16 支持）。
  2. 将 screenshot 比较的 `if: failure()` artifact upload 改为 `if: always()`，并允许 AI triage 服务不可用时降级为仅 pixel/SSIM 比较而非失败。
- **影响**: 外部服务依赖导致 CI 非确定性失败，阻塞合并。

### P2 — Release workflow 未验证 Apple 签名合规性
- **文件**: `.github/workflows/release.yml`
- **问题**: Release gate 使用 ad-hoc 签名（`CODE_SIGN_IDENTITY="-"`），因此 `release-verify.sh` 跳过了 Developer ID 和 Notarization 检查。虽然文档说明了原因，但 CI 无法在生产签名流程变更后提供回归保护。
- **修复建议**: 在 release workflow 中增加一个可选的 `dry-run-notarization` job，使用自签证书（即使无法 notarize）验证 `codesign -dvvv` 中的 Hardened Runtime 和 Secure Timestamp 标志是否就位。
- **影响**: 发布流程中的签名配置 regressions 只能在手动打包时发现。

---

## 4. 构建系统

### P2 — `project.yml` 中硬编码 Apple Team ID
- **文件**: `macos/project.yml` (第 207 行)
- **问题**: `DEVELOPMENT_TEAM: J25GS8J4XM` 硬编码在仓库中。对于开源贡献者，这会导致本地构建失败或签名错误；对于 CI，虽然通过 `CODE_SIGN_IDENTITY="-"` 绕过，但 XcodeGen 生成的项目仍包含该 team。
- **修复建议**: 将 `DEVELOPMENT_TEAM` 改为从环境变量读取（如 `${ENGRAM_DEVELOPMENT_TEAM:J25GS8J4XM}`），并在 `.xcodegen.yml` 或文档中说明；CI 中保持空值即可。
- **影响**: 外部贡献者无法直接本地构建 macOS App；Team ID 泄露虽非高危，但非最佳实践。

### P2 — TypeScript 构建未在 Swift CI job 前验证
- **文件**: `.github/workflows/test.yml`
- **问题**: `swift-unit` job 直接运行 `npm ci`、`npm run build`、`npm run generate:fixtures`，但如果 `tsc` 编译失败，错误信息会被淹没在 xcodebuild 日志中。`typescript` job 和 `swift-unit` job 是并行的，没有 `needs` 依赖。
- **修复建议**: 让 `swift-unit` job `needs: typescript`，或在 `swift-unit` 中显式检查 `npm run build` 的退出码后再继续。
- **影响**: Swift CI 失败时，开发者需要排查是 TS 构建问题还是 Swift 问题，增加调试时间。

### P3 — Vitest coverage 阈值设置偏低
- **文件**: `vitest.config.ts` (第 19–23 行)
- **问题**: Threshold 设置为 lines 75、branches 70、functions 80。对于核心业务逻辑，这个标准偏低；且由于 `exclude` 的操纵，实际达标并不真实。
- **修复建议**: 将 threshold 提升至 lines 80、branches 75、functions 85；同时修复 `exclude` 后再评估是否可达标。
- **影响**: 阈值过低无法阻止覆盖率逐步侵蚀。

---

## 5. 工程实践

### P2 — 缺少 `AGENTS.md`
- **文件**: 项目根目录
- **问题**: 项目说明中明确提到 `AGENTS.md` 是编码代理的指令来源，但根目录不存在该文件。只有 `.cursor/rules/` 和 `.claude/settings.json` 等 IDE 配置。
- **修复建议**: 创建 `AGENTS.md`，包含构建步骤、测试运行命令、Biome 规则说明、fixture 生成流程、XcodeGen 使用方式等。
- **影响**: AI 编码助手缺乏统一的上下文来源，可能重复提出已解决的问题或采用不一致的代码风格。

### P2 — pre-push hook 未运行测试
- **文件**: `.husky/pre-push`
- **问题**: `pre-push` 仅包含 `git lfs pre-push`，没有运行 `npm test` 或 `npm run lint`。这意味着开发者可能在本地测试未通过的情况下直接推送。
- **修复建议**: 在 `pre-push` 中增加 `npm run typecheck:test` 和 `npm run test` 的快速子集（如 `vitest run --reporter=dot tests/core/db.test.ts` 或一个 smoke 测试集），或至少运行 `npm run lint`。
- **影响**: 低质量的 commit 被推送到 remote，增加 CI 负担和 review 噪音。

### P2 — lint-staged 未覆盖配置文件
- **文件**: `package.json` (第 62–66 行)
- **问题**: `lint-staged` 仅匹配 `*.{ts,tsx,js,jsx}`。`*.json`、`*.yml`、`*.yaml`、`.md` 文件不在范围内，但 `biome.json` 支持 JSON/YAML 格式化。
- **修复建议**: 扩展 lint-staged 为 `"*.{ts,tsx,js,jsx,json,yml,yaml}"`，并视情况加入 `"*.md"`。
- **影响**: 配置文件格式不一致，review 中出现无意义的格式化变更。

### P2 — 多项依赖严重过时
- **文件**: `package.json`
- **问题**:
  - `@modelcontextprotocol/sdk`: 1.10.2 → 1.29.0 (重大版本差异，可能包含协议不兼容变更)
  - `openai`: 6.25.0 → 6.41.0
  - `typescript`: 5.8.2 (package.json 声明) → 实际 5.9.3 → latest 6.0.3
  - `vitest`: 3.0.7 (声明) → 实际 3.2.4 → latest 4.1.8
- **修复建议**: 每月执行一次 `npm update` 并跑完全部测试；对 MCP SDK 等协议敏感依赖，升级前阅读 changelog。
- **影响**: 错过 bugfix 和安全补丁；升级间隔越大，累积的破坏性变更越多。

### P3 — `noNonNullAssertion` 被关闭
- **文件**: `biome.json` (第 26 行)
- **问题**: `style.noNonNullAssertion` 设为 `off`，允许 `value!.property` 这种不安全的非空断言在代码库中自由使用。
- **修复建议**: 设为 `"warn"` 或 `"error"`，逐步清理现有使用点（大部分可用可选链或提前检查替代）。
- **影响**: 运行时 `undefined` 访问错误在编译期被隐藏。

---

## 6. 文档与可维护性

### P3 — README 中 Swift 测试命令可能过时
- **文件**: `README.md` (第 75–76 行)
- **问题**: 文档中的示例命令使用 `-only-testing:EngramTests/MessageParserTests`，但 `MessageParserTests` 在 `EngramTests` 中是否存在未经验证；且未提及 `EngramCoreTests`、`EngramMCPTests` 等更重要的目标。
- **修复建议**: 将 README 中的 Swift 测试示例更新为当前 scheme 和 target 名称，并指向 `macos/README.md`（如果存在）或统一文档。
- **影响**: 新贡献者复制命令后遇到 "Test not found" 错误。

### P3 — CHANGELOG 格式规范但缺少分类标签
- **文件**: `CHANGELOG.md`
- **问题**: 虽然格式遵循 Keep a Changelog，但条目未按 `Security`、`Deprecated`、`Removed` 分类，难以快速定位破坏性变更。
- **修复建议**: 在 `[Unreleased]` 下增加子标题（`### Added`、`### Changed`、`### Fixed`、`### Security`）。
- **影响**: 版本升级时无法快速评估风险。

---

## 7. 性能测试

### P1 — 性能基准脚本在 CI 中零运行
- **文件**: `scripts/perf/capture-node-baseline.ts` (533 行), `.github/workflows/test.yml`
- **问题**: 项目包含完整的 Node 性能基准捕获脚本（cold launch、DB open、indexing、search P50/P95、get_context P50/P95），但没有任何 CI job 调用它。`measure-swift-single-stack-baseline.sh` 同样未被 CI 调用。
- **修复建议**:
  1. 新增 `performance` CI job，在 `main` 分支的 nightly schedule 或每个 PR 中运行 `tsx scripts/perf/capture-node-baseline.ts --compare-only`。
  2. 将 baseline JSON 提交到 `scripts/perf/baselines/` 并使用 `git diff --exit-code` 检测回归。
  3. 对 logger 微基准测试，考虑提取到独立 `perf/` 目录并标记 `skip`。
- **影响**: 性能 regressions（如 transcript paging 前的全量加载）只能在用户反馈或代码审查中偶然发现，无法系统性地拦截。

### P2 — Logger 微基准测试缺乏稳定性控制
- **文件**: `tests/core/logger.test.ts` (第 429–437 行)
- **问题**: 测试在 1000 次迭代后测量平均耗时，但没有 warm-up、没有丢弃异常值、没有多次采样取中位数。CI runner 的 CPU throttling 会导致结果大幅波动。
- **修复建议**: 使用 `benchmark.js` 或 Vitest 的 `bench` API（Vitest 4+ 原生支持 `describe.bench`），或至少进行 3 轮 warm-up + 5 轮测量取中位数。
- **影响**: 该测试成为 CI 中最可能的 flaky 来源。

---

## 优先级改进列表

### 立即执行（本周）
1. **修复 coverage exclude**：将 `src/web.ts` 和 `src/daemon.ts` 从 `vitest.config.ts` 的 `exclude` 中移除，补充 daemon 启动逻辑的单元测试。
2. **将 fixture-check 移至 ubuntu-latest**：节省 macOS runner 资源。
3. **在 CI 中启用 npm audit**：新增 `security` job，运行 `npm audit --audit-level=moderate`。
4. **统一全局 mock 恢复**：将 `ai-client.test.ts` 中的 `globalThis.fetch =` 改为 `vi.stubGlobal` + `vi.unstubAllGlobals()`。

### 短期（本月）
5. **补充 CLI 测试**：为 `src/cli/project.ts` 和 `src/cli/resume.ts` 添加最小测试集，或提取核心逻辑到可测试模块。
6. **提升 biome 严格性**：将 `noExplicitAny` 改为 `"error"`（或在 CI 中加 `--error-on-warnings`）；将 `noNonNullAssertion` 改为 `"warn"`。
7. **创建 AGENTS.md**：汇总构建、测试、fixture 生成、XcodeGen 流程。
8. **启用 Swift 覆盖率**：在 `xcodebuild test` 中加 `-enableCodeCoverage YES`，并上传报告。
9. **配置 Dependabot**：创建 `.github/dependabot.yml` 扫描 npm 和 SPM。

### 中期（下季度）
10. **集成性能回归 CI**： nightly 运行 `capture-node-baseline.ts`，与历史 baseline 比较。
11. **增加覆盖率上传**：接入 Codecov，在 PR 中评论覆盖率变化。
12. **XCUITest 重试与稳定性**：配置 `-testRetryOnFailure`，降低截图比较的硬性阻塞。
13. **清理测试间共享状态**：将 `mock-data.test.ts` 和 `live-sessions.test.ts` 的 `beforeAll` 改为 `beforeEach`。
14. **依赖升级计划**：分批次升级 `@modelcontextprotocol/sdk`、`vitest`、`typescript` 等核心依赖，验证协议兼容性。

---

## 附录：数据快照

| 指标 | 数值 |
|------|------|
| TS 测试文件 | 123 |
| TS 测试用例 | 1,439 |
| TS 测试耗时 | ~23s 总时间 / ~59s tests 时间 |
| TS 行覆盖率 | 79.2% (16,118 / 20,362) — **含 exclude 操纵** |
| TS 分支覆盖率 | 76.6% (3,689 / 4,817) |
| TS 函数覆盖率 | 86.5% (779 / 901) |
| Swift 测试文件 | 120 (不含 build) |
| Swift 测试方法 | ~861 |
| Swift 覆盖率 | **未收集** |
| CI jobs (test.yml) | 6 (lint, dead-code, typescript, swift-unit, fixture-check, ui-test) |
| 安全扫描 | 无 |
| 性能回归 CI | 无 |
| Coverage 上传 | 仅 artifact，无趋势服务 |
