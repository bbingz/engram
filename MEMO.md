# Engram Memo

## Changelog Memo

### 2026-07-05

- [新增] Fable/Claude 用 38-agent opus+sonnet workflow 完成砍功能审计（4 区域清单 → 4 视角提案 → 去重 → 每候选对抗验证 → opus 终审），与 Codex 同日的“隐藏/降级默认入口”轮合并为 Top 10 执行清单，落盘在 `docs/followups.md` § "feature-cut execution plan (2026-07-05)"；Codex 按清单开工，Claude 合并前复审。Codex 的 live_sessions 隐藏提案被验证否决。
- [修复] Fable/Claude 找到菜单栏弹窗“过长 / 低信号”的最终根因：不是首开查询慢，而是 `PopoverView` 的 Live 区域无上限渲染 `liveSessions`，service 又把 `/subagents/workflows/` churn 和 24h `recent` 会话混进来，导致最多 100 张 Live card 把弹窗撑到屏幕高度。
- [变更] 最终修复组合：`PopoverView` 固定 400x420 最小盒并用 `Spacer` 稳住 footer；Live 区域只显示 active/idle、最多 5 条，溢出用 `popover_liveOverflow`；`EngramServiceReadProvider.considerLiveSessionCandidate` 排除路径组件含 `subagents` 的 Claude Code 子代理 transcript；菜单栏活动显示可用 `showMenuBarActivity` 关闭。
- [验证] Fable/Claude 在 `CHANGELOG.md` 记录了 `HomePopoverActionsTests`、新增 `EngramServiceIPCTests.testFileSystemProviderExcludesSubagentChurnFromLiveScan`、Debug/Release build 与本地 `/Applications` 部署；本轮 Codex 文档同步另确认当前安装包含 `popover_liveOverflow` marker。用户已确认现在满意。

### 2026-07-04

- [新增] 新增本文件作为短工作备忘，采用 newest-first 的 `Changelog Memo` 格式，并回填 2026-06 以来的关键节点；长期事实仍以 `CHANGELOG.md`、`.memory`、`docs/TODO.md`、`docs/followups.md`、`docs/roadmap.md` 为准。
- [变更] 根目录 review/audit 文档已归档到 `docs/reviews/`：`2026-06-02-macos-swift-product-code-review.md`、`2026-06-03-five-round-multi-expert-audit.md`、`2026-06-10-multi-expert-audit.md`、`2026-06-28-full-project-audit.md`。
- [变更] 本地 `audit/` 审计包已迁出根目录，回填为 `docs/reviews/2026-05-03-*` 与 `docs/reviews/2026-06-03-testing-devops-audit.md`；旧 `audit/...` 路径引用已更新。
- [清理] Claude 已清掉 13 个 stale `.claude/worktrees`、26 个已合入/远端 gone 的本地分支，并删除 `macos/build`；`git worktree list --porcelain` 只剩主工作树。
- [排查] `codex-provider-audit-remediation` 分支保留：仍有 `origin/codex-provider-audit-remediation`，且 `git rev-list --left-right --cherry-pick --count main...codex-provider-audit-remediation` 显示右侧 4 个独有提交。
- [验证] 本轮文档归档后，根目录 Markdown 只剩 `AGENTS.md`、`CHANGELOG.md`、`CLAUDE.md`、`CONTRIBUTING.md`、`README.md`；旧根目录 review/audit 文件名和旧 `audit/...` 引用用 `rg` 已搜不到，`git diff --check` 通过。
- [后续] 当前剩余 follow-up 已回填到 `docs/followups.md`：提交本轮文档整理、处理保留分支、决定是否手动释放 Time Machine 本地快照、整理本地 `.git/info/exclude` 规则。

### 2026-07-03

- [性能] Claude 完成 49-agent 性能审计，基于真实 835 MB / 29,093-session DB 产出 25 个验证后的性能发现；随后 21-agent implement-review-fix 流程拆成 8 个 perf PR。
- [变更] 8 个 perf PR 覆盖 search fallback CTE、startup gating、UI hotpath、service read/render、MCP paging、indexer parse-once、adapter windowed reads、`fts_map` incremental FTS。
- [验证] 7 月 4 日 Codex 已把 8 个 PR 分支本地集成、二次 review/fix，并部署 `/Applications/Engram.app`；详见 `CHANGELOG.md` 的 2026-07-03 条目。
- [风险] 截止本 memo，notarization/stapling/DMG/remote CI 未跑；`npm run screenshots:compare` 仍受 macOS 容器隐私限制。

### 2026-06-28

- [新增] Project detail 增加垂直 rail 工作时间线，支持 AI semantic title 与点击跳转；核心文件为 `macos/Engram/Components/ProjectWorkTimeline.swift` 和 service `generateProjectWorkTitles` IPC。
- [审计] Claude 完成全项目 read-only audit，报告归档为 `docs/reviews/2026-06-28-full-project-audit.md`。
- [修复] Codex 关闭 2026-06-28 audit 的 actionable P0/P1 与部分 P2/P3：输入边界、路径校验、AppleScript 转义、MCP numeric clamps、aux-file size caps、FTS rebuild resume 等。
- [验证] 该 remediation pass 记录为 targeted App/Core/ServiceCore/MCP Xcode tests、targeted Vitest、`npm run typecheck:test`、`npm run lint`、`git diff --check` 通过；完整 Swift/coverage/UI/release/CI 未跑。

### 2026-06-27

