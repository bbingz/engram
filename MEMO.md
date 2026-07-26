# Engram Memo

## Changelog Memo

### 2026-07-26

- [变更] #269 row 11 规格已 rebase 到 `main@43333986`：resume 生产锚仍成立；示例谓词由仅比 basename 收紧为同时拒绝 `subagents` 路径，避免误放行未来的 `subagents/<id>.jsonl`。异家 review 后又锁定 NULL-parent 契约：先用持久父 id、再按 adapter 路径推导、最后才 generic hint，并补专门测试。corpus 数字继续限定为 `2026-07-25 16:04:59 UTC` 单次快照；附录改为 #268 已在 merge 前把 row 32 校正为 Partial。仅文档，无数据库写入、rerun 或 deploy。
- [裁决] #263 post-merge Tests `30178625833` 首轮仅 `swift-unit` 在大量 0-failure 测试后静默至 45 分钟被取消；exact merge tree 与 PR head 相同，其他 Tests lane、31 张 full UI 与 CodeQL 全绿。仅对 failed jobs 做一次有收据的 rerun，`swift-unit` 7m21s 全绿且 CI Gate 通过，归类为偶发 `xcodebuild`/runner hang；未二次 rerun、未 deploy。
- [变更] #268 verified status 已重算为 20 landed + 2 partial + 13 open：row 9 随 #262 转为 landed；row 12 的 #264 prune 前提与 #263 对齐已落地，但 DTO/UI/MCP 仍未实现。旧 `~1,001` 估算作废，完整索引后的运行时计数继续标记 `UNVERIFIED`；异家 review 抓到原 status prose 隔断 Markdown 表头，现已恢复 0–35 连续表格。
- [验证] #264 已 squash merge 为 main `33887fc4`；fresh Tests `30177028003` 与 CodeQL `30177028012` 全绿，full UI 31/31，Source Pulse 为 `SSIM 1 / pHash 0 / diff 0%`。未 rerun、未 deploy。
- [变更] #263 已基于新 main 校正 row 12 前提：528 行只作 2026-07-25 的 pre-prune 快照；#264 已落地域限定裁剪，但完整索引后的真实计数仍标记 `UNVERIFIED`，须同一 corpus 只读重测后再实现 C1-C3。
- [裁决] #262 合入后的 Tests `30170009516` 不是 runner 抖动：近四次绿 run 的 Source Pulse 指标稳定，而 exact merge artifact 因新增的 `Live sessions unavailable` 过期态确定性越过阈值；归类为预期 UI 变化导致的 baseline drift。
- [修复] 只用 `main@a598ed59` 的 CI 原图刷新 `sourcePulse_statusGrid.png`；同一 artifact 对旧基线复现 `SSIM 0.8945 / diff 7.9513%`。新 LFS 对象与原图 SHA-256 同为 `39fd9021…`；`SSIM 1 / diff 0%` 只作同一性校验，不作产品正确性证明。UI test 现先等 `sourcePulse_liveUnavailable`，消除 live poll 完成前抢拍。
- [验证] #270 已 squash merge 为 `351c339a`；fresh main Tests `30173625010` 的 full UI 31/31（Source Pulse `SSIM 1 / diff 0%`），CodeQL `30173625009` 亦绿。旧失败 workflow 未 rerun，baseline drift 已关闭。
- [修复] #262 exact-head 对抗 review 抓到连续失败轮询不一定触发 SwiftUI freshness 重算；`LiveSessionsHold.failed(at:)` 现只更新尝试时间，不覆盖 last-good 或成功时钟，三处消费者均接线。Popover stale badge 同时保留 active count 与 as-of。
- [验证] 两个复现先红（缺失失败状态成员；stale badge 丢 count），修复后定向 `EngramTests` 39/39；`xcodeproj drift ok`。完整证据见 `CHANGELOG.md`。
- [验证] #262 已 squash merge 为 `a598ed59`；合入后唯一红项按上方 baseline drift 记录继续收口。
- [修复] PR #264 的首次对抗 review 找到误删边界：不可用或中途枚举失败的 Claude profile 仍可能借健康 sibling 的非空 keep-set 进入裁剪域。重放提交 `0d81bfdb`（原 `3a854567`）现在先清旧域、只枚举 available profiles、目录读取失败即中止，并且仅在完整成功后发布 base/derived roots。
- [验证] 两条回归先红：2 tests / 5 assertions failed，两个场景都实际删了 1 行；重放到包含 #262 的新 base 后，聚焦 2/2、完整 orphan-prune 13/13、全量 EngramCoreTests 1,011 项 / 0 失败 / 1 环境 skip，xcodeproj drift 与 diff check 均通过。完整命令与因果见 `CHANGELOG.md`。
- [复核] Qwen 只读对抗 review job `pv-8239bb0e` 锁定 exact range `783eb5d3..3a854567`，明确返回 `APPROVE`。唯一 Medium 是单个 profile 读取失败会跳过整次 Claude adapter；已核实 `SwiftIndexer` 只跳该 adapter、继续其他 adapters，这是防止部分 keep-set 参与删除的必要边界。成功枚举仍裁剪由既有正向测试覆盖。
- [变更] #262 已 squash merge 为 `a598ed59`；#264 远端已 rebase 为 `7ed3c612`，安全补丁无代码冲突重放为本地 `0d81bfdb`。文档冲突仅合并两边同日事实。
- [复核] Qwen 在 `8b40f3ea` 找到 derived listing 与 roots 间的 shared-snapshot 漂移；`f3b2e8fb` 改为一次返回同源 locators/roots（run `run_5d146ddba574469089e0`）。
- [验证] 上述结构性回归先在旧 array-only 契约上编译失败，修复后 1/1；两个相关测试类 22/22，全量 EngramCoreTests 再次 1,011 项 / 0 失败 / 1 环境 skip，xcodeproj drift 与 diff check 均通过。
- [复核] Qwen 在 `7250e7d7` 确认修复并撤回疑似 shared-root bug；仅要求说明 canonical 去重与防御性 symlink 解析，现已补注释、无行为变更（run `run_ff75ff8140954c178b17`）。
- [变更] #264@`8e6a96df` 的 16 checks 全绿；#270 推进 main 后因同改 durable docs 变为 DIRTY，现已 rebase 到 `main@351c339a`。`range-diff` 证明代码/设计 patch-equivalent，冲突仅保留双方记录。
- [验证] 新 base 上 orphan-prune 13/13、完整 EngramCoreTests 1,011 项 / 1 环境 skip / 0 失败；`build-for-testing`、xcodeproj drift、diff check 通过。本机 `xcodebuild test` 的一次 IDE-session 启动卡死在测试体前，已终止且不计结论。
- [裁决] Qwen 对 rebased `04d8a048` 的首轮 code/test slice 要求修改（run `run_5077b33de83d442eb279`）。其中“应遍历 symlink 子项目”和“失败时保留旧 roots”均与既有安全边界/防误删红灯相冲突，拒绝；projects 根本身仍允许 symlink，根下 symlink 子项继续不遍历。
- [修复] 接受有效项：prune 错误改为私有日志后隔离、补重叠/重复 roots 数据库测试、明确 symlink 子项目测试及双层去重注释、简化 protocol-default 测试。
- [验证] 整改后 `build-for-testing`、orphan-prune 14/14、Claude symlink 聚焦 1/1、完整 EngramCoreTests 1,013 项 / 1 环境 skip / 0 失败。
- [未验证] #264 的 rebased exact head 仍须异家明确批准、force-with-lease push 与 fresh PR CI，方可合并。

