# 三方评审短板补齐 TODO

**评审方**: Claude (Opus 4.6) / Gemini / Codex
**评审日期**: 2026-04-13
**分支**: `feat/local-semantic-search`
**综合评分**: 7.9/10 (Claude 7.95, Gemini 8.0, Codex 7.7)

---

## P0 — db.ts 拆分 (三方共识, 可维护性 +1.5)

- [ ] 从 db.ts (1845行) 拆出 `session-repo.ts` (session CRUD + list)
- [ ] 拆出 `fts-repo.ts` (FTS5 索引 + 搜索)
- [ ] 拆出 `migration.ts` (schema migration + idempotent DDL)
- [ ] 拆出 `metrics-repo.ts` (metrics + stats queries)
- [ ] 拆出 `index-job-repo.ts` (index job queue CRUD)
- [ ] db.ts 保留 Database class 作 facade, 委托给各 repo
- [ ] 确保 690 tests 全部通过, lint 0 issues

## P1 — 测试覆盖率提升到 75%+ (三方共识, 测试 +1)

- [ ] search.ts branch coverage 32% → 70%+ (补 semantic/hybrid/keyword 各路径)
- [ ] daemon.ts 0% → 基础冒烟测试
- [ ] index.ts 0% → MCP tool routing 测试
- [ ] save_insight.ts 扩展边界 case (重复 insight, 空 embedding, 超长文本)
- [ ] chunker.ts 扩展边界 case (空消息, 单消息超长, CJK 分块)
- [ ] 配置 vitest coverage threshold gate (75% lines, 70% branches)
- [ ] CI 中 coverage 低于阈值时 fail

## P2 — 清理 knip findings + 开启 noExplicitAny (三方共识, 代码质量 +0.5)

- [ ] 清理 ~20 个未使用 exported types (或 knip ignore 标记)
- [ ] 清理 4 个未使用文件 (Viking 残留确认)
- [ ] 检查 2 个未使用依赖 (js-yaml? @types/js-yaml?)
- [ ] biome.json: 开启 `noExplicitAny: warn` (先 warn, 后 error)
- [ ] 逐步修复 any 类型 → 具体类型
- [ ] CI knip job 配置为 fail on findings (非仅 report)

## P3 — 文档修复 + 补齐 (Codex/Gemini 扣分, 文档 +1)

- [ ] README.md: 修正 "278 tests" → "690 tests" (Codex 发现)
- [ ] 确认 SECURITY.md / PRIVACY.md 存在性 (Gemini 说被删了, 需核实)
- [ ] 补 MCP tool API reference (19 tools 的 usage examples)
- [ ] 补 CONTRIBUTING.md (新开发者 onboarding)
- [ ] 清理根目录 brainstorm-rag-web-sync.md (Gemini 发现, 应移入 docs/ 或删除)

## P4 — Semantic search 退化提示 (Claude 扣分, 产品完整度 +0.5)

- [ ] Ollama 不可用时, search 结果明确标注 "FTS-only mode"
- [ ] get_context 返回值中加 warning 字段说明 embedding 不可用
- [ ] save_insight 无法生成 embedding 时, 仍保存文本 + 返回 warning
- [ ] MCP ServerInfo.instructions 中说明 embedding provider 状态

## 额外发现

- [ ] 修复 hygiene.test.ts flaky test (Gemini 发现, timestamp race condition)
- [ ] index.ts 462 行 monolithic tool routing → 考虑 tool registry pattern
- [ ] web.ts 过大 → 考虑拆分 route modules