- [新增] Codex 落地 deterministic project-work timeline：`session_work_beats`、`ImplementationDigestExtractor`、`ImplementationTimelineBuilder`、Timeline Work/Sessions 模式。
- [新增] Human-driven sessions 默认过滤与 “What you asked” 指令摘要进入产品；可靠源为 `claude-code`、`codex`，搜索不套默认过滤。
- [修复] 追加历史 backfill 和 direct startup instruction backfill，解决可靠源旧行 `instruction_count IS NULL` 误显示与已有文件未回填问题。
- [验证] 先后通过 full `EngramCoreTests`、full `EngramServiceCore`、full `EngramMCPTests`、release build、local deploy、codesign、real DB predicate/backfill smoke；UI tests、notarization/stapling/DMG、remote CI 未跑。

### 2026-06-26

- [新增] P1 relaunch 关键能力落地：MCP resources/prompts/tool annotations、memory lifecycle schema/ranking、OpenAI-compatible embedding client、semantic chunks、hybrid `get_memory`、semantic/hybrid service search、`get_rules` 与 corpus miner。
- [变更] 语义检索采用纯 Swift Float32 BLOB + cosine KNN/RRF，不引入 sqlite-vec native 依赖；embedding provider 全部 opt-in，缺 key/失败时降级 keyword。
- [验证] 相关条目分别记录 full `EngramMCPTests`、full `EngramCoreTests`、full `EngramServiceCore`、`xcodebuild ... Engram build`、`npm run check:fixtures`、`git diff --check` 通过；UI/remote CI 等仍按条目注明未跑。
- [策略] 竞争分析确认 Engram 定位为 MCP-first cross-tool memory/context layer，不做 chat-first dashboard、in-session rewind/checkpoint、dual licensing。

### 2026-06-21

- [文档] `docs/session-formats/` 扩展到 17 个 source adapters 的 EN/ZH 双语参考，VS Code 官方源码确认补齐，EN/ZH heading/fence/code-block parity 通过。
- [修复] Codex 按 17-source format audit 修复 Gemini CLI current JSONL、VS Code mutation log、Kimi rotation shards、Qwen thought skip、Cline legacy discovery、Copilot quote stripping、Gemini project move 等 Swift/TS drift。
- [同步] Multi-Mac sync L1 Unison live，L2 client/server catalog 完成并部署验证；远端 offload 相关基础设施继续作为后续能力使用。
- [Backlog] `docs/TODO.md` 记录 2026-06-21 后无 open TODO；open follow-up 当前仅限本轮 2026-07-04 workspace hygiene。

### 2026-06-20

- [新增] Remote session offload self-hosted 链路完成：Engram app 通过 Tailscale 对 `engram-remote` 做 offload/rehydrate，原始 transcript 不出本机，只上传可再生 artifacts。
- [部署] macmini-m1/macmini-hq 相关服务器和 nginx/Tailscale 路径已验证；`docs/remote-offload.md` 是运维入口。
- [约束] Live app 必须通过 Tailscale IP 访问 server；macOS Local Network Privacy 会阻断 background helper 的普通 LAN 路径。

### 2026-06-19

- [修复] Codex/Claude 处理 menu/live-session polling 负载与 idle CPU 问题，降低主菜单和 live session 轮询造成的高 CPU。
- [设计] Remote session server schema/engine 开始成形，为 6 月 20 日 offload 功能闭环铺路。

### 2026-06-15

- [修复] UX flow alignment PR #74 阶段完成，macOS UI 与 service backend 对齐；相关后续已在 2026-06-21 cleanup 中关闭。
- [修复] GRDB 运行时 crash 根因收敛为只链接一次 shared dynamic `GRDB-dynamic` product。
- [依赖] `npm audit fix` 处理 esbuild 与 `@grpc/grpc-js` advisories；CI/jsonl patch flaky test 也有对应修复记录。

### 2026-06-12

- [修复] Codex 修复 `EngramService` startup crash 和 high CPU scan，并完成本地 app/service restart 验证。
- [文档] GitHub-facing docs 与 Swift product state 同步，避免继续宣传 TypeScript/Node 历史运行面。

### 2026-06-10

- [审计] Claude 完成无 security 维度的 multi-expert audit，报告已归档为 `docs/reviews/2026-06-10-multi-expert-audit.md`；该 repo 后续 multi-agent review 不应默认加入 security/vulnerability expert。
- [修复] Codex 先完成 high-risk slice remediation，随后完成全部 confirmed finding 与 low-severity note 的本地 remediation ledger closeout。
- [验证] Evidence ledger 位于 `docs/superpowers/plans/2026-06-10-audit-complete-remediation.md`；本轮整理已把旧根目录报告路径更新到 `docs/reviews/`。

### 2026-06-06

- [修复] Project migration 兼容性集中收口：Gemini/iFlow dry-run parity、Codex rollout summaries、OpenCode SQLite、Claude/Qoder grouped-dir encoding、archive gitdir marker validation 等。
- [修复] Swift/TS parity 与服务细节多点 cleanup：generate_summary MCP status、database statement wrapper、migration_log indexes、export directory parity、hide_session not-found/local-state parity、empty reindex fact preservation。
- [部署] Local build 752 曾完成本地部署；该阶段也做过 stale follow-up plan reconciliation。

### 2026-06-01 至 2026-06-05

- [新增] Today Workbench 首轮 UI、i18n 与 completion pass 落地；advanced noise controls quieted。
- [修复] 6 月 2 日 Claude 完成 MCP fix 与 Swift-product review/fix/cleanup，包含 web UI pager O(N^2) 到 O(N) lazy streaming。
- [修复] 6 月 3 日 Codex 完成 multi-model review adjudication and fixes；6 月 4-5 日完成 follow-up remediation closeout、FTS table-swap rebuild、project migration coverage/encoder 修复、PR #49 CI follow-up。