### 2026-07-25

- [修复] **栈式 PR 假绿已修**：去掉 `test.yml` 的 `pull_request: branches:[main]`；`codeql.yml` 有意保留过滤——咬人的是 Swift 测试，而 CodeQL Swift 是最慢的一对。`verify-test-gate.sh` 按 `event_name` 分支不按 base ref，无需改。PR #258 / `487d6d09`。
- [修复] `build-release.sh` step 2 的裸 `xcodegen generate` 改为调 `scripts/check-xcodeproj-drift.sh`：非钉版直接拒跑、有 diff 直接失败。部署 1382 那三次尝试就栽在这里（第二次拿到 `build=20260725034737`）。PR #257 / `f84cd3fe`。
- [排查] 本地 vitest 挂 503 个的**真根因不是 Node ABI，是 npm 12 默认封禁 install script**——better-sqlite3 从没编译过。`allowScripts` 已批且不 pin（dependabot #236 要把它升到 13.0.1）。注意该字段会**整体覆盖** `~/.npmrc` 的 allow-scripts 列表；`sharp`/`esbuild`/`protobufjs`/`fsevents` 实测被拦也照常工作。
- [变更] 14 个 worktree、15 个分支已清（`~/.engram-worktrees` 回到 0B），双 upstream 随之消解；`.husky/pre-commit` 补 shebang；`CLAUDE.md` 增 `## Local Dev Environment`。
- [撤销] 两条开放项前提不成立：`ui-test-full` 不是恒 SKIPPED（只在 push 到 main 时跑，`487d6d09` 上跑了且通过）；`.gitignore` 不匹配 symlink（主仓和 worktree 都没有 symlink 形态）。
- [决定] **不发 1.0.5**——无外部用户。这关掉镜像 backlog 的 row 0，以及硬门禁在它上面的 row 33/34/35。`release.yml` 门禁保留，想发时打 tag 即触发。当前 tag 停在 `v1.0.4`、Release 停在 `v1.0.3`，本机装的是 1.0.5 (1382)。
- [清账] **镜像 backlog 36 行（0–35），13 个 PR 覆盖 22 行，仍剩 14 行**：4 行随不发布关闭；4 行（5/9/12/25）是 `docs/service-resilience-design-2026-07.md` 整个包——**写了 spec 但从没开 PR**；6 行（6/11/14/15/20/21）连 spec 都没有。其中 row 5 最刺眼：`App.swift:159-165` 注册了 `.restartService` 观察者，注释声称菜单栏项和状态横幅会 post 它，**全代码库无人 post**——一键服务恢复不可达，注释是假的。
- [验证] 清空 node_modules 后 `npm ci` exit 0 + `npm test` 1502 passed；`487d6d09` 的 main push 全绿含 `ui-test-full`。
- [教训] 本轮两次 CI 红**都因为本地验证命令和 CI 不是同一条**：`npx tsc --noEmit` 不覆盖 `tests/`（要用 `npm run typecheck:test`）；`Node quality and tests` 跑在 ubuntu 上，依赖 `/usr/libexec/PlistBuddy` 的测试要放 `build-release-script.test.ts`（macos-vitest 按文件名点跑），并显式传 `ENGRAM_BUILD_NUMBER`（CI 的 `fetch-depth: 1` 让 `rev-list --count HEAD` = 1，会被当成占位构建号拒绝）。
- [未验证] 14 个 `EngramMCP` 助手仍跑 1340，需各 MCP 会话自己重启才换代；#251/#241/#252 都在这条路径上。

- [排查] **base 指向 feature 分支的 PR 完全不跑 Swift 测试**：#253 的 base 是 `feat/transcript-find-rendering`，Tests / CodeQL 工作流只在 base 为 main 时触发，它的 check 列表只有一条 `Dependency Review`；GitHub 仍报 `CLEAN`，因为"没有必需检查失败"和"必需检查跑过了"是同一个状态。看 check 列表，别信 rollup 结论。
- [修复] 上述盲区藏住一个真实性能回归：row 30 为线程安全把 `ReplayState.parseISO` 改成 per-call 分配两个 `ISO8601DateFormatter`，而 `densityBuckets` / `walkTurns` / `closeTurnsAfterAppend` 三处在循环里调它。改为 `makeISOParser()` 由调用方各持一份复用，每轮遍历只分配一次。
- [修复] 两条源码扫描断言因钉标识符而失效（`private static let isoFormatter` 被合理删除、`snapshot` 被改名为 `fullSnapshot`），已重锚到性质本身，并做了能编译、能执行的变异验证。
- [验证] 13 个 PR 合入集成分支后本地全量 Swift 单测 1772 通过 / 0 失败；逐个合并无法发现上述问题——组合态从未被编译过，#253 的代码从未被测过。
- [未验证] "没有结论"不等于结论：drift 闸中止 → 测试报告为空；变异编译失败 → 报 `TEST FAILED`；工作流未触发 → 报 `CLEAN`。三者都不是测试结果，需查 `xcodebuild_exit`、已执行测试数、真编译错误数。
- [转录分页] Load more 改为 append-only 重建；助手首条显示 turn 耗时芯片（时钟回拨则隐藏）；堆叠在 #247 之上。

- [排查] 评审板记为"可合并"的五个 PR（#245 #248 #249 #251 #252）实际 `swift-unit` 全红，卡在同一步 xcodeproj drift 闸，测试一行都没跑；详见 CHANGELOG。
- [修复] 两类根因：#248/#249/#252 新增 Swift 文件未提交重新生成的 `project.pbxproj`（文件不在构建里，其测试从未编译执行），#245/#251 用本地 xcodegen 2.46.0 生成而 CI 钉 2.45.4。已用钉版重新生成并推送。
- [验证] 修复后 `PopoverUsageSectionTests`、`TranscriptAccessibilityTests`、`UIUXPolishWiringTests`、`MCPActivationOnboardingTests` 首次真正执行并通过。
- [修复] #248 随后触发既有源码扫描断言的假阳性——重试按钮渲染出与反模式相同的子串。已锚定到 `.onChange` 闭包签名（`d3b31a39`），并用变异验证守卫仍会响。
- [修复] #245 的两条 CodeQL `js/regex-injection` 不可达（`--format` 必须命中 support-matrix key），但元字符会改错矩阵行；已加 `escapeRegExp`（`b632452f`）。
- [新增] `scripts/check-xcodeproj-drift.sh` + pre-commit 接线（PR #255），把 CI 那道闸搬到本地，钉版不符直接拒跑。
- [未验证] `.husky/pre-commit` 缺 shebang（SC2148）、`feat/adapter-format-drift` 分支配了两条 upstream、`docs/mirror-followup-specs` 本地有一个未推送 commit `7ed3d2a6` —— 均为既有问题，本次未动。
- [洞察生命周期] 代理可读路径过滤 `superseded_by` 非空洞察（含 CJK LIKE）；ledger #14；CJK repro 查询改为两行公共子串以保证回归有效。
- [源健康] 可索引（非 skip）分母 + `healthReason` 提示；橙色徽章 18→8 量级。
- [Codex 原生父子] 启动回填读 line-1 `thread_spawn`/`parent_thread_id`；无条件 `session_meta` 门；多字节头边界/全拒排水/游标三次不重读测试；格式文档与 ledger #2 同步。
- [格式漂移] 本地 fingerprinter + 200 文件 baseline；desync/schemaVersion 纯函数；accept 折叠在 check 脚本（`baseline:adapter-format`）；Swift drift 测试 failure→XCTFail。
- [转录查找] 用户/助手/代码消息在 ⌘F 激活时仍走分段渲染，高亮落在渲染后文本上，不再把 markdown 压成 raw source；隐藏类型的匹配会计数并一键正确翻闸（type 与 systemPrompt/agentComm 分桶）。
- [验证] `TranscriptLabelAndCopyTests` / `TranscriptFindTests` 含 `_repro` 用例；相对 `origin/main` 仅功能提交。

- [UI 诚实/无障碍] 用量 share 不再画成绿条；转录图标控件补 VoiceOver/help；四页加载失败条补 Retry+ServiceErrorPresenter；侧栏与转录正文接入 Dynamic Type 缩放。
- [合并约束] 须在 #242 与 #247 之后合入（SourcePulseView / ColorBarMessageView 交叠）。

- [性能观测] DEBUG 下为转录/列表分页路径加 `os_signpost` 与可选主线程 stall 监视；Release 为空操作。行 15 构建溯源仍延后。

- [Claude 工作流] 适配器下沉发现 `subagents/workflows/wf_*/agent-*.jsonl`，按 path 挂父会话并保持 skip；不读 journal、不碰 session 级 workflows/。
- [路线裁决] 相对 row 22：工作流文件从未入库，只能走适配器发现；backfill 无法插入未发现行，slice C 正则加宽延后。

- [成本诚实] `get_insights` 按真实窗口日投影月花费，不足 3 天拒绝投影；`get_costs`/服务 costs 披露未计价会话并按归因缺失 vs 价表缺口分桶；CostSummary 有未计价提示行。Part C prices.json 仍延后。

- [MCP 激活] 首次引导任意关闭即完成；Help/右键菜单可报 issue 与重开引导；首页 MCP 激活卡 + 引导 MCP 步；设置内 Test now 四阶验证；helper 路径从 bundle 推导。

- [发布说明] 新增 `docs/release-notes/1.0.5.md` 用户向发行说明，并在 tag CI 强制存在对应版本文件；不执行 tag/release/repo 元数据变更。

### 2026-07-24

- [本机分支] PR #240 已合并为 `cb6bffc`；机器专属外置构建实现仅保留在无 upstream/远端的本地 `local/external-build-root@da595285`，共享 main 不硬编码 Bing-SSD-5。
- [构建路径] 本地分支把 DerivedData、archive、export log 放到 `/Volumes/Bing-SSD-5/XcodeBuilds/Engram`，最终 export 与 rollback 仍在 `macos/build`；使用前需明确切换或 rebase 该分支，禁止直接 push 机器专属默认值。
- [空间] 已删除 squash 等价的插件 worktree/分支、9 个已合入 audit 分支、595 MB `node_modules` 和 50 MB 旧 EngramExport；普通 `git gc` 将 `.git` 从 459 MB 降至约 174 MB，保留 81 MB CodeGraph 与 rollback。恢复 Node 工具链时使用 Node 24 执行 `npm ci`。
- [保护] rollback ZIP 完整性与 SHA-256 `3d92e132256ff973044efe12abeb4b3d55baae2517c177c2e6e389bc4ae08a03` 通过；清理后 App/Service 与只读 archive status IPC 正常，未重编译、重装、重启、迁移、改 Keychain/MCP 或写远端。
- [插件] 新增独立的 Claude Code 插件 MVP：复用已安装的 `EngramCLI` / `EngramMCP`，提供 SessionStart 上下文注入与手动 `catch-up`、`remember`、`handoff` 技能，不捆绑第二套 Swift 二进制。
- [边界] `EngramCLI context` 只经 MCP 调用 `get_context`，完整输出限制 8KB，缺 helper、异常响应或超时均 fail-open；自动 hook 不写 memory，只有用户手动调用 `remember` 才允许 `save_insight`。
- [复核] 真实 Claude Code 2.1.218 加载发现并修正标准 `hooks/hooks.json` 被 manifest 重复声明的问题；MCP 初始化顺序、超时进程回收、JSON 字节上限和路径解析也经独立 review 收紧。
- [验证] strict plugin validation、7 项插件测试、18 项 CLI 测试、显式写入路由/持久化测试、完整 MCP 169/169、Node build/typecheck/lint/knip 均通过；真实插件 smoke 成功注入上下文且临时 DB 字节不变，10 次启动 p95 低于 1 秒。详细命令和证据见 `CHANGELOG.md`。
- [发布] PR #240 已通过门禁并 squash merge 为 `cb6bffc`，本机已部署 Developer ID Engram `1.0.5 (1340)`；未 tag/GitHub Release、notarize、staple 或修改 Keychain/MCP 配置。

### 2026-07-23

- [候选版] 已将 npm 与 macOS 权威版本元数据对齐到 `1.0.5`；仍须通过生成项目无漂移、精确提交 CI、Developer ID、notarization/stapling、产物哈希和运行 smoke，当前不创建 tag 或 GitHub Release。
- [CI] Tests、Release、CodeQL、Perf 已统一改用带官方 SHA-256 校验的 XcodeGen 2.45.4 安装脚本，不再依赖 Homebrew 当前版本；安装器变更会触发全部 CodeQL lane。
- [验证] 本地 actionlint、shell 语法、真实下载/校验/生成项目、build、测试 typecheck、lint、knip、35 项聚焦 CI 测试和 Node 24 下全量 1,464 项 coverage 均通过；详细证据见 `CHANGELOG.md`。
- [整理] 已核对 Orca/Grok 会话、Orca worktree 清单、Git worktree/分支/reflog 与 7 月 17 日后的 dangling commits；旧 Orca workspace 已无登记或目录，独有实现均已由 #218–#228 的最终提交覆盖，主工作区仍与 `origin/main@3ba6e2a3` 对齐。
- [归档] Grok 最后一批生产 alias 清理记录已从未提交交接收回 `main`：详细证据见 `CHANGELOG.md` 与 `docs/verification/prod-alias-cleanup-2026-07-21.md`；低优先级残留为 `docs/followups.md` 的 `ALIAS-P2`。
- [保护] 整理前状态保存在本机 Git stash `0cf3715f6bd07943af8d1dd5af01035c242542e4`；本轮未删除 Git 对象、旧分支、生产数据，也未 push、部署或重跑生产清理。
- [验证] `git diff --check` 通过，完整 `EngramMCPTests` 169/169 通过；只读 alias 清单仍为 15 条 basename、0 条 path-shaped。

### 2026-07-16

- [性能] `0b754c2f` 至 `6ea7a98f` 收口周期性 Service 维护：embedding 按小批处理并对失败 provider 指数退避，repo 探测轮转限流，Archive policy/reconcile 避免无变化重扫，productive backlog pass 间隔 30 秒并在每轮后释放 allocator pressure，周期索引只把真实 merge 计为新增工作。
- [收口] 合并态通过 Node 24 clean install、TS 7.0.2 compiler/lock、build、test typecheck、lint、knip、1,461 项 coverage、fixture/parity、XcodeGen 无差异，以及 `EngramCoreTests` 899 passed/1 skipped、`EngramServiceCore` 555 passed/1 skipped；`d666c6e3` 同时修正 TS 7 rollback 生命周期。本轮只 push 源码，不构建或部署 App。
- [工具链] Fable 审阅并通过 TS 7 SPEC 后，PR #181 将保留的 TypeScript 开发工具链从 `6.0.3` 升级到 `7.0.2`，合并提交为 `68f124ea`；Swift App、Service 与 MCP 产品运行时没有引入 Node 启动路径。
- [验证] Node 24 原生 clean install、build、测试/脚本 typecheck、lint、knip、audit、1,461 项 coverage、fixture/parity 与编译后 CLI smoke 全部通过；TS 6/7 emit 都是 452 个文件，JavaScript 全部逐字节一致，声明仅引号变化，source map 全量可解码且共同坐标没有重映射。
- [CI] PR Tests `29493842404` attempt 2、CodeQL `29493842570`、Dependency Review `29493842582` 全绿；首次 Remote Server 并发测试偶发失败经本地 20/20、失败项重跑及主干复跑确认未复现。`main@68f124ea` 的 Tests `29495170792`（含 full UI）与 CodeQL `29495170922` 均成功。
- [部署边界] 本变更按设计不部署；TypeScript 仍是 devDependency 且 release verifier 禁止 Node 产物进入 app。保留当前 `/Applications/Engram.app` `1.0.4 (1221)`，fresh 只读验证确认 Developer ID/bundle hygiene、App/Service、`srw-------` socket、MCP 27 个工具及 archive status 正常。

### 2026-07-15

- [内存修复] build 1205 收口 Service 启动峰值：跳过无消费者的 tail snapshot 查询；archive v2 仅在 catalog schema 升级时重放 manifest 绑定；grouped-dir 对账改为逐文件 autoreleasepool、先筛 `"cwd"` 再解析，并以版本标记只运行一次；FTS 维护改为每轮最多 500 页的可续跑 merge，启动不再执行全量 `VACUUM` / `optimize`。
- [实机验证] 同一真实数据集下，修复前启动阶段 sampled RSS 峰值约 7.93 GiB；build 1205 首轮一次性 grouped-dir 对账的 sampled RSS 峰值约 1.17 GiB，`vmmap` 物理峰值 974.4 MiB，约 226 秒完成并写入版本 1。二次启动即时 ready、27 秒完成，物理峰值 926.3 MiB、完成后 127.7 MiB；Developer ID release verifier 与 Core/Service 全量测试通过。
- [同步观测] Archive v2 最近 drain pass 每轮继续捕获 7–32 个文件，状态为 idle、无 active stage，M1 队列剩 1；HQ 有 9 个 `transport_network` 重试并处于短暂基础设施退避。同步仍在推进，但不宣称远端积压已经清零。
- [部署] `/Applications/Engram.app` 已安装为 `1.0.4 (1205)`；完整 Developer ID、Hardened Runtime、secure timestamp 与 bundle hygiene 验证通过。build 1202 回滚包保留在 `macos/build/rollback/Engram-1.0.4-1202.app`。

### 2026-07-14

- [排查] Archive v2 慢同步的主因不是积压发现或双副本互相阻塞，而是单个瞬时网络错误会终止该副本剩余批次并暂停 60 秒。现场 `archive.sqlite` 仅有 HQ 2 条、M1 1 条 `retryWait`，却分别有 5112 与 2490 条普通 `pending`；最近半小时多数副本分钟仅完成 1–2 条。
- [修复] PR #167 / `7cf190d1` 增加批内一次有界健康探针：首个瞬时错误仍保留行级 full-jitter 重试；下一条完整验证成功则继续余下批次，第二个瞬时错误、无可用探针或资源门关闭才触发原有 60 秒副本熔断。鉴权/配置错误、HQ/M1 隔离、每副本串行与双回执证明不变。
- [验证] 新回归测试先复现旧行为（HQ 只请求 1 条、验证 0 条且进入暂停），修复后 `ArchiveReplicationCoordinatorTests` 39/39、相关 Service archive 调度测试 82/82、全量 `EngramCoreTests` 890 项（1 skip、0 failure）通过，PR #167 全部门禁通过并合并为 `834bf1f2`。
- [部署] 经明确授权，从 `main@9d9ae163` 构建并安装 Developer ID Engram `1.0.4 (1202)`，23:02 重启 App/Service。安装包通过 bundle hygiene、结构、deep/strict codesign、Hardened Runtime、Developer ID authority 与 secure timestamp 检查；ZIP SHA-256 为 `94a1d3a882daf4d606876f2206c2d78c741684c5483a92d24934cf2e815e3b06`，build 1188 回滚包保留在 `macos/build/rollback/Engram-1.0.4-1188.app`。
- [现场验证] 30 分钟内 HQ verified `6178→6279`（+101）、pending `4939→4835`；M1 verified `8837→8995`（+158）、pending `2280→2118`，合计 +259、约 8.6 条/分钟。期间持续出现 `transport_network` / `NSURLError -1005` 和 retry，但普通队列仍推进、两副本均能暂停后恢复；quarantine 与 server error 均为 0。
- [资源] Service 启动扫描时 RSS 峰值约 8.36 GiB，`vmmap` 显示主要是可回收 `Malloc Small (empty)`；随后回落并稳定到约 3.45 GiB，30 分钟内没有无界增长。App 约 85 MiB，socket、CLI archive status、MCP initialize/tools/list 均通过。
- [上一安装] build `1188` 与 `git rev-list --count 3b0b5b1d` 一致；当时安装主程序与 `macos/build/EngramExport/Engram.app` 的 SHA-256 均为 `b46c78aaa3a7da7df08c261d88f3f1fd848aece15e1b46fad9e716d00f1c9769`。该包现仅作为回滚基线，不再是当前运行版本。
- [CI] 以 3 个独立 review agent 加 coordinator 裁决完成 CI 编排审计，分 4 个 PR 合入：#161 按变更路径路由 CodeQL 并增加 fail-closed `CodeQL Gate`，#162 稳定 Swift product 的 SPM clone cache/timeout，#163 强制 MCP contract fixture 新鲜度，#164 收口 dependency/perf/release 与 `CI Gate`。
- [性能] 旧 Perf run `29317039094` 在编译后卡于 Xcode test-manager IPC；改为 `build-for-testing` 后直接 `xcrun xctest`。最终 PR head `845d6d69` 的 run `29318748080` 在 macmini-m1 / Xcode 26.6 上 2m52s 完成，20/20 fixtures，平均 0.049s、RSD 1.315%，build/test exit code 均为 0。
- [供应链] 启用 GitHub Dependency Graph，并新增 pinned Dependency Review：moderate 及以上漏洞覆盖 runtime/development/unknown scopes，snapshot warning 60 秒重试后仍不完整则 fail closed；当前 SPDX 2.3 SBOM 为 363 packages。
- [保护] `main` strict required checks 已读回为 `CI Gate`、`CodeQL Gate`、`Dependency Review`；PR #164 的 Tests `29318747842`、CodeQL `29318747789`、Dependency Review `29318747679` 与 Perf `29318748080` 均通过后，合并为 `e76b463c`。
- [主干验证] 合并后的 `main` Tests run `29321120090` 成功，包含 Node、macOS gates、Swift unit、remote-server package、full UI 与 `CI Gate`；CodeQL run `29321120012` 的 TypeScript、Swift product、Swift remote-server 与 `CodeQL Gate` 全绿。
- [轻量路由] closeout PR #165 的 Tests `29322068421` / CodeQL `29322068445` 对耐久文档变更跳过全部 Node、macOS、Swift、UI 与语言分析重任务，同时两个 fail-closed gate 通过；Dependency Review `29322068681` 通过。
- [发布边界] release tag 现在拒绝 SemVer 数字段前导零，release verifier 会核对 notarization/stapling；仓库没有 Actions secrets，故本轮只验证 ad-hoc 签名路径，未伪装执行真实 Developer ID notarization。
- [清理] 刷新 `origin`（含 prune）后，删除 3 个干净且 HEAD 已被 `origin/main`（`3b0b5b1d`）包含的本地 worktree 及对应分支：`.worktrees/archive-drain-fairness` / `codex/archive-drain-fairness`、`.worktrees/archive-v2-backlog-drain` / `codex/archive-v2-backlog-drain`、`.worktrees/claude-profile-registry` / `codex/claude-profile-registry`。
- [归档与清理] 进一步用 `git cherry -v origin/main <branch>` 确认 `claude-profile-empty-capture` 的 3 个、`claude-profile-reclamation` 的 2 个独有 SHA 均已有等价补丁在 `main`；删除两项 worktree/分支。已合入的 `archive-review-gpt56` 的 5 个未跟踪 handoff 文档迁入 `docs/archive/reviews/2026-07-11-archive-review-gpt56/`，仅 `round2-clusters.md` 的 1 个行尾空格为通过格式检查而规范化，再删除 worktree/分支。
- [验证] 对每个 worktree 核验 `git status --porcelain`、`git merge-base --is-ancestor HEAD origin/main`、`git rev-list --left-right --count origin/main...HEAD` 与（非祖先分支）`git cherry -v`；归档包 SHA-256 已复核。`git worktree prune --verbose` 后仅剩 `main`，当前仅本轮耐久文档有修改。
- [保留] `git fsck --full` 未报告对象损坏，但列出历史与已删分支留下的 dangling objects；未运行破坏性的 `git gc --prune=now`，以保留可恢复历史。工作树 clean 不等于立即物理回收 Git 对象。

### 2026-07-06

- [完成] Feature-cut Top 10 已按 `docs/followups.md` 的自主执行协议完成：PR #103-#112 连续合并，ITEM 0-10 均落地；后续验收确认 keep-list、孤儿清扫、墓碑测试、默认关闭归档来源等关键约束均通过。
- [修复] 追加清理 LOW 残留并合并 PR #113：App target 移除死 Hummingbird 依赖但保留 EngramRemoteServer 依赖；`SettingsHonestyTests` 增加防回归 guard；`settings_page` / `settings_general` baseline 从 CI run `28745689659` 实拍刷新；`settings_network` 当前已无 tracked baseline 或 active capture。
- [验证] PR #113 本地验证包括 `xcodegen generate`、目标 `SettingsHonestyTests/testAppTargetDoesNotLinkDeletedHttpStack`、`SCREENSHOTS_DIR=/tmp/engram-settings-compare npm run screenshots:compare`、`git diff --check`；PR CI 全绿，main `24cc4562` 的 Tests run `28793745657` 与 CodeQL run `28793745640` 均 success。
- [后续] 当前 durable backlog 口径：`docs/TODO.md` 和 `docs/roadmap.md` 无 open 项；`docs/followups.md` 仍保留低优先级 open follow-up（`codex-provider-audit-remediation` 分支、`.git/info/exclude` 规范化、perf residuals 中的 Cursor WAL cache/P3 latent 项）。Time Machine 空间 follow-up 已因当前 `df -h .` 显示 241Gi 可用而关闭为“不需立即手动清理”。

### 2026-07-05

- [新增] Fable/Claude 用 38-agent opus+sonnet workflow 完成砍功能审计（4 区域清单 → 4 视角提案 → 去重 → 每候选对抗验证 → opus 终审），与 Codex 同日的“隐藏/降级默认入口”轮合并为 Top 10 执行清单，现归档在 `docs/followups.md` § "Completed — feature-cut execution plan, adjudicated Top 10 (2026-07-05)"；Codex 的 live_sessions 隐藏提案被验证否决。该执行计划已在 2026-07-06 完成并归档为 closed follow-up。
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
- [后续] 当时剩余 follow-up 已回填到 `docs/followups.md`：提交本轮文档整理、处理保留分支、决定是否手动释放 Time Machine 本地快照、整理本地 `.git/info/exclude` 规则；2026-07-06 已关闭文档提交与 Time Machine 立即清理项。

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
- [Backlog] `docs/TODO.md` 记录 2026-06-21 后无 open TODO；当时 open follow-up 主要是 2026-07-04 workspace hygiene，后续状态以 `docs/followups.md` 当前 Open 区为准。

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
