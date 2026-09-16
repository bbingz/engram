# Engram Memo

## Changelog Memo

### 2026-09-16

- [修复] Collector PR #446 的 CI 闸门：archive-v2 精确允许 Web unlink/suggestion DELETE；R3 allowlist `npm_` 脱敏前缀；Linux 无 `/usr/bin/otool` 时跳过 Mach-O 解析，Concurrency 闭包测试改为 darwin-only；用 CI 钉住的 xcodegen 重写 `project.pbxproj`；macos-15 上给 Kimi/Cursor 测试数组标 `[String]`；会话列表混合查询只 MATCH 长词（`Review P2 tests` 不再空页）；AI stats 单端日期改用当天；costs 合计按 key 排序后再加，避免 Dictionary 迭代让快照/live freshness 误报 stale；MCP source enum 测试跟 `SourceName.allCases`（含 pi/grok）；collector inventory SQL 不用 Swift `5_000`。证据见 `CHANGELOG.md` 顶部。未部署 HQ。

### 2026-09-15

- [验证] 完整 scheme：RemoteServerCore 506、CoreTests 2013（1 skip）绿；ServiceCore 因 `testOverviewOrdersMachineThenInstance` 仍按默认 limit 取 3 条 stream 失败。测试改为显式 `limit: 3` 后 `WebMetadataProducerTests` 91/91。未提交、未部署。
- [修复] HQ Web 六项残留（仅 collector worktree，未部署）：overview 省略 limit 50→2；会话列表 1–2 字不再对 `sessions_fts` 无界 LIKE（空页 + `query_too_short`，去 Search）；Search 短词 LIKE 按 recency/`fts_map` 封顶；Files `agents=all` 增加测试用覆盖部分索引 `idx_sessions_activity_id`（未 migrate HQ）；Health 改文案区分 skip 终态与空转写隔离。证据与未跑全套见 `CHANGELOG.md` 顶部。

### 2026-09-14

- [修复] `agents=all`/`agents=only`（会话页「All」「Agents Only」、Stats 的 Agents 选项）在 HQ 规模下整体失效：默认 `hide` 带 `parent IS NULL AND suggested IS NULL` 两个等值，规划器自己会选覆盖部分索引 `idx_sessions_web_list_keys`；`all`/`only` 只剩 `hidden_at IS NULL` 一个索引约束，无统计的 HQ 库选 `idx_sessions_visible` 读全部 44k 可见会话行（其中 32k skip 层随即丢弃）。r14 实测：会话「All」1.85s，Tools all 503/2.08s，Files all 503/2.00s，「All」+ 搜索词 1.6–1.8s。`sessionsJoinSQL(agents:on:)` 对 `.all/.only` 把 `sessions s` 写成 `INDEXED BY idx_sessions_activity_time`（迁移自带的排除 skip 的部分索引），用于列表、总数（含搜索总数：线上 1.65s→0.02s）、工具、文件四类语句；页面新鲜度复查的 ID 批次（≤50 个）改为钉住主键（`primaryKeyJoinSQL`，仅当 `sqlite_master` 有 `sqlite_autoindex_sessions_1` 才加 hint），此前 `all`+搜索时它也走 visible 索引重读 44k 行（一次请求 1200 个采样中 950 个在这里）。r17 线上未缓存：会话 all 0.07s、all+xcodegen 0.13s、all+source+query 0.32s、Tools all 0.38–0.59s、Files all 1.14s（剩余最慢项，走非覆盖索引读 11.8k 行；覆盖索引需迁移，未做）。浏览器：「All」1–50 of 6,545、+xcodegen 1–50 of 122、Tools 按会话分组 agents=All 5,380 组、Files 有行、Child sessions 显示「No child sessions」而非「unavailable」。新增 `testAgentsAllPinsSessionsToSkipExcludingIndex_repro`，`WebMetadataProducerTests` 搜索用例增加 `.all` 断言。r15/r16/r17 依次激活（回滚 plist 均留），Grok lanes-10/11 106/106，lanes-12 105/106（唯一失败为已知负载敏感的 costs 用例，与改动语句无关，单跑通过）。
- [修复] Child sessions 的 r10「0.215s 冷」数据来自一份跑过 `ANALYZE` 的数据库副本；HQ 线上 `index.sqlite` 从未 ANALYZE、没有 `sqlite_stat1`，r10/r11 的 children 语句在线上仍是 1.53s/次（无统计时规划器假定任何索引等值只返回约 10 行，于是选了匹配全部 44k 可见会话的部分索引 `idx_sessions_visible (hidden_at=?)`，浏览器没报 503 只是因为差 0.3 秒到期限；「首个 1.08s 之后 0.03s」是 producer 的短期租约缓存，不是查询本身）。`childRows` 改用 `childVisibilitySQL`：三条隐私谓词写成 `+s.hidden_at IS NULL` / `+s.source = …` / `+s.authoritative_node = …`，一元加号让它们不再作为索引约束（SQLite 文档手法），同时排除了启用来源很少时通过传递等值 `s.source = i.source AND i.source IN (…)` 选中 `idx_sessions_source` 的第三种走法；此后无论有无统计、来源多少，多索引 OR 都是唯一便宜的计划。线上只读验证 0.08s（2,315 个 skip 层子会话的父会话）；service-index 切 `r13` 后经 remote-server 实测 children 重启后首个 0.088s、闲置后 0.013–0.019s（r11 为 1.29–1.69s）。测试改为 `testChildrenStatementUsesBothParentIndexes_repro`：对 producer 实际发出的语句在无统计 fixture 上 `EXPLAIN`，要求两条 parent 索引且不出现 `idx_sessions_visible`/`idx_sessions_source`/`SCAN s`/`SCAN i`（lanes-7 如预期在 `idx_sessions_source` 上失败，lanes-8 4/4）。r12 只去了 `hidden_at` 一项、未激活。
- [修复] Stats→Files 在 r11 回填 190,039 行 `session_files` 后每次 503（2.00s）：采样显示快照读取 1.26s 且新鲜度复查再做一遍，其中 `fileActivityLabel`→`TranscriptRedactionPolicy.redact` 约 0.5s、`publishedProjectKey` SHA-256 约 0.25s（约 1.6 万个不同路径各算两遍）、`Row.fetchAll` 0.36s（CLI 中 `ORDER BY s.id, file_path, action` 的临时 B 树占 0.50s 语句的 0.46s）。`fileActivityRows` 去掉 ORDER BY，组权威改为对排序后的每行摘要再摘要（行序无关）；`FileActivityRecord` 只存 path/key/计数，label 在 `.item` 上惰性派生（只有返回页付脱敏成本）；key 用有界的 `FileKeyCache` 跨快照读/复查/后续请求复用；游标匹配改用记录上的 key。新增 `testFileActivityStatementIsUnsortedAndAuthorityIgnoresRowOrder_repro`。打包为 `r14`，激活与 HQ 时延见 `CHANGELOG.md` 顶部条目末尾。
- [修复] HQ `session_files` 一直为 0 行的原因不是没有采集，而是启动期文件活动修复任务在自己的候选查询上就超时：`CaptureIngestFileActivity.repairCurrentGenerations` 的 `SELECT … ORDER BY g.generation_id LIMIT 4` 在 HQ 实测 14.7–15.6s（规划器从账本状态索引出发、把 38,780 个当前头全部连接后用临时 B 树排序再取 4 条），2 秒批次期限在取回后立即抛 `deadlineExceeded`，因此从未修复、从未落标记、从未写游标。改为从 `capture_ingest_generations` 出发的 `CROSS JOIN`（首批 5ms，游标 3 万行处 14ms），并把批中途超时改为保留已完成头与游标、单个头独占超时则本次启动跳过（HQ 有 44 个 5–87MB 的 v2 代与 93 个 >5MB 的 v1 代，此前整批回滚会让该批永远无法推进）。三条 `_repro` 测试修复前 0/3、修复后 107/107。改动随并行 Web 线的 `web-parity-20260913-r11` 上线：08:41–08:46 一次遍历修复 38,779 个头，`session_files` 190,039 行 / 22,925 会话。副作用：`/web/api/file-activity` 从「空」变为「贴线」，HQ 1.95–2.00s、200/503 交替（回填期间返回 409），读侧 `fileActivityRows` 的全表排序与二次聚合是下一项，未动。另：HQ 账本 577 条隔离全部是 `parse.noVisibleMessages`（cursor 57 条属此类，非 Cursor 专有解析失败）。详情见 `CHANGELOG.md`。
- [验证] 09:00–09:30 对 HQ 全部 GET 读端点做了一轮只读时延扫描（r14 激活后 `file-activity` 1.25s 冷/0.34s 热，`fa-read` 关闭）。仍贴线或超线的只剩三处，均未改代码：(1) `/web/api/overview` 不带 `limit` 时默认 50，一次请求把 17 个采集流全算完，HQ 实测 2.85s（每流 `readyCount` 合计 2.07s + 账本分组 0.77s）稳定 503；浏览器用 `limit=2` 分 9 页请求（最慢页 0.91s/1.20s 热），所以 UI 不受影响，只是 API 默认值在 HQ 规模不可用。(2) 两字 CJK 搜索（如「修复」）走 `sessions_fts` 的 `LIKE` 全表扫描，HQ 777k 行/379MB 内容 5.0–6.2s，仍在 8 秒搜索期限内但会随语料增长越线；`instr`/`GLOB` 同为 5.8–6.5s，无免费加速，真正的选项是按时间序提前终止（fts_map 已 1:1 覆盖 777,464 行）或加短词索引，属设计决策。(3) Health 卡片「Parsed 28,868 / Index ready 1,314」（Claude Code）会被读成积压，实际 32,138 个 `parsed` 头全部是 `tier=skip`（28,654 条 `agent_role=subagent`）：`ensureCurrentCaptureFTSJob` 对 skip 不建 FTS 作业，readiness 永不推进到 `index_ready`，是设计上的终态而非积压，建议改标签或拆分计数。另在 `/tmp` 副本上验证了 Fable 提出的「HQ 无 `sqlite_stat1`」问题：`ANALYZE` 3.5s，children 原句自动改走多索引 OR，但 r11 前的 repair 候选查询仍 2.06s（我的 `CROSS JOIN` 重写不可省），会话列表首页近似语句从 1ms 变 18ms（临时 B 树排序），结论是不引入全库 ANALYZE，继续逐语句锁计划。
- [修复] HQ 工具统计 session 分组超时的真因不是 I/O，而是 Foundation `Data.hash` 只哈希前 80 字节：HQ 会话 ID 约 196 字节且同一采集流共享前缀，`[Data: Group]`/`Set<Data>` 退化为线性探测（8k 键 9.4s vs `String` 键 12ms）。`ServiceWebMetadataProducer` 的 `toolAnalyticsRows`/`fileActivityRows`/`admittedAuditSessionIDs` 改用全字节哈希的 `ByteKey`，新增 4000 条长前缀会话的 repro 测试。service-index 先切 `web-parity-20260913-r9`，HQ 实测 `groupBy=session` 由 r8 的 503/1.6s 降到 0.73–0.90s（服务重启后首个请求 1.92s，仍贴近 2 秒期限），tool/project 不变；浏览器 Stats→Tools→按会话分组显示 5,378 组。Grok 四条 producer 线 113/114，唯一失败的 costs 用例与改动无关且复跑 3/3 通过（Release 构建并行导致的负载敏感）。r8 条目中的覆盖索引后续项已撤回。
- [修复] 浏览器会话详情「Child sessions」页签在 HQ 返回 503：`childRows` 的 `(parent = ? COLLATE BINARY OR suggested_parent = ? COLLATE BINARY)` 显式 COLLATE 让 SQLite 放弃多索引 OR 优化，每次请求遍历全部 38,779 条身份绑定（首个请求 1.96–2.00s）。两列本就是 BINARY，去掉显式 COLLATE 结果不变，规划器改走 `idx_sessions_parent`/`idx_sessions_suggested_parent`。service-index 已切 `r10`（回滚 plist 已留），HQ 实测 children 0.215s 冷/0.028s 热，浏览器显示「No child sessions」（HQ 现有父子链接全部指向 skip 层子代理会话，按设计不展示）。新增 plan 断言 repro（3000 条填充会话 + 真实 ANALYZE）。HQ 就是本机，构建/测试并行时 Web 时延会明显上浮。详情见 `CHANGELOG.md`。

### 2026-09-13

- [部署] 原生 Web 已上 HQ：service-index 跑 `web-parity-20260913-r8`，remote-server 跑 `r5`，均有回滚 plist 与 SHA256 清单；编辑凭据已生成并注入（未入库）。浏览器验收登录、五页、别名增删写回、AI 配置表单通过。D15 迁移接口验收（21 服务 + 5 远端）。修复 HQ 规模三缺陷：搜索 8 秒超时改为分阶段 CTE（`xcodegen generate` 1.41s 冷/0.35s 热，两字词约 5–6s 仍在期限内）、片段 `<mark>` 原样显示、`aiProtocol: disabled` 导致设置不可用。工具统计 tool/project 分组 1.1–1.8s，session 分组仍超 2 秒（当时归因于 I/O，已被 09-14 条目纠正为 `Data` 哈希截断，r9 修复）。前端 175 项、Biome 通过；Grok 全量 Swift 三条线仅剩 2 项环境依赖与 1 项主机固有失败，磁盘满导致的 6 项已复跑 90/90 通过。分支 312 处改动未提交，交由所有者。详情见 `CHANGELOG.md`。

- [验证] 原生摘要与配置收尾 4 项通过：完整保存、无提供商回退、拒绝会话先于凭据读取，以及 HTTP 保存后的真实配置读取。D13 合计 14 项原生／联调、6 项 HTTP／客户端；D14 为 9 项原生／联调、14 项远端回归。迁移接口继续推进，未部署；详情见 `CHANGELOG.md`。

- [新增] AI 配置接口已接通：多行 prompt/style 可保存，GET 不再回显带账号或查询串的 URL，embedding 地址按原生 `aiBaseURL` 回退。8 项服务、14 项远端／客户端、1 项真实 HTTP／IPC 联调通过。未部署，详情见 `CHANGELOG.md`。

- [新增] 保存笔记写入口通过 6 项原生／真实联调、10 项 HTTP／写客户端检查。摘要、标题和批量补标题界面已接好，167 项前端及桌面／手机模拟流程通过；发现原生保存摘要截为 200 字符，Cursor 正修复并接入生成接口，尚未部署。详情见 `CHANGELOG.md`。

- [新增] Insights 原生读取通过 17 项服务／真实联调、11 项语义回归和 31 项 HTTP／客户端检查，元数据客户端专项已通过。保存笔记表单完成，160 项前端和手机模拟保存／读回通过；Cursor 正接真实写入口，未部署。旧接口实际是保存文本，已纠正清单。详情见 `CHANGELOG.md`。

- [新增] Insights 搜索卡片和全文续读已接入；154 项前端检查、桌面／手机模拟渲染通过。Cursor 正修正仅有 Insights 向量时的搜索门槛，原生与真实 HTTP／IPC 联调待跑；尚未部署，全量写操作仍在范围内。详情见 `CHANGELOG.md`。

- [新增] AI 调用记录、详情和统计已接通，聊天及向量请求均记录；149 项前端、47 项原生／联调／后台回归、110 项 HTTP／客户端检查通过。修复刚写入调用被统计漏掉的问题，未部署；继续 Insights 搜索。详情见 `CHANGELOG.md`。

- [新增] 文件活动、用量和仓库页面已接入；手机显示改为卡片，142 项前端测试通过。15 项原生服务／真实采集联调及 106 项 HTTP／权限／客户端检查通过，未部署。详情见 `CHANGELOG.md`。

- [新增] Stats 工具统计已接通，132 项前端、4 项服务统计及 100 项 HTTP／权限／客户端回归通过；桌面和手机页面已检查。文件活动写入／历史修复 9 项、真实采集到 Web 联调 1 项也通过；继续文件活动页面及其余能力，未部署。详情见 `CHANGELOG.md`。

- [新增] Web 会话关系编辑已接入页面，128 项前端、47 项 HTTP／权限回归、21 项原生服务／真实数据库联调通过；桌面／手机模拟流程已检查，未部署。继续统计接口及文件活动数据补齐。详情见 `CHANGELOG.md`。

- [新增] Web 子会话与时间线已完成本地联调：120 项前端、26 项服务／真实采集联调、45 项 HTTP／权限回归通过；桌面和手机页面已检查，尚未部署。继续接回会话关联与建议确认等写操作。详情见 `CHANGELOG.md`。

- [新增] Web 来源启停配置已接通：114 项前端、7 项真实服务联调、56 项远端回归通过；全部停用后可重开，手动隐藏和其他配置保留。桌面／手机模拟验收通过，尚未部署；继续子会话／时间线。详情见 `CHANGELOG.md`。

- [新增] Settings 别名编辑界面已接入，110 项前端及 24 项权限路由测试通过；桌面／手机模拟新增删除已检查。原生别名写入及真实 HTTP／IPC／数据库联调 8 项通过；84 项远端回归也通过；已派工来源配置开关，尚未部署。详情见 `CHANGELOG.md`。

- [新增] Stats 费用界面及后端已通过 103 项前端、4 项费用及 111 项远端／权限测试，桌面／手机模拟渲染通过；编辑权限基础已验证，正接回别名新增／删除，写接口尚未接通。未部署。详情见 `CHANGELOG.md`。

- [变更] 本轮全量范围已明确包含旧 Web 配置修改、别名删除等写操作；通过现有 Swift 服务写入口恢复，费用功能继续推进。详情见 `CHANGELOG.md`。

- [变更] 恢复旧版深色及导航样式，桌面／手机渲染通过；搜索后端完整 97 项及 HTTP／界面 58 项通过，前端 99 项通过。费用功能接续开发，全量对齐和真实联调未完成，尚未部署。详情见 `CHANGELOG.md`。

- [变更] Settings 后端 3+91 项组件测试通过；上一页／下一页、日期及纯工具会话筛选已接入本地界面，96 项前端测试通过，桌面／手机模拟渲染已检查。Cursor 正补后端精确总数与筛选；语义搜索等全量能力仍未完成，尚未部署。详情见 `CHANGELOG.md`。

- [新增] Settings 四块旧版内容和五页导航已接入本地界面，92 项前端测试通过；桌面／手机模拟渲染已检查。路径型项目别名要求保留安全显示，后端正补回归验证；尚未部署。详情见 `CHANGELOG.md`。

- [变更] 来源／项目选项接口已通过本地验证；统计接口 76+87 项测试通过，Stats／Health 页面及导航已接入，89 项 JS 测试通过，桌面／手机模拟数据渲染已检查。Cursor 正补 Settings；全量功能及真实端到端验收未完成，尚未部署。详情见 `CHANGELOG.md`。

- [变更] 已补回 Agent 切换、时间和消息数，修复允许显示的 Agent 会话无法打开正文；首批后端 87+38 项及 UI 路由 8 项通过。来源／项目多选界面已接好，82 项 JS 测试通过；分页项目接口仍在修正，统计等完整能力尚未验收。详情见 `CHANGELOG.md`。

- [变更] 已恢复旧 Web 全量对齐开发，确认此前界面功能缩水；本地 ID 跳转相关 74 项 JS 测试通过，Cursor 正补筛选接口，首轮后端仍有 1 项失败。尚未完成浏览器验收或部署，详情见 `CHANGELOG.md`。

- [交付] 按要求先交付已部署版本供验收，后续开发暂停等反馈。Web 可用；当前 39 次追加通过，完整 CPU 结果仍待现有观察完成，旧原文不阻塞。入口和详情见 `CHANGELOG.md`。

- [验证] 新包基线全文及前 18 次追加均通过，最慢 26.7 秒；资源观察仅余 Claude 复核。日常旧索引服务仍停用，App/设置未变，完整验收继续。详情见 `CHANGELOG.md`。

- [优化] 新调度包已更新日常 Mac，17 项回归及 7 条实际包流程通过；定期检查改为 10 秒、事件检查最多 1 秒。本地同场景 CPU 为 0.52%，实机 30 分钟资源及 60 次追加验证已启动，尚未验收；旧程序和设置可回滚，旧原文不阻塞交付。详情见 `CHANGELOG.md`。

- [修复] 缺正文重试已改为同批写入，10 项回归和 7 条实际包流程通过，本地同场景 CPU 从 4.27% 降至 3.38%，尚未部署。当前部署完整 30 分钟 CPU 13.18% 未达标、采样 RSS 55.7 MiB 达标。详情见 `CHANGELOG.md`。

- [验证] 新版 60 次追加全部成功，p95 33.1 秒、最慢 63.3 秒；62 条完整消息和双端 126,976 字节原文通过，运行版本未变。CPU 稳态验收仍待 Claude 扫描完成。详情见 `CHANGELOG.md`。

- [修复] 空闲批量读取优化已更新到日常 Mac，16 项相关测试及 7 条实际包流程通过。本地空目录 CPU 从 5.72% 降至 2.36%，缺失文件场景从 8.37% 降至 4.27%；实机仍在启动复核，完成后观察 30 分钟，尚未宣称达标。新版追加到搜索的 60 次实机验证也已排队，等待对应来源复核完成。旧记录查找不阻塞交付。详情见 `CHANGELOG.md`。

- [修复] 已移除空闲协调器的一次重复状态读取，真实校验次数从 128 降到 64，8 项回归通过，尚未部署。首轮扫描已完成，但稳态 CPU 仍超标，正在对照测量后继续修复；旧记录不阻塞交付。详情见 `CHANGELOG.md`。

- [验证] 当前包的重命名、采集器崩溃恢复、HQ 崩溃恢复 3 项测试通过；原始字节、身份和用量断言均保留。日常保活配置及同一进程已核实，资源观察仍待 3 个来源复核完成，详情见 `CHANGELOG.md`。

- [修复] Kimi 空文件重试修复已上线，7 项回归及 4 条实际包流程通过；同 6 个空文件从 54 秒各重试 20 次，降为 124 秒各 1 次，未误标采集成功。新进程资源观察继续，详情见 `CHANGELOG.md`。

- [排查] 6 个 Kimi 空文件在 54 秒内各重试 20 次，已定位到空内容分支；Cursor 正补最小修复和回归，尚未部署。旧记录查找不阻碍主线，详情见 `CHANGELOG.md`。

- [验证] 新包 60 次追加均最终可搜索，p95 48.6 秒、最慢 84.6 秒，62 条完整消息及双端原文通过；4 次 HTTP 错误仍保留，严格检查未通过。资源观察仍待 Claude 复核完成（已复核 1,102 个目录），详情见 `CHANGELOG.md`。

- [验证] 日常旧索引服务仍停用，App/设置哈希未变；新观察已记录 25 次搜索确认，Grok 复核完成，仅余 Claude（688 个目录已复核），详情见 `CHANGELOG.md`。

- [排查] 新包首轮观察在基线阶段因 HTTP 超时退出，尚未追加；480 次传输对照未复现。追加源复核完成后新观察基线及首条追加（29.3 秒）通过，资源观察仍跟踪原进程，详情见 `CHANGELOG.md`。

- [修复] 缺失源重试已收窄，189 项相关回归通过；新事件立即唤醒，分批采集和磁盘重试保持原节奏。4 条实际包流程也通过，日常采集器已更新；启动复核及新包资源/追加观察运行中，详情见 `CHANGELOG.md`。

- [验证] 60 次追加均搜索确认，p95 41.2 秒、最慢 53.4 秒，62 条完整消息及双端原文通过；5 次轮询超时仍保留为失败。完整 30 分钟 CPU 为 18.95%、采样最大内存 40.33 MiB，CPU 未达标；Cursor 正修复缺失文件的一秒重复重试，旧原文不阻碍交付，详情见 `CHANGELOG.md`。

- [验证] 日常旧索引服务仍停用，App/配置未变；原资源观察到等待上限退出，已接续相同目标的只读观察，未重启采集器。历史复核已完成 2,531 个目录，追加试运行继续，详情见 `CHANGELOG.md`。

- [修复] Cursor 已补齐首次检查和清理路径，126 项测试及两条实际包流程通过，HQ 已更新；新一轮基线全文及首条追加（约 12.25 秒）通过，完整试运行和资源观察继续。上轮 7 次成功、53 次取消的记录保留，详情见 `CHANGELOG.md`。

- [修复] Cursor 的索引正文检查修复已通过父审和 97 项测试，同样本工作量由 20,556 降至 139 步；两条实际包流程也通过，HQ 已更新并开始新一轮追加试运行。完整延迟与资源结果待测，旧原文不阻碍交付，详情见 `CHANGELOG.md`。

### 2026-09-12

- [排查] 追加完整试运行 54 次成功、4 次超时、2 次跳过，延迟未通过；续期正常，最终 60 条消息及双端原文通过。已定位索引更新前的全扫描，Cursor 正跑最小修复的回归，详情见 `CHANGELOG.md`。

- [验证] 首轮追加测试因脚本遗漏 15 分钟登录续期而中止，25 次成功、3 次 401，原失败记录保留。重新登录后完整 30 条消息和双端 94,208 字节原文通过；Cursor 修正已通过父审和离线检查，新一轮完整试运行已启动，资源观察继续。详情见 `CHANGELOG.md`。

- [验证] 追加试运行前 20 次全部成功；扫描仍需完成已排队的复核。日常 App/设置未变，旧索引服务仍停用，新 MCP helper 未打开旧状态库。完整资源和延迟结论仍待实测，详情见 `CHANGELOG.md`。

- [验证] 原扫描仍在前进，已完成 2093 个目录；只读观察继续跟踪，完成后自动测量 30 分钟。追加延迟脚本已由 Cursor 修正并通过父审，实机试运行已启动，基线全文通过，前两次追加约 14/17 秒可搜索；完整结果仍待采样。详情见 `CHANGELOG.md`。

- [优化] Web 搜索和总览优化已上线，最终 260 次读取全部成功；列表约 1 秒显示，搜索/总览 p95 为 646/1450 毫秒。采集器空轮询修复也已上线，217 项回归和 4 项实际包流程通过；当前仍重扫，30 分钟资源与追加延迟验收未完成。旧原文继续低优先级自查，无需提供备份。详情见 `CHANGELOG.md`。

- [优化] HQ 已新增 Web 列表索引，58 项元数据、17 项迁移和 2 项实际包检查通过；首访列表 532 毫秒返回，约 1 秒显示会话，完整 260 次读取中列表/详情/消息/总览全部成功，列表 p95 188 毫秒；搜索仍有 2/20 次 503。Collector 补传继续，旧记录仍不阻塞交付，详情见 `CHANGELOG.md`。

- [修复] Collector 的 10 秒观察间隔已上线，118 项回归、4 项实际包检查通过；重启补传窗口仍占单核 54.7%，尚未完成闲时验收。Web 首访错误处理已上线，70 项测试、2 项实际包及两种浏览器故障检查通过；正常首访仍收到两次后端 503，读取稳定性继续处理，详情见 `CHANGELOG.md`。

- [优化] Web 搜索改为从命中会话开始连接，57 项回归和 2 项实际包检查通过，HQ 已更新；混合读取完成 18 轮，第 19 轮仍有 503，首访失败也未解决。Collector 的 10 秒观察间隔已通过 118 项测试，打包中，详情见 `CHANGELOG.md`。

- [修复] Cursor 优化 Web 搜索并合并返回前校验，55 项回归和 2 项实际包流程通过，已更新 HQ；桌面/手机首访正常，连续测试第 7 轮搜索仍有 503，未标为全部解决。旧记录缺失继续低优先级自查，详情见 `CHANGELOG.md`。

- [修复] Cursor 减少重复观察扫描，116 项回归和 4 项实际包检查通过；现场发现重启仍依赖旧服务身份库，已独立保存同一机器身份并恢复补传，新包运行中。重启重扫期间 CPU 仍高，Web 列表/搜索仍有 503，继续定位，详情见 `CHANGELOG.md`。

- [排查] HQ 的另外 3 个 Cline 任务与缺失记录 ID 不同，Mimo 原路径也未匹配；旧原文继续低优先级自查，不再询问备份。已通过 Herdr 派 Cursor 修复重复目录扫描，详情见 `CHANGELOG.md`。

- [修复] HQ 总览不再提前统计下一页，48 项回归和 2 项实际包检查通过并上线；线上单页约 0.9–1.0 秒，完整页面约 4.3 秒。日常补传 CPU 约单核 24.5%，已定位 Cursor 重复目录扫描线索，继续处理资源开销，详情见 `CHANGELOG.md`。

- [修复] Web 总览已补齐分页并上线 HQ，59 项前端测试、2 项实际包流程通过；线上 9 页完整显示 17 个来源流，约 5 秒完成，桌面/手机画面正常。首轮浏览器曾超时，冷启动性能仍未验收，补传继续，详情见 `CHANGELOG.md`。

- [修复] Cursor 经 Herdr 修复总览读取已映射大正文，正确样本从 8,292 页降到 79 页，47 项回归和 2 项实际包检查通过并上线；首次总览仍超时，尚未完全解决。719 份恢复原文已全部采集，双端仍排队补传，详情见 `CHANGELOG.md`。

- [优化] Cursor 的两行总览查询优化已上线，45 项回归及 2 项实际包检查通过；后续访问约 262–437 毫秒，短间隔首访 1.804 秒，但重启首访仍超时，未宣称完全修复。恢复原文已采集 699/719 份，详情见 `CHANGELOG.md`。

- [切换] 日常旧索引服务已停用，App 已切为采集角色，9 个旧 MCP 退出、8 个父会话保留；Collector 与双端补传继续，旧库 60,379 条记录及回滚包保留且完整性检查通过。HQ 列表正常，总览连续两次超时正在排查，详情见 `CHANGELOG.md`。

- [验证] 30 分钟观察完成：HQ/M1 新确认 862/1,190 份，补传 CPU 平均单核 22.1%，内存峰值 122.5 MiB；五个来源的 97 条 Web 消息及 OpenCode 双端原文检查通过。旧库、App 和启动配置回滚备份已核验，切换须先停用旧 Service 自动拉起任务，详情见 `CHANGELOG.md`。

- [核对] Cursor 经 Herdr 复核退出条件：历史队列清零不是统一前提，各来源替代覆盖及 App/MCP 角色切换仍须完成。日常仍有旧服务和 9 个旧 MCP；719 份恢复原文中 445 份已采集，同一轮 30 分钟观察继续，详情见 `CHANGELOG.md`。

- [优化] Cursor 经 Herdr 将每端上传限为两份并行，110 项回归、2 项顺序测试、4 项实际包检查通过，日常采集器已更新。两轮实测确认量均高于基线；补传峰值内存约 211 MiB，后回落，尚非闲时验收。原文抽样核验通过，配置未变，详情见 `CHANGELOG.md`。

- [验证] 恢复进度检查改为批量只读查询，父审复跑 0.58 秒；719 份 Claude 原文中 401 份已采集，另 318 份均在待扫描目录内。采集模式 App 隔离检查通过，截图权限不足未验证画面；旧服务继续保留，详情见 `CHANGELOG.md`。

- [修复] Cursor 经 Herdr 完成 239 条历史误判修复，HQ 已部署；同类 240 条全部入库且 Web 详情可读，114 条探针仍跳过。42 项回归和 2 项实际包检查通过，原文及其他元数据校验未变；历史补传与旧服务收尾继续，详情见 `CHANGELOG.md`。

- [修复] Cursor 修正审阅关键词误把主会话判为 skip；19 项回归、2 项实际包检查通过，HQ 已加载修复。恢复的 156 条 Codex 会话共 181,600 条消息全文校验通过；同类误判另 239 条待修复，详情见 `CHANGELOG.md`。

- [恢复] Claude 旧记录已找回 722 份原文，其中 719 份约 1.87 GB 恢复至采集目录并逐份核验，另 3 份仅保留备份；补传入库仍在进行。Mimo/Cline 缺失记录低优先级自查，不再询问备份位置，详情见 `CHANGELOG.md`。

- [恢复] 再从 HQ/M1 找回 129 份 Codex 原文；原清单 156 条非 skip Codex 记录的原文已全部补齐并核验，共约 2.17 GB。三份归档 Web 16/16/3 条消息完整通过，大批次仍待入库，详情见 `CHANGELOG.md`。

- [恢复] Codex 样本原文双端核验、Web 9 条消息完整通过；另恢复 26 份约 412 MB 原文，三机副本核验通过、26 份已采集。HQ 又找到 268 条旧记录对应路径，身份和内容待核验，详情见 `CHANGELOG.md`。

- [恢复] 另补齐 129 份 Kimi 历史文件的三机副本；旧归档中两份 Claude/Codex 原文已核验并安全恢复，待采集接入后再扩大批次。旧服务继续保留，详情见 `CHANGELOG.md`。

- [恢复] 补齐 Codex 归档目录，两份原文共 230,237 字节双端核验通过，Web 23/3 条消息完整；日常 PID 32584、HQ 索引 PID 36446，程序包未变。另补齐 20 份暂缓原文与 244 份 Kimi 历史文件的三机恢复副本，详情见 `CHANGELOG.md`。

- [修复] Cursor 经 Herdr 修复 `<synthetic>` 占位模型误报来源冲突；106 项回归及 4 项实际包检查通过。日常 PID 22878，受影响 Minimax 原文 689,687 字节已双端核验，Web 99 条消息完整通过，详情见 `CHANGELOG.md`。

- [验证] 60 秒优先级对照未显示双端上传一致改善，已恢复后台策略，配置未变；Claude 已采集 22,051 个，剩余 8,141 个，继续补传，详情见 `CHANGELOG.md`。

- [验证] 30 分钟观察完成，Claude 新采集 2,209 个，HQ/M1 新确认 786/753 个；仍有约 1.4/1.5 万个待上传，旧服务继续保留。查询改动无实测收益，未采用，详情见 `CHANGELOG.md`。

- [验证] 新 App 正常模式隔离启动未打开旧库或启动服务；窗口显示仍未验证。日常仍有 12 个旧 MCP，最终切换须一并处理，当前均保留，详情见 `CHANGELOG.md`。

- [上线] 一行改动复用已验证的重复项目路径，104 项回归与 4 项实际包检查通过；日常采集器 PID 16485，Claude 已采集 19,617、待采集 10,575，进入 30 分钟只读观察，详情见 `CHANGELOG.md`。

- [上线] 采集与上传改用独立工作实例，7 项行为测试和 4 项实际包检查通过；日常采集器 PID 14584，旧服务保留。启动后 Claude 已采集 18,409、待采集 11,783，实机吞吐仍在观察，详情见 `CHANGELOG.md`。

- [验证] 旧服务退出所需的完整 App 候选通过 30 项角色测试及实际内置 MCP 隔离检查；已修正本地包签名启动问题，尚未安装或停旧服务。Claude 已采集 17,777，待采集 12,415；Cursor 正验证上传与采集分离，详情见 `CHANGELOG.md`。

- [上线] 两行路径类型提示减少重复文件查询，82 项存储测试和 4 项实际包检查通过；日常采集器 PID 11562，设置不变。Claude 已采集 16,169，待采集 14,023；继续运行观察，详情见 `CHANGELOG.md`。

- [上线] 旧 Cursor 同批工作区读取改为复用，60 项相关测试和 4 项实际包检查通过；日常采集器 PID 8912，已核对加载包。启动后 Claude 已采集 15,090，待采集 15,102，详情见 `CHANGELOG.md`。

- [进展] 日常采集器同包调至每轮 32 个文件，PID 6796；Claude 已采集 14,706，待采集 15,486。旧 Cursor 64 条已双端确认，读取复用优化仍在测试，详情见 `CHANGELOG.md`。

- [修复] 删除重复目录扫描循环，6 项运行回归及 4 项实际包检查通过；日常采集器 PID 6192，详情见 `CHANGELOG.md`。
- [完成] 三份约 799/677/513 MB 大记录均获得 HQ/M1 确认，六份服务端持久化回执已独立核对；普通历史补传及旧服务退出仍未完成。

- [调优] 日常同一采集包改为每轮访问 32 个目录项，PID 4031；约 80 秒新增采集 16 个，仍有 16,793 个待采集，三份 M1 大记录未确认；重复扫描循环留待精简，详情见 `CHANGELOG.md`。

- [上线] 中断恢复改为先筛选目标记录，大记录提交延长有限等待并跳过重复清单；155 项相关原生测试、10 项实际包检查通过，日常采集器 PID 2687，详情见 `CHANGELOG.md`。
- [进展] 卡住 Claude 的旧恢复任务已清除，已采集从 13,374 增至 13,375；三份 M1 大记录及全量补传仍待实机确认。

- [上线] Cursor 会话观察已只检查目标会话正文，45 项回归及 4 项实际包测试通过；日常采集器 PID 94843，详情见 `CHANGELOG.md`。
- [未完成] 全量补传和旧服务退出仍在主线；尚未宣称空闲资源验收或实机提速比例。

- [恢复] Kimi 同编号不同分片修复已上线；真实 1,853 条正文经 Web 39 页完整哈希核验，45 个原文件的 HQ/M1 副本均已逐块核验，详情见 `CHANGELOG.md`。
- [修复] Cursor 旧库已越过 4 条空记录，64 条非空记录全部采集，原先仅 15 条；其中 8 条有正文的会话、345 条消息已通过 Web 全文核验，无正文记录仍明确隔离。
- [验证] 57 项 Kimi、58 项旧库回归及 9 项实际包检查通过；当前四角色使用 kimi-legacy-20260912 包。
- [优先级] Mimo/Cline 由代理顺手自查，不再等用户提供路径；主线继续补传、采集效率及旧服务退出，Cursor 经 Herdr 修复重复扫描。

- [上线] 日常采集与双副本上传已独立推进；85 项回归和 7 项实际包测试通过，上线约一分钟 Claude 新增采集 64 个，详情见 `CHANGELOG.md`。
- [恢复] Web 已改回居中列表与独立阅读页，补齐返回和滚动位置；54 项测试及实网明暗、桌面/手机检查通过。
- [排查] Copilot 待处理已从 451 降至 397；Kimi 非空历史被两种同编号分片误拦，已确认文件不同，继续修复。

- [上线] 日常采集器已部署持续目录扫描、Copilot 跨批次主文件认领及重复数据块跳传；84 项回归和 7 项实际包测试通过，详情见 `CHANGELOG.md`。
- [恢复] 7 份 Pi 原文已双副本逐块核验；两条正常会话的 366/6 条 Web 正文完整通过，其余 5 条保留 skip。
- [修复] 工具调用前的 Web 空白气泡已修复上线，53 项脚本测试及真实手机页面通过。
- [未完成] Claude 最新仍有 22,896 个文件待采集；全量补传、缺失历史、Windsurf 可读性和旧服务退出继续处理。

- [上线] 日常采集器已更新目录发现修复并适度提高补传预算；287 项核心测试及 5 项真实进程测试通过，Pi 恢复链路继续实测，详情见 `CHANGELOG.md`。
- [保全] Windsurf 两份原始 PB（约 2.27 MB）已保存至日常/HQ/M1，哈希一致；尚未证明可在 Web 阅读。
- [修复中] Copilot 索引文件存在首选正文跨批次导致反复推迟的问题，已交 Cursor 按现有模式修复；全量覆盖及旧服务退出仍未完成。

- [保全] 22 份元数据不足的采集已保存至日常/HQ/M1，原始清单与数据块哈希一致；未冒充可搜索会话，详情见 `CHANGELOG.md`。
- [进展] 原受阻子集已 1521/1556 双副本确认；Claude 另有约 2.3 万个已发现文件待采集，仍须全量核对。
- [修复中] 新建目录触发整棵目录重扫已定位，Cursor 正补有界子树发现及回归测试，尚未上线；Mimo/Cline 另备份位置待用户补充。

- [修复] 采集端普通建目录事件改为有界子树发现，不再整根重扫；265 项 CollectorCore 测试通过，尚未打包上线，详情见 `CHANGELOG.md`。
- [未验证] 目录删除/迁出仍可能留下缺口；OpenCode 与 Cursor 旧库遇目录事件仍整根对齐；实机未重启。

- [上线] 旧 Web 的紧凑筛选、来源色、气泡及折叠预览已恢复；51 项测试和实网桌面/手机检查通过，详情见 `CHANGELOG.md`。
- [恢复] 找回 7 份 Pi 原文并核对 HQ/M1 副本，已恢复日常缺失目录；新采集发现延迟由 Cursor 排查。
- [进展] 原受阻采集已有 1433/1556 份双副本确认；Mimo/Cline 历史缺口、全量验收与旧服务退出未完成。

- [上线] 长消息自动续页已部署，真实 Grok 无需点击即显示 90 条消息；48 项测试及实网手机/桌面验证通过，详情见 `CHANGELOG.md`。
- [进展] 原 1556 份受阻采集中已有 1368 份双副本确认；旧 Web 体验对照、全历史覆盖及旧服务退出继续处理。

- [上线] 路径兼容、Grok 大历史与 Web 富文本/刷新恢复已更新；原 1556 份中 1534 份可上传，1212 份已有双副本确认，详情见 `CHANGELOG.md`。
- [验证] 284 MB Grok 归档双副本一致；395 条正文含 7 段真实压缩历史，经 30 页完整哈希校验；7 项实际包测试通过。
- [修复中] 实网发现长消息首屏须手动续页才显示，Cursor 正补自动读取；全历史覆盖与旧服务退出仍待完成。

- [上线] Cursor 无目录会话、Gemini 快照与 Copilot 长行修复已更新 HQ/日常 Mac；原 1556 份中 1525 份可上传，详情见 `CHANGELOG.md`。
- [验证] 三类真实采集双副本字节一致；Cursor 17 条、Copilot 263 条网页正文完整校验通过；Gemini 样本为 skip，未算正常搜索验收。
- [开发] 剩余 9 份路径误拦已复现修复，115 项测试通过；Web 富文本、刷新恢复登录及手机宽表格预览通过，45 项页面测试通过，待打包上线。
- [排查] 新发现一份约 284 MB Grok 原文已归档但被解析大小上限拒绝；Cursor 正补归档解析支持，详情见 `CHANGELOG.md`。

- [上线] HQ/日常 Mac 已更新；原 1556 条拦截中 1379 条规则验证可上传，已有 111 条双副本确认，剩余继续补传及排查，详情见 `CHANGELOG.md`。
- [验证] 三份真实 Pi 长行原文双副本字节一致；一份 Web 正文 208 条消息、8 页完整校验通过。

- [修复] Codex 明确分叉祖先不再误判身份冲突；Claude/Codex 的 `/` 工作目录仅在无排除项时允许归档，25 项元数据、74 项隐私测试通过，详情见 `CHANGELOG.md`。
- [修复] Pi 长消息暴露逐页脱敏过慢；9 MiB 无口令正文脱敏从约 1.6 秒降至约 0.04 秒，85 项正文/导出/总览测试通过；合并包两代链路已通过并上线，详情见 `CHANGELOG.md`。

- [上线] Grok 三机接入完成，三份真实会话双副本字节一致，网页完整读取 62 条消息并校验哈希；全量及实机压缩历史仍待核对，详情见 `CHANGELOG.md`。
- [修复] Grok 隐私检查改为逐块校验，128 MiB 夹具的额外内存峰值从约 256 MiB 降至约 160 KiB；72 项测试通过。
- [排查] 1556 条隐私拦截已按真实规则分类，877 条身份冲突、571 条路径无效、57 条限额、51 条元数据不足；不是项目排除，详情见 `CHANGELOG.md`。

- [验证] Pi 实网列表、详情和正文均返回 200；799 MB 堵塞任务已完成索引，详情见 `CHANGELOG.md`。
- [修复] Web 补齐 Pi/Grok 来源筛选，先红后绿，37 项测试通过；尚未上线。
- [开发] Grok 实际两代链路测试已补；Cursor 正验证压缩文件单独变化的增量发布，详情见 `CHANGELOG.md`。

- [修复] Pi 接收端允许列表遗漏已修复；55 项接收测试及实际两代链路通过，详情见 `CHANGELOG.md`。
- [上线] Pi 已接入日常采集及 HQ/M1 副本，实机根目录共 566 个日志；三份原文双副本逐字节一致，HQ 网页验证待完成。
- [修复] HQ 被 799 MB 历史的清单请求超时卡住；调整已有超时/传输配置后游标恢复推进，详情见 `CHANGELOG.md`。
- [验证] Grok 压缩历史原文采集 11 项测试通过；Cursor 正补解析、搜索与完整接入，尚未上线。

- [修复] 总览全文表重复扫描已修复上线；44 项总览、3 项实际包测试通过，首次就绪请求 795ms，随后 101ms，详情见 `CHANGELOG.md`。
- [验证] Cursor 的 Grok 文件集采集 6 项测试通过；尚未接入线上，完整历史仍需核对。
- [排查] 实际 Grok 压缩会话另有 118 段历史存于 segment 文件；Cursor 正补原文采集，详情见 `CHANGELOG.md`。
- [排查] 同口径未采集 Codex 日志从 225 降至 69 个，约 5.7 GB；旧索引继续保留。

- [上线] 旧 Web 紧凑导航、来源色、日期与明暗布局已补回；56 项原生、37 项页面和 3 项实际包测试通过，详情见 `CHANGELOG.md`。
- [修复] 已遮盖两条真实标题中的自然语言口令，原始归档不变；普通密码询问保留。
- [未验证] 首次总览仍复现 2 秒 503；全历史补齐、Grok/Pi 上线和旧索引退出继续处理。

- [修复] 总览统计误读正文溢出页已复现修复；41 项总览、5 项迁移/Pi 与 35 项页面测试通过，详情见 `CHANGELOG.md`。
- [上线] HQ 总览连续三次成功（916–1381ms），手机标题三行且保留全文，详情见 `CHANGELOG.md`。
- [未验证] 旧 Web 整体观感、Grok 接入、历史覆盖与旧索引退出继续处理；225 个现存 Codex 日志仍待采集。

- [上线] HQ 大历史与正文阅读修复已上线；日常采集预算升至 1 GiB，详情见 `CHANGELOG.md`。
- [验证] 三份真实大采集双副本逐字节一致；线上 13,558 条消息经 276 页完整读取，每条载荷哈希正确。
- [未验证] 总览仍有 503，手机长标题仍偏大；Pi/Grok、全历史覆盖和旧索引退出继续处理，Cursor 已交回 Pi 候选，待独立验收。

- [修复] 大历史分行存储与 Web 按页读取已实现，末页漏报已复现修复，详情见 `CHANGELOG.md`。
- [验证] 179 项存储/索引与 93 项 Web 测试通过；114 MB 双副本字节一致，10,001 条消息经 594 页完整读出，最终实际包 4 项测试已通过并部署。
- [修复] 长正文摘要从 53 秒降至 4.8 秒；9 项摘要、34 项页面及 8 项原生路由测试通过，已部署。
- [排查] Pi 的 223 个现存日志尚未接入；Grok/Mimo 旧路径缺失，仍需核对归档，详情见 `CHANGELOG.md`。

- [修复] 26 MB 长行读取从 42.5 秒降至约 0.26 秒；采集端长行限制和 HQ 大文件接入已补齐，详情见 `CHANGELOG.md`。
- [验证] 230 项解析、53 项 HQ 重放、91 项采集测试通过；HQ/日常 Mac 已更新，当时实机预算为 32 MiB，后续提升见上。
- [验证] Web 稳定后总览三次成功（548–1011ms），详情可读；两份 VSCode 日志双副本字节一致。
- [未验证] 启动初次总览仍有超时；当时大历史入库与按页读取仍待实现；后续验证见上，全历史完整性和旧索引退出尚未完成。

### 2026-09-11

- [修复] CommandCode 与恢复轮转已部署；44 份日志在 HQ/M1 逐份字节及哈希一致，Web 可读，详情见 `CHANGELOG.md`。
- [验证] 新 VSCode 采集拖延已复现修复，总览复核减少重复统计；129 项测试通过，两项修复尚未部署。
- [未验证] 大历史解析、入库及分页读取继续补齐；旧索引保留，完整覆盖和轻量运行尚未验收。

- [新增] 实机已扩展到 13 个采集根；12 条发布的 HQ/M1 字节及哈希抽样一致，详情见 `CHANGELOG.md`。
- [修复] HQ Web 登录过期提示已上线，31 项页面、8 项原生路由和实网过期/重新登录验证通过。
- [修复] CommandCode 无 cwd 的日志不再猜项目路径；无排除项时可归档，90 项隐私/元数据测试及本地双副本流程通过，尚未部署此修复。
- [未验证] 大文件/长行/长会话限制、VSCode 恢复预算疑似饿死及历史完整性仍待处理；旧索引保留，目标继续。

- [修复] Web 已复用旧版样式并更新 HQ：分栏、来源筛选、对话气泡、工具折叠和窄屏阅读完成，详情见 `CHANGELOG.md`。
- [修复] 总览重复扫描 FTS 的超时已复现并修复；总览失败也不再阻断列表加载。
- [验证] 26 项页面、48 项路由、39 项总览测试通过；实网 14 次请求成功，总览三次耗时 288–469ms。
- [未验证] 多 Claude 配置目录、其他来源及历史覆盖仍待接齐，日常 Mac 旧索引尚未退出；完整目标继续进行。

- [新增] Codex/Claude 新链路已常驻三机，浏览器可读真实会话；旧服务保留，完整角色切换尚未完成，详情见 `CHANGELOG.md`。
- [修复] 采集/上传来源轮转、未变文件免重采、新记录优先；620 项测试及实机双源同步通过。
- [验证] Claude 双副本字节抽样与网页详情通过；旧 1424 条 parsed 均为 skip，不是 FTS 积压。
- [未验证] 其他来源接入、全历史补齐及重启恢复待完成；Antigravity 继续后置。

- [修复] 后续源预算饿死已在预算 1 下复现并补轮转，617 项 CollectorCore 测试通过；未替换试运行包，详情见 `CHANGELOG.md`。

- [验证] 新版 30 分钟试运行已完成，四进程退出、临时 HTTPS 撤下、原服务保留，详情见 `CHANGELOG.md`。
- [验证] 双副本两条发布记录的字节抽样一致、真实浏览器登录/详情读取通过；HQ 接入改用已批准的 HTTPS 后推进，原配置保留。
- [未验证] 本次 CPU 采样均值 8.28%、Claude 未发布；Codex 双副本各 ACK 1618/1675，尚不支持切换。

- [修正] 试运行方案改为 HQ HTTPS8443、M1 HTTPS9443：Collector 拒绝远端 HTTP，M1 nginx 已占用 8443；保留现有服务，详情见 `CHANGELOG.md`。
- [计划] 配置模板已补齐，启动前必须复制新读取的有效隐私排除规则；新版两条映射方案仍待授权，未生成凭据或写入主机。

- [计划] 30 分钟真实主机试运行方案已就绪：日常 Mac 两类源、HQ 解析/Web、M1 副本，保留旧服务与 443 映射；等待本次主机写入授权，详情见 `CHANGELOG.md`。
- [验证] HQ/日常 Service 未发现隐私/禁用源环境覆盖；独立 HTTPS 8443 方案已记录，尚未启用。

- [验证] 新 Release Collector 从空存储初始化后，7 项实际包双副本/HQ 读取/恢复测试通过，包哈希不变、进程退出；三台安装预览已更新，详情见 `CHANGELOG.md`。
- [未验证] 真实主机身份、隐私和 TLS 配置仍待核对，尚未部署或切换旧服务。

- [新增] 首次采集身份初始化已接入独立命令；28 项 Swift 与 52 项实际 CLI 测试通过，不启动索引/采集，详情见 `CHANGELOG.md`。
- [未验证] 新包及新身份全链路尚待验证；真实 M1 未分配身份，部署前仍须核对其他既有身份路径。

- [排查] HQ/日常 Mac 默认采集身份目录存在，M1 该路径缺失；归档服务身份不可代替采集身份，已确认首次分配仍耦合本地归档 Service，Cursor 开始补显式初始化组件，详情见 `CHANGELOG.md`。
- [验证] HQ 安装预览已改用支持显式源登记的新包并通过干运行；真实主机尚未部署，隐私环境覆盖仍待核实。

- [验证] HQ 显式源登记完成：13 项组件测试及 6 项实际包集成测试通过，包含启动前无数据库的两代数据接入；包哈希一致、进程退出，详情见 `CHANGELOG.md`。
- [未验证] 真实主机配置与切换尚未执行，旧服务继续运行。

- [验证] 不预写 HQ 授权表的端到端测试已复现失败：收到 1 条发布，但源登记/epoch/会话均为 0；失败夹具保留，详情见 `CHANGELOG.md`。
- [开发] 已接入显式登记文件启动参数；组件与 index 角色限制仍待完成编译验证。

- [排查] 真实试运行准备发现 HQ 缺少生产源登记入口：现有集成测试预先写入授权表，不能据此宣称新安装流程完整，详情见 `CHANGELOG.md`。
- [计划] Cursor 正补受控初始登记组件与测试；父代理负责启动参数及不预写登记表的端到端验证，尚未部署。

- [验证] 新包本地 HTTPS 浏览器验收通过：登录 204、六次读取 200，三条消息与正反搜索正确；测试退出、夹具清理、包哈希一致，详情见 `CHANGELOG.md`。
- [未验证] 真实主机数据与轻量运行仍待验收，尚未切换旧服务。

- [验证] 实际角色包的 5 项双副本/HQ 读取/崩溃恢复测试通过，包哈希不变、测试进程已退出；三台主机隔离目标目录只读检查通过，详情见 `CHANGELOG.md`。
- [未验证] 浏览器页面和真实主机数据链路仍待验收，旧服务保持运行。

- [验证] 安装规划补齐反向目录边界，最终 19 项测试通过；六份安装预览重跑一致，详情见 `CHANGELOG.md`。

- [验证] 三种当前角色包及独立校验全部通过；175 项打包测试通过，六份禁用状态的安装预览已生成，详情见 `CHANGELOG.md`。
- [修复] 安装规划器误把用户主目录当作状态文件的问题已修复：先复现 2 项失败，再验证 17 项通过；真实主机尚未切换。

- [排查] 打包失败已定位到 GRDB 的 Swift Concurrency 相对依赖；系统共享缓存确认库存在，Cursor 正按失败测试修复复制产物的依赖名，详情见 `CHANGELOG.md`。

- [验证] 30 分钟复测及独立复算通过：CPU 1.733%、最高 RSS 19.02 MiB，1140 次请求和 3 次认证成功，8 个子进程已回收，详情见 `CHANGELOG.md`。
- [排查] 实际 Collector 打包遇到 Swift Concurrency 依赖校验失败，失败产物保留；Cursor 正定位，尚未部署。

- [修复] 打包准备脚本补齐每包未提交源码说明、构建进程检查及额外资源哈希；尚未执行打包，详情见 `CHANGELOG.md`。

- [排查] 已纠正部署审查中的额外阻塞判断：远端已有安装预览支持，M1 归档身份有既有认证记录；本地候选包保留真实未提交源码证据，详情见 `CHANGELOG.md`。

- [验证] 本轮性能验收前的打包拒绝检查通过，未创建产物；准备脚本会核对源码及二进制哈希，性能 exec95076 仍运行，详情见 `CHANGELOG.md`。

- [决策] 用户明确暂缓 Antigravity，不作为当前阶段阻塞项；保留现有数据与未应用草稿，回到轻量采集、HQ 索引、M1 副本和浏览器主线，详情见 `CHANGELOG.md`。

- [排查] Antigravity 实际缓存候选为 HQ 58 / 日常 Mac 58 / M1 0；CLI 候选 22 / 172 / 0，不能以 CLI 支持代替缓存覆盖，详情见 `CHANGELOG.md`。
- [未验证] 原始 `.pb` 候选仍需保全与解析核实；Windsurf 两份候选来自 2024 年，默认应用路径不存在。v4 性能复测继续。

- [排查] 三台 Windsurf 默认缓存均为空；日常 Mac 另有 2 个 `.pb` 候选文件，尚未读取内容或归档，不能以空缓存代表没有历史，详情见 `CHANGELOG.md`。
- [未验证] 日常 Mac 没有 Windsurf 进程或默认 daemon 目录；缓存草稿不能替代原始历史迁移。v4 三个 Release 构建通过，性能结果待完成。

- [修复] inventory 两处校验改用已有安全打开方法，保留全部身份与 SQLite 检查；609 项回归通过，详情见 `CHANGELOG.md`。
- [未验证] 新一轮相同负载复测已启动（exec95076），尚无结果；缓存补丁继续未应用。

- [排查] 第二轮诊断完整退出并清理，调用栈确认 inventory 逐层路径打开开销；Cursor 正做两处最小替换，仍待回归与完整复测，详情见 `CHANGELOG.md`。

- [验证] 完整复测 CPU 2.213% 仍超过 2%，RSS 21.33 MiB；1140 次请求、3 次认证成功，独立复算一致，详情见 `CHANGELOG.md`。
- [排查] 8 个子进程已回收；同产物诊断已启动（exec63482），Cursor 只读定位剩余开销。缓存隐私草稿已修正，仍未应用/编译。

- [排查] 缓存隐私实现草稿发现编译类型、上传前路径复核及格式校验缺口，已退回 Cursor 修正；补丁未应用，详情见 `CHANGELOG.md`。

- [验证] 缓存隐私测试草稿完成独立审查和应用预检，未应用/编译；746 个测量源码哈希一致，性能窗口继续，详情见 `CHANGELOG.md`。

- [验证] 旧缓存注册测试草稿完成审查与应用预检，仍未应用/编译；性能复测已进入稳态采样，746 个源码哈希未变，详情见 `CHANGELOG.md`。

- [修复] 已减少存活来源的重复注册，保留身份与存储校验；179 项回归通过，详情见 `CHANGELOG.md`。
- [未验证] 同负载 30 分钟复测已启动（exec28705），尚无结果；日常 Mac SSH 在线，仍运行 Service、未运行 Collector。

- [排查] CPU 调用栈出现每轮重复来源注册/激活及目录、数据库检查；诊断已完整退出并清理，详情见 `CHANGELOG.md`。
- [未验证] Cursor 正修改最小轮询路径并保留绑定/存储校验，尚需回归和同负载 30 分钟复测；旧缓存补丁继续未应用。

- [验证] 30 分钟资源验收失败：CPU 2.308% 超过 2% 目标，RSS 最大 20.44 MiB；1140 次请求和 3 次认证全部成功，独立复算一致，详情见 `CHANGELOG.md`。
- [排查] 8 个子进程已回收，失败夹具保留；已启动同产物 CPU 调用栈诊断，旧缓存补丁暂不应用，GOAL active。

- [验证] 旧缓存补丁完成静态审查，已拆分测试/实现且应用预检通过；源码哈希未变，尚未应用或编译，性能窗口继续，详情见 `CHANGELOG.md`。

- [排查] 旧 Windsurf 缓存身份来自元数据 ID，与 hook 文件名身份不同；Cursor 准备未应用补丁，测量结束后再运行真实测试，详情见 `CHANGELOG.md`。

- [排查] 已通过核实的 Tailscale 地址连接日常 Mac：仍为 local，Service 在运行、Collector 未运行；单点 CPU 31.6%、RSS 约 674 MiB，不能当作完整性能窗口，详情见 `CHANGELOG.md`。
- [未验证] 三台都缺 Windsurf 默认 transcript 目录；Cursor 正只读核对旧缓存历史的采集覆盖，30 分钟性能测试仍在运行。

- [验证] 三个 arm64 Release 构建通过，746 个源码文件保持一致；性能夹具双副本/HQ 的 256 份初始数据校验通过，已进入 30 分钟稳态采样，详情见 `CHANGELOG.md`。
- [排查] HQ/M1 归档认证接口均返回 200，身份/配置目录各自独立；最近变更遥测仍为 8 月 23 日，历史错误不能当成本次故障。
- [未验证] 日常 Mac 历史主机名无法解析；真实最新归档、恢复完整性与最终性能结果仍未验收，GOAL active。

- [验证] 重启会话后 Herdr/进程访问恢复，GOAL active；旧构建已无匹配进程，arm64 新构建启动，Cursor 经 Herdr 只读复核运行器。
- [验证] HQ/M1 实际 Tailscale 监听地址健康检查均返回 ok；完整归档与性能仍待验收，详情见 `CHANGELOG.md`。

- [未验证] 同一权限阻塞连续三轮，GOAL 已标记 blocked；恢复本会话 Herdr/进程访问后继续核对旧构建，完整目标未完成，详情见 `CHANGELOG.md`。

- [修复] 准备独立 arm64 性能运行器，保留旧尝试；架构、源码/产物稳定性与实际 PASS 结果均需满足，详情见 `CHANGELOG.md`。
- [未验证] 语法/计划检查通过；进程可见性预检因权限失败而拒绝启动，没有新增构建。恢复 Herdr/进程可见性后先核对旧任务终态。

- [排查] HQ/M1 只读清单已刷新：旧 Windsurf 缓存存在、默认 transcript 目录均不存在；M1 缺少设置文件，不能将默认值当成运行角色，详情见 `CHANGELOG.md`。
- [验证] daemon 边界扫描和启动配置静态验证通过；当前 Collector Release 构建成功，30 分钟性能验收尚未完成。
- [未验证] 权限切换后 Herdr 被拒、构建句柄失效；先核对现有进程终态再处理 arm64 测量配置，不重复启动构建，GOAL active。

- [新增] Windsurf独立二进制与浏览器整链通过：删除源目录后HQ仍可检索两代、展示四条消息及完整工具对象，详情见 `CHANGELOG.md`。
- [验证] 三个构建通过、测试1/0、8个产物哈希稳定；登录204、读取200、空搜索通过，控制台无错误，自有浏览器与夹具已回收。
- [未验证] 真实HQ/M1、来源历史/留存与日常Mac资源验收仍开放；Cursor经Herdr核对现有验收脚本，GOAL active。

- [新增] Windsurf常驻采集已向两个本地副本发布两代，源目录删除后可恢复未发布归档，详情见 `CHANGELOG.md`。
- [验证] Runtime3/0、Collector608/0、Service176/0；默认格式隐私拒绝0ACK，不创建本地产品索引。
- [未验证] Cursor经Herdr接续独立二进制测试；真实HQ/M1、资源与切换仍未验收，GOAL active。

- [新增] Windsurf隐私检查扫描完整归档的转义路径，路径只作排除规则证据，不推断工作区，详情见 `CHANGELOG.md`。
- [修复] 补上正文/标点路径遗漏和缺失末端的别名检查；增加路径深度上限；另修复混合file URI遗漏，最终Collector607/0。
- [未验证] 保守匹配可能误拒安全文本，真实数据与开销未验收；常驻发布、恢复和整链仍待接通，GOAL active。

- [新增] Windsurf专用归档已接HQ准入、回放、提交和全文检索；源删除后原始字节仍含规则元数据，详情见 `CHANGELOG.md`。
- [验证] Core617/0、副本54/0、Collector598/0、身份22/0、原生/parity14/0；伪造身份、错误根目录与损坏内容被拒绝。
- [未验证] 隐私证明和常驻采集仍未启用，Cursor经Herdr核对下一步；真实HQ/M1与资源验收仍开放，GOAL active。

- [新增] Windsurf官方嵌套JSONL可在源目录删除后回放，逻辑文件名保持会话身份，详情见 `CHANGELOG.md`。
- [修复] 工具步骤保留完整类型/状态/同级字段；失败复现13/2，修正后原生与parity14/0，畸形对象也计入数量预算。
- [未验证] 尚未启用Windsurf常驻采集；格式、隐私及HQ准入是下一步，真实机器与完整性验收仍开放。

- [验证] Antigravity 独立二进制重跑1/0、8个产物哈希稳定；浏览器四条消息和工具调用可见，登录204、读取200、控制台无错误，详情见 `CHANGELOG.md`。
- [排查] 首轮失败来自停止文件权限；成功重跑按300秒期限退出并回收夹具，空搜索证据仅来自首轮，未混算成单次全通过。
- [未验证] 真实HQ/M1、资源与切换验收仍未完成；Cursor经Herdr核对Windsurf接入边界，GOAL active。

### 2026-09-10

- [新增] Antigravity CLI 常驻采集已向两个独立本地副本发布两代；源目录删除后可恢复未发布归档，详情见 `CHANGELOG.md`。
- [修复] CLI捕获保留原始规范定位符，避免路径别名改变HQ身份；补齐Worker初始化来源入口。
- [验证] Core614/0、Collector598/0、Service173/0；覆盖默认格式隐私拒绝和恢复身份不变，独立二进制/浏览器及真实机器验收仍待完成，来源族仍15。

- [修复] Antigravity隐私检查识别JSON斜杠与Unicode转义目录，补上原始扫描可漏过排除规则的问题，详情见 `CHANGELOG.md`。
- [验证] 失败复现55/3；另修复转义目录重复计数的57/1复现，最终Collector597/0，覆盖跨块转义、代理对和目录预算。
- [未验证] Runtime候选接入点已记录，来源根消失后的稳定身份、常驻发布和完整整链仍待实现；来源族仍15、GOAL active。

- [新增] Antigravity CLI 已接通HQ/副本严格准入，源目录删除后仍可归档回放、提交并全文检索，详情见 `CHANGELOG.md`。
- [修复] 提交重新绑定日志目录身份，拒绝伪造解析ID；身份提取统一为纯路径字节校验。
- [验证] Core614/0、副本53/0、Collector594/0、投影22/0、原生/parity23/0；Runtime根身份与转义路径隐私仍待处理，来源族仍15、GOAL active。

- [修复] Antigravity CLI 身份与回放目录严格绑定；隐私检查遍历全部归档，补上50KB之后的排除目录遗漏，详情见 `CHANGELOG.md`。
- [验证] 隐私54/0、Collector594/0、投影22/0、原生/parity23/0；覆盖源删除、跨块路径/UTF8、损坏尾部和预算拒绝。
- [未验证] Runtime发布、HQ准入与整链尚待接通；真实来源/机器和资源验收仍未完成，来源族仍15、GOAL active。

- [新增] Antigravity brain 日志新增冻结文件回放入口；三种目录在删除源文件后保持原生身份、消息和工具语义，详情见 `CHANGELOG.md`。
- [验证] 独立验收修正了逻辑路径校验，最终原生/parity 23/0；采集隐私、HQ 路由和整链仍待接通，来源族仍15。
- [排查] Windsurf 官方文档提供完整会话 JSONL hook 导出线索；版本适用性、留存与历史补齐仍需验证，尚未安装 hook，GOAL active。

- [修复] HQ 旧代晚到/归档重试恢复后，以 `quarantine.obsolete_generation` 明确停止重试，保留原始归档，不覆盖当前解析/读取头；详情见 `CHANGELOG.md`。
- [验证] Worker 61/0、归档/摄入 Core 611/0、专用隔离主目录下 Runtime 13/0；已索引场景的消息、FTS 与索引任务保持不变，自有进程和临时主目录已收回。
- [未验证] Windsurf 原始 JSON 导出完整性仍在核对，不能假设 Markdown JSON 接口可用；Antigravity、真实机器/资源与 Release/CI/切换仍待完成，来源族仍15、GOAL active。

- [新增] VSCode 实际二进制与浏览器链路通过：原始输入全部删除后，HQ 从独立双副本解析两代、展示三条消息，本地合成来源族增至15；详情见 `CHANGELOG.md`。
- [修复] HQ 同秒入队按哈希排序会先解析新代、拒绝旧代；改为同时间按来源流/序号排序。Cursor 找出的旧测试预期已同步修正，最终 Worker 58/0。
- [验证] 三个 Debug 构建通过；二进制/浏览器各1/0、8个链接产物哈希稳定，浏览器与自有夹具已收回。
- [未验证] 跨时间乱序/延迟代处理仍待补齐；Windsurf 原生导出、Antigravity、真实机器/资源与 Release/CI/切换尚未完成，GOAL active。

- [新增] VSCode 已验证工作区/外部配置变化重采；未变化时只查文件元数据，侧文件不再独占采集队列。详情见 `CHANGELOG.md`。
- [验证] 删除源目录与外部配置后，Runtime 仍用冻结归档完成双副本发布；Service 170/0、Collector 589/0，无产品索引。
- [未验证] Cursor 正复核观察逻辑；新二进制、HQ 搜索与浏览器及真实机器/资源验收仍待完成，来源族仍14，GOAL active。

- [新增] VSCode 首轮常驻 Runtime 已发布日志与工作区原始字节到两个独立本地 HTTP 副本，重启复用已有归档；详情见 `CHANGELOG.md`。
- [验证] Service 169/0、Collector 586/0；未创建产品索引。旧 Cursor 所有权用例首次失败后整套重跑通过，首次原因仍未确定。
- [未验证] 工作区/外部配置变动重采、侧文件事件路由、源删除恢复、整体 I/O 预算及实际二进制/浏览器尚待完成，来源族仍14，GOAL active。

### 2026-09-09

- [新增] VSCode 有界文件观察与 schema 11 配置持久化已接通，删除源目录后可恢复预留并创建独立双副本发布义务；详情见 `CHANGELOG.md`。
- [验证] Collector 585/0、Worker 87/0；覆盖配置变化拒绝、损坏保留记录、旧回执迁移、事务回滚及 64 KiB 配置恢复。
- [未验证] Cursor 正只读复核；常驻采集、配置变动重采及实际二进制/浏览器链路尚待接通，完整来源族仍为14，GOAL active。

- [新增] VSCode 轻量身份投影与流式隐私检查已验证，工作区每个项目目录都核对排除规则；详情见 `CHANGELOG.md`。
- [修复] 快照预算计入冻结外部配置并拒绝溢出；失败复现 124 项/2 断言，最终 Collector 568/0，身份 20/0、隐私 49/0。
- [未验证] Cursor 正修正文件采集器的预算与路径绑定问题；持久化、常驻采集及完整链路未接通，完整来源族仍为14，GOAL active。

- [新增] VSCode 归档已接 HQ 原生回放、数据库写入和全文检索；删除整个原工作区后仍可查到消息，详情见 `CHANGELOG.md`。
- [修复] 补齐 HQ/副本准入并按原生日志大小校验；去掉上下文再降级 schema 的发布被拒绝。
- [验证] Archive/Ingest611/0、副本52/0、Collector562/0；Cursor 模型审查两项意见已逐项裁定并留证。
- [未验证] 常驻采集、隐私检查、真实双副本及二进制/浏览器链路仍待接通；来源族仍为14，GOAL active。


- [新增] VSCode schema 7 保存外部配置原始字节、路径、代次和摘要；配置缺失也显式记录，详情见 `CHANGELOG.md`。
- [修复] 采集时校验配置引用，并将外部配置计入字节预算；配置及源目录删除后可从 CAS 恢复上下文。
- [验证] Archive/Ingest606/0、Collector562/0；实际失败复现与编译错误均保留。
- [未验证] 有界外部文件采集、隐私检查、HQ 接入及完整链路仍待完成；来源族仍为14，GOAL active。


- [新增] VSCode 原生回放可使用冻结工作区与外部配置，源删除或暂存路径变化后仍保留身份、项目和消息；详情见 `CHANGELOG.md`。
- [验证] 失败复现19项/8断言失败，最终20项通过；覆盖原生路径优先级及缺失上下文不读取本机文件。
- [未验证] 归档上下文、常驻采集、HQ 接入及二进制/浏览器链路尚待接通；完整来源族仍为14，GOAL active。


- [新增] MiniMax/LobsterAI 已接通常驻采集、独立双副本、HQ 原生搜索及浏览器；同目录按真实来源分流，源目录删除后仍可恢复原归档。详情见 `CHANGELOG.md`。
- [验证] Collector 562/0、Service 167/0、Worker 87/0；两条二进制链路各 1/0，浏览器与临时进程已清理。MiniMax 验证脚本首次凭据填充错误的两次 401 已保留，修正后通过。
- [未验证] 本地合成来源链路覆盖 14 个族；VSCode/Windsurf/Antigravity、真实 profile/机器、资源和正式切换仍待完成，GOAL active。


- [新增] Collector schema 10 可在同一根目录保存不同来源的独立流；旧 UUID、epoch、序号和回执保持不变。详情见 `CHANGELOG.md`。
- [验证] Collector 562/0、Worker 81/0；真实 GRDB 覆盖源删除后恢复、发布/ACK 字节保留、历史来源不猜测及失败回滚。
- [未验证] 来源识别与采集分流尚未接入；MiniMax/LobsterAI 完整链路、真实机器、资源和切换验收继续推进，GOAL active。


- [新增] MiniMax/LobsterAI 的真实来源标签已获 HQ 和副本支持；源删除后仍可原生回放、写入与全文检索，相同会话 ID 保持独立。详情见 `CHANGELOG.md`。
- [验证] 最终 Archive/Ingest 598/0、副本 51/0，进程退出码均为 0；保留失败复现及路径夹具修正证据。
- [未验证] 共享目录的 Collector 来源分流与重启恢复仍待实现；完整本地来源数量保持 12，真实 HQ/M1、资源和切换验收未完成，GOAL active。


- [新增] Cline 已通过实际原生二进制的双副本、HQ 搜索与浏览器链路；详情见 `CHANGELOG.md`。
- [修复] 单文件预算下的主文件切换不再重复采集；采集中源文件消失会保留预留并重试，已存归档可在源删除后恢复发布。
- [验证] Collector560/0、replica49/0、Worker80/0、Service160/0、binary1/0；三次新构建通过，浏览器零错误/警告，临时进程和目录已清理。
- [未验证] 仍有五个来源族及实际配置、资源、真实 HQ/M1、Release/CI 和切换验收；混合异常事件与重扫读取预算继续保留，完整 GOAL active。

- [新增] Cline 的主文件选择、受限数组隐私检查和 HQ 原生回放基础已验证；详情见 `CHANGELOG.md`。
- [验证] Archive/Ingest 594/0、Collector 559/0、projection 17/0、Service 153/0；Cursor 经 Herdr 补测试，主代理独立执行。
- [未验证] Cline 实时采集、主文件切换恢复、双副本和浏览器链路尚未接通；来源覆盖数量不增加，完整 GOAL 继续 active。

- [新增] iFlow now reaches independent local replicas, HQ native parsing/FTS and rendered Web through fresh Swift binaries; exact messages, identity and positive usage verified. See `CHANGELOG.md`.
- [修复] Filled the replica source-admission gap found by Runtime RED153/1; whole Runtime unpublished-CAS restart also preserves original bytes/sequence/epoch after source removal.
- [验证] Core592/0, projection13/0, Collector551/0, Service153/0, replica49/0, binary1/0; eight linked artifacts stable, browser closed and successful fixture removed.
- [未验证] Remaining source/profile/resource coverage, Runtime native-stop/recapture races, Release/CI, M1 local identity and production cutover remain open. Full GOAL stays active.

- [修复] Modern Cursor stale-root observation no longer blocks saved-CAS recovery; bounded retries remove only confirmed-unavailable roots and preserve stored identity. See `CHANGELOG.md`.
- [验证] RED73/1; final Service151/0 and Collector550/0. Original reservations resume after source return; missing inventory still fails closed without uploads.
- [未验证] Whole Runtime restart/native-stop races, later recapture races, fresh binaries and real-host/source/resource/Release/CI/cutover gates remain open. Full GOAL stays active.

- [修复] Missing configured roots no longer block healthy startup; late roots bootstrap, and restart delivers pending archives without rebinding missing/replaced sources. See `CHANGELOG.md`.
- [验证] Behavioral RED147/1; Service148/0 and Collector550/0 passed. Herdr Cursor implemented Owner/Worker; parent independently verified Runtime and replica results.
- [未验证] Mid-cycle disappearance, whole Runtime saved-CAS restart, fresh binaries and real-host/Release/CI/cutover gates remain open; full GOAL stays active.

- [修复] Legacy prior-CAS comparisons now share a per-cycle read allowance; exhaustion resumes next cycle, and oversized optional comparisons do not starve current capture. See `CHANGELOG.md`.
- [修复] Actual binary validation found missing standalone Service framework search paths; project.yml and pinned XcodeGen output corrected, all three Debug products rebuilt.
- [验证] Collector550/0, Service146/0, legacy and modern binary chains1/0 each; eight linked artifacts stable. Rendered browser verified updated ownership, search and exact messages; fixture closed and removed. See `CHANGELOG.md`.
- [未验证] Natural source/profile/resource coverage, absent-root Runtime lifecycle, Release/CI, M1 local identity and production cutover remain open. Full GOAL stays active.

- [修复] Cursor legacy ownership/peer changes now trigger durable schema 9 rechecks; unchanged global main/WAL no longer prevent local Runtime recapture. See `CHANGELOG.md`.
- [验证] Final Collector550/0, Service144/0 and three key cases repeated three times (9/0); missing-source Worker recovery keeps original bytes and both replica ACKs. See `CHANGELOG.md`.
- [排查] Corrected layout-only legacy fixture, per-stream sequence selection and bounded asynchronous waits; failed evidence retained in the observer receipt.
- [未验证] Prior-CAS resource bounds, full absent-root Runtime lifecycle, fresh binaries/Web and real-host/Release/CI acceptance remain open. Full GOAL stays active.

- [新增] Cursor legacy now enters the actual Runtime paginated walk using one shared global snapshot per page; schema 8 records per-session capture IDs atomically. See `CHANGELOG.md`.
- [验证] Runtime RED141/1 retained; final Collector542/0 and Service142/0 passed. Two sessions resume across restart to both local HTTP replicas; forced re-scan after unrelated DB writes adds no publications. See `CHANGELOG.md`.
- [未验证] Ownership-only observation, modern peer removal/invalidation, prior-CAS resource bounds and fresh binaries/HQ/Web/real-host gates remain open. Full GOAL stays active.

- [新增] Explicit Cursor legacy roots/paired-root config now persist in schema 7; bootstrap and main/WAL event routing are covered. See `CHANGELOG.md`.
- [修复] Herdr Cursor implemented uncaptured retry; matching frozen bytes reach both local HTTP replicas, while changed ownership/source and budgets preserve recoverable work. See `CHANGELOG.md`.
- [验证] Collector536/0 and final Worker68/0 passed; Runtime45/replay27 passed in the earlier mixed run. Corrupt locator reload fails closed and retains work. See `CHANGELOG.md`.
- [未验证] Initial legacy walk, shared-page snapshot, modern-ID/content dedup, ownership-only observation, fresh binaries/HQ/Web and real-host gates remain open. Full GOAL stays active.

- [新增] Cursor legacy now has bounded ID pages, typed durable reservations and saved-CAS recovery to two local HTTP replicas. Herdr Cursor wH:p2 implemented discovery and reviewed parent integration. See `CHANGELOG.md`.
- [验证] Actual REDs retained; final Collector532/0 and Worker63/0 passed, with original bytes/sequence/epoch checked. See `CHANGELOG.md`.
- [未验证] Paired-root automatic discovery, scoped-content dedup, uncaptured retry, fresh binary/HQ/Web and real-host/resource gates remain open. Full GOAL stays active. See `CHANGELOG.md`.

- [修复] HQ continuation now admits Cursor legacy privacy proofs from verified captured CAS and frozen ownership; exclusion and resource limits remain enforced. See `CHANGELOG.md`.
- [验证] Actual RED 39/7; initial GREEN 39/0; expanded Collector 518/0 and PublicationWorker 62/0, exit 0, plus diff check. See `CHANGELOG.md`.
- [未验证] Herdr Cursor wH:p2 accepted the bounded change; discovery/revisions/retry/HTTP ACK and real-host gates remain open. See `CHANGELOG.md`.

- [新增] Cursor legacy schema 6 now binds typed bodies in CAS and enters HQ native replay/commit/FTS; native UTF-8 size remains distinct from raw and encoded sizes. See `CHANGELOG.md`.
- [验证] Final Core590, Collector514, Service133, native52 and replica48 passed; actual source-deleted Collector/CAS/HQ parity and independent local store reopen are covered. See `CHANGELOG.md`.
- [未验证] Legacy privacy/discovery/revisions/retry/runtime HTTP ACK, fresh binaries/Web and all-source real-host/resource/retirement gates remain open. Full goal stays active. See `CHANGELOG.md`.

- [新增] Cursor legacy now persists typed scoped rows and frozen cwd; CoreRead replays the saved body through native SQLite after source deletion. See `CHANGELOG.md`.
- [验证] Actual REDs retained; final Collector514, Archive/Ingest569, native52 and Service133 passed, including cross-module capture/replay and captured-path isolation. See `CHANGELOG.md`.
- [未验证] Legacy manifest/CAS/discovery/retry/dual ACK/FTS/Web/binaries, all-source real-host acceptance and authorized retirement remain open; full goal stays active. See `CHANGELOG.md`.

- [新增] Cursor legacy now freezes raw rows and unique workspace cwd from one global snapshot plus fenced workspace inputs; ambiguous/malformed proof stays withheld. See `CHANGELOG.md`.
- [修复] Actual RED closed UF_HIDDEN ownership and staging-inside-source mutation; final Collector513 and Service132 passed, exit0. See `CHANGELOG.md`.
- [未验证] Next: Cursor-specific durable representation/native parity, discovery/retry/dual ACK/HQ/Web, then all-source real-host acceptance; raw bytes and native size are distinct. See `CHANGELOG.md`.

- [新增] Cursor legacy now exports bounded, exact per-composer raw rows from private WAL-safe snapshots; frozen workspace ownership is still required before upload. See `CHANGELOG.md`.
- [修复] Actual REDs closed source-journal, UTF-16, generated ROWID and exact-output-budget gaps. Final Collector490 and Service132 passed, exit0. See `CHANGELOG.md`.
- [未验证] Next: frozen ownership, legacy discovery/retry/dual ACK/HQ/Web, then remaining profiles and real-host acceptance; total goal remains active. See `CHANGELOG.md`.

- [修复] Cursor modern now suppresses duplicate event work and repairs held-open WAL notification gaps with bounded stat-only known-dependency pages. See `CHANGELOG.md`.
- [验证] Actual REDs preserved; final Collector474, Service132, fresh native builds and CLI/binary35 (34 pass/1 existing skip) passed. Four publications settled at sequence7 with drained work. See `CHANGELOG.md`.
- [验证] Rendered Cursor login/search/detail/three messages/no-match passed; browser v2 exited0 with stable artifacts and owned cleanup. First0644 stop-file failure remains recorded. See `CHANGELOG.md`.
- [未验证] Legacy export/ownership, actual source profiles/hosts, new Release/CI/resource windows and authorized retirement remain open. See `CHANGELOG.md`.

- [新增] Cursor modern archives now replay and commit through HQ with native identity, metadata, time and payload-size parity; persisted-message FTS reaches index_ready. See `CHANGELOG.md`.
- [修复] Actual WAL replay failures led to private SHM initialization before sealing; existing byte/identity fences remain enforced. See `CHANGELOG.md`.
- [验证] Final Archive/Ingest560, Service129 and native Cursor52 passed, exit0; all RED receipts are linked in `CHANGELOG.md`.
- [未验证] Next: fresh Cursor binary/FTS/rendered-Web chain; legacy, remaining profiles, actual hosts and retirement remain open. See `CHANGELOG.md`.

- [新增] Cursor modern runtime now delivers four exact-byte generations to two independent local HTTP replicas, including WAL-only and stopped-runtime metadata updates. See `CHANGELOG.md`.
- [修复] Cursor uncaptured source loss now preserves retry work; durable unpublished captures recover original identity after source deletion/catalog reopen. See `CHANGELOG.md`.
- [验证] Actual recovery RED129/1; final Collector471, Service129 and replica47 passed, exit0. Grok tests/review independently checked. See `CHANGELOG.md`.
- [未验证] Next: Cursor HQ native replay/commit/FTS/Web and fresh binaries; legacy, real hosts, remaining profiles and retirement remain open. See `CHANGELOG.md`.

- [新增] Cursor modern reservations now survive DB/catalog reopen and source removal using the original captured generation; two durable replica intents remain pending. See `CHANGELOG.md`.
- [修复] Actual Unicode RED exposed wrong-version retry/recovery/abandon; Cursor UTF8 path checks now preserve the original reservation. See `CHANGELOG.md`.
- [验证] RED466/17, remaining466/1 and expanded102/6 reproduced; final Collector466 and Service124 passed, exit0. Grok review done575; all producers joined. See `CHANGELOG.md`.
- [未验证] Next: Cursor discovery/worker/runtime bridge, independent delivery and HQ/Web; legacy, actual hosts and retirement remain open. See `CHANGELOG.md`.

- [新增] Cursor privacy now reads verified captured main/WAL metadata only and binds recognized roots/current policy; default policy and HQ admission stay closed. See `CHANGELOG.md`.
- [修复] Reproduced CAS physical-path alias rejection and two-record budget bypass; preserved no-follow custody and enforced both metadata inputs. See `CHANGELOG.md`.
- [验证] Final Service124, Collector459 and Archive/Ingest553 passed, exit0; WAL-only CAS, forged member hash and PK/index schemas covered. Grok finding adjudicated; all producers joined. See `CHANGELOG.md`.
- [未验证] Next: durable reservations/restart with transcript-first primary, then independent replicas/HQ/Web; legacy, actual hosts, Release/CI and retirement remain open. See `CHANGELOG.md`.

- [新增] Cursor native metadata selection is shared with future collector privacy checks; losing roots and malformed/type evidence are retained without changing display. See `CHANGELOG.md`.
- [验证] RED12/60 reproduced; native/projection/index52, Service113 and Collector449 passed. Raw-history native6 passed after fixture-only corrections; Grok review done553. See `CHANGELOG.md`.
- [未验证] Captured-only SQLite reading and Cursor privacy/reservation/publication/HQ remain next. Raw history is not a byte-scrubbing guarantee; all real-host/retirement gates stay open. See `CHANGELOG.md`.

- [新增] Cursor sealed modern bytes now persist through existing schema 2/CAS with original provenance; five native cases replay reopened durable artifacts after source removal. See `CHANGELOG.md`.
- [验证] Archive RED77/10 and persistence RED5/5 reproduced; final Archive/Ingest553, Collector449 and Service112 passed, exit0. Grok review done545. See `CHANGELOG.md`.
- [未验证] Cursor privacy/reservations/replica delivery/HQ ingest remain next; legacy ownership/export and actual-host/Release/CI/retirement gates remain open. See `CHANGELOG.md`.

- [新增] Cursor modern capture preserves original main/WAL/meta/JSONL bytes; five native replay cases survive original-source removal. Legacy scoped export remains pending. See `CHANGELOG.md`.
- [修复] Actual REDs reproduced directory deadline and disappeared-payload classification gaps; final Collector449 and Service112 passed, exit0. See `CHANGELOG.md`.
- [未验证] Cursor sealed-member CAS/manifest work is active; privacy, durable publication, HQ/Web and all actual-host/retirement gates remain unverified. See `CHANGELOG.md`.

- [新增] Cursor now leases its observed store DB through shared private main/WAL custody; OpenCode reuses that physical path while its export/privacy SQL stays byte-identical. No live source SQLite opens. See `CHANGELOG.md`.
- [验证] Demonstrated initial and private-pair REDs; final focused70, full Collector438 and affected Service107 passed, actual exit0. Source removal, dependency drift, staging integrity and cleanup covered; Grok review done533. See `CHANGELOG.md`.
- [未验证] Cursor composite JSONL/meta capture, versioned transport/privacy, legacy row export/ownership and HQ/Web remain next; fresh binaries and all real-host/retirement gates remain open. See `CHANGELOG.md`.

- [新增] Cursor modern metadata discovery now pairs chats/projects and fences main/WAL/meta/transcript changes, missing members, ambiguous IDs and unsafe paths; native-hidden children stay excluded. See `CHANGELOG.md`.
- [验证] Discovery/hidden-directory and independent review issues have actual REDs; final full Collector421 passed, zero failures, exit0. Total-call budget, atomic CLOEXEC and native child-link skipping verified; explicit source boundary retained. See `CHANGELOG.md`.
- [未验证] Cursor private snapshots, modern/legacy capture and HQ/Web integration remain pending; no runtime upload or source retirement is enabled by discovery alone. See `CHANGELOG.md`.

- [验证] Fresh native Kimi Collector → independent replicas → HQ Service → FTS/Web passed three generations, including registry-only cwd change. CLI/binary 33 passed plus one opt-in skip; browser fixture passed; eight linked local hashes stayed stable. See `CHANGELOG.md`.
- [验证] Playwright checked login, Kimi search/detail, three messages, updated project and empty search; screenshot inspected. Initial wrong JSON credential produced401, corrected login/data requests succeeded. Owned browser and fixture are closed/removed. See `CHANGELOG.md`.
- [未验证] Local Kimi acceptance does not retire any real source: remaining families/profiles, distinct Codex runtimes, M1 identity, natural hosts, Release/CI and operational Web/resource gates remain open. See `CHANGELOG.md`.

- [新增] Kimi HQ registry/replay/commit now uses native captured inputs, frozen cwd/mtime and context-only size; registry-only versions update one stored session. See `CHANGELOG.md`.
- [修复] Reproduced and rejected wire-inclusive session size, consistent native-ID forgery and cwd drift from captured context. See `CHANGELOG.md`.
- [验证] Archive/Ingest plus native Kimi 563, affected Service 107 and final commit/FTS 63 passed. Real IndexJobRunner consumed saved messages without adapters; FTS found the expected session after original inputs were removed. See `CHANGELOG.md`.
- [未验证] Fresh native binary chain, rendered Kimi Web, actual hosts/profiles/identity, Release/CI and retirement remain open. The full goal stays active. See `CHANGELOG.md`.

### 2026-09-08

- [新增] Kimi Runtime now captures primary/shard/wire and registry-only changes, applies captured-input privacy, and uploads schema 5 to independent replicas; source/registry removal no longer blocks policy reauthorization of captured data. See `CHANGELOG.md`.
- [验证] Full Collector 404, affected Service 103, replica store 45 and routes 13 passed; all xcodebuild producers exited 0. Runtime tests checked both replicas byte-for-byte and restart recovery; registry paging survives DB reopen. See `CHANGELOG.md`.
- [修复] Reproduced and fixed uncaptured Kimi recovery blocking after missing inputs; dirty work retries, while already durable captures preserve the original publication sequence. See `CHANGELOG.md`.
- [未验证] Kimi HQ ingest/commit/FTS/Web remains next. Real-host/profile/identity, fresh binaries, Release/CI and retirement gates stay open; the full goal remains active. See `CHANGELOG.md`.

- [新增] Kimi schema 5 now binds scoped cwd to immutable capture and durable reservation identity; registry-only changes cannot overwrite an older reservation. See `CHANGELOG.md`.
- [验证] Archive/Ingest 543, full Collector 399 and Service affected classes 98 passed. DB reopen/source removal/CAS completion, migration, corruption and rollback are covered; native replay uses persisted manifest context. See `CHANGELOG.md`.
- [未验证] Kimi dirty observation scheduling, privacy, dual-replica transport and HQ/FTS/Web wiring remain next; real-host/Release/CI/retirement gates stay open. See `CHANGELOG.md`.

- [新增] Kimi now has bounded context/shard/wire observation and per-session cwd projection; shared registry rows and unnecessary sibling session IDs stay out of the projection. See `CHANGELOG.md`.
- [验证] Two reproduced registry defects fixed; full Collector 392 passed. Native Kimi CAS replay after original source/registry removal passed both wire and no-wire cases with full metadata/message parity. See `CHANGELOG.md`.
- [未验证] Kimi provenance is not yet in the transport/reservation schema; Runtime, HQ commit and real-host replacement remain open. The full multi-host/source objective stays active. See `CHANGELOG.md`.

- [验证] Rebuilt OpenCode Collector → independent local replicas → HQ Service → FTS/Web IPC passed for two WAL-only generations; CLI/binary suite: 32 passed, one opt-in Codex browser hold skipped. All 8 linked local artifacts stayed unchanged. See `CHANGELOG.md`.

- [验证] Actual OpenCode HTTPS browser login/search/detail and three-message rendering passed; no-match search and console checks passed. Screenshot: `output/playwright/opencode-native-web.png`. Temporary browser/processes were joined and fixture removed. See `CHANGELOG.md`.

- [未验证] Full actual-source/profile coverage, M1-local identity, real-host natural input, Release/CI, production TLS and retirement remain open; local process/browser gates supersede only earlier OpenCode gaps. See `CHANGELOG.md`.

- [新增] OpenCode HQ registry, staged native replay and payload-size commit are connected; captured IDs are bound at commit and dispatched children remain skip. This supersedes the earlier HQ-placeholder notes below. See `CHANGELOG.md`.

- [验证] Archive/Ingest plus native OpenCode regression 553 passed; actual Collector snapshot → CAS → HQ replay after original DB deletion passed with all 3 Service replay tests. Identity-rebinding RED was reproduced and fixed. See `CHANGELOG.md`.

- [未验证] Rebuilt native process chain, OpenCode FTS/Web proof and all real-host/full-source/retirement gates remain open. See `CHANGELOG.md`.

- [新增] OpenCode Runtime now delivers bounded session images to independent local HTTP replicas; restart, source removal, WAL-only input and CAS recovery are verified. This supersedes the earlier unwired Runtime/privacy notes below. See `CHANGELOG.md`.

- [修复] Reproduced one-day privacy retry delay after policy change; persisted policy SHA now requeues pending privacy-withheld records while preserving transport backoff. Final Runtime/worker 93 and full Collector 379 passed after the fix. See `CHANGELOG.md`.

- [未验证] HQ OpenCode registry/replay/commit, native binary chain, full actual-source coverage and real-host retirement remain open. See `CHANGELOG.md`.

- [新增] OpenCode inventory now commits each session publication with its cursor atomically, preserves unfinished database work across restart/WAL changes, and migrates legacy reservations to schema 4. Runtime wiring remains open. See `CHANGELOG.md`.

- [验证] Collector 373, publication worker 52, Archive/Ingest 527 and replica store/routes 44+13 passed; local HQ/M1 store fixtures preserve schema-4 images and provenance. This is not real-host delivery or HQ parsing. See `CHANGELOG.md`.

- [新增] OpenCode private leases now reuse one fenced DB/WAL snapshot across bounded session pages; SQLite opens only staged files. Schema-4 image CAS preserves real provenance and idempotent recovery. See `CHANGELOG.md`.

- [验证] Archive/Ingest 527, full Collector 363 and native replay 2 passed, including CAS reconstruction after source removal. Multi-session durable publication, privacy and HQ admission remain open. See `CHANGELOG.md`.

- [新增] OpenCode schema-4 scoped SQLite image provenance passes model 33 and Archive/Ingest 523; real DB/WAL stats remain distinct from derived image bytes. See `CHANGELOG.md`.

- [验证] Scoped OpenCode export passed full Collector 353 and native adapter parity after original-source removal; typed raw rows, WAL/offline paths and isolation are covered. Runtime/CAS/privacy/HQ integration remains open with an executed admission RED. See `CHANGELOG.md`.

- [修复] Gemini HQ commit now preserves native transcript-size semantics; actual capture/replay/commit RED is fixed and Archive/Ingest 519 passed. See `CHANGELOG.md`.

- [验证] Both rebuilt Gemini binary chains passed: auxiliary-only changes reached independent local HQ/M1 replicas and HQ FTS/Web IPC; all eight linked artifacts stayed unchanged. Final Collector 333 and Runtime/worker 88 passed. This supersedes the earlier incomplete local checkpoints below. See `CHANGELOG.md`.

- [未验证] Remaining enabled DB/composite/cache sources, M1-local identity, real-host natural input, current Release/CI, rendered Web and retirement remain open. See `CHANGELOG.md`.

- [验证] Gemini full Collector 333, Runtime 36 and Archive/CaptureIngest 517 passed; new observer paging/restart and unused-registry recovery REDs remain under repair. See `CHANGELOG.md`.

- [新增] Gemini schema-3 project-scoped provenance and native HQ replay are implemented locally; Core 145 and replica storage/routes 43+13 passed. Shared registry bytes are not uploaded. See `CHANGELOG.md`.

- [排查] Independent Collector/Runtime REDs exposed final-ID, registry fencing/observation, authority retention and privacy gaps; Cursor is repairing the bounded Collector paths. Gemini binary and real-host acceptance remain open. See `CHANGELOG.md`.

- [新增] Copilot now has native composite HQ replay, per-member replica integrity, snapshot-bound recovery and stat-only Collector discovery with budgeted primary selection. See `CHANGELOG.md`.

- [验证] Copilot HQ 70, Remote 54, Collector 327 and Runtime/worker 73 passed; three Debug builds and both two-generation binary chains passed. Single-checkpoint skip behavior was preserved; eight linked artifact hashes stayed unchanged. Real-host coverage remains open. See `CHANGELOG.md`.

- [新增] Declared schema-2 file sets preserve exact auxiliary bytes and absence; physical-path and directory-FD defects have executed RED/GREEN. Native Gemini/Copilot enablement remains open. See `CHANGELOG.md`.

- [验证] Foundation 54 passed; broader Core 501, Collector 320, Remote 51 and Runtime/worker 64 passed. Two new Copilot auxiliary-only acceptance tests are RED at configuration admission; they have not reached recovery/upload. See `CHANGELOG.md`.

- [新增] Qoder and CommandCode now pass native Collector → independent HQ/M1 → HQ index/Web IPC for two synthetic generations, preserving native identity, cwd, time and usage. See `CHANGELOG.md`.

- [验证] Core 146, Collector 320, Remote 51, Runtime/worker 64 passed; three Debug builds passed; CLI/shadow 27 passed/one opt-in skip. Two additional binary cases passed with all eight local linked artifacts unchanged. Real-host rollout and composite sources remain open. See `CHANGELOG.md`.

- [新增] Qwen now passes native Collector → independent HQ/M1 → HQ index/Web IPC for two synthetic generations; captured timestamp fallback preserves original mtime. See `CHANGELOG.md`.

- [验证] Collector 316; affected Core 134; later HQ registry 36; Remote publication 49; Runtime/worker 61 passed. Three Debug builds passed; native CLI/shadow 25 passed/one opt-in skip. Real-source rollout and remaining sources are still open. See `CHANGELOG.md`.

- [新增] Native `--initialize` and Grok-authored custom-Claude profile mapping are implemented locally; full enabled-source collection/HQ/Web rollout remains active. See `CHANGELOG.md`.

- [验证] CollectorCore 311 passed; affected Service classes 83 passed/one opt-in skip; native CLI/package/planner 125 passed. Initialization replacement race has deterministic RED/GREEN; final review and real-host acceptance remain pending. See `CHANGELOG.md`.

- [验证] Same-ten HQ/M1 snapshot replay passed: nine exact-byte dual ACKs, four visible/956 verified Web messages, and 30-minute Collector mean CPU 1.36% / max sampled RSS 19.59 MiB. All trial roles stopped; old processes retained. See `CHANGELOG.md`.

- [排查] Timestamp-preserving seed transfer triggers HQ preflight ctime rejection; byte-exclusive seed creation enables the bounded replay without relaxing guards. General cold-start compatibility and earlier local directory-impact uncertainty remain open. Old/new parser full-byte parity resolves the legacy-count oracle mismatch. See `CHANGELOG.md`.

### 2026-09-07

- [排查] Scoped metadata review found no incident-window timestamp in 274 current Claude/Qoder/CommandCode directories; effects remain UNKNOWN without a prior baseline. See CHANGELOG and the private impact receipt.

- [修复] Grok-authored default-Claude multi-root ALL-pass proof/revalidation is locally verified: Collector 305 passed; Service 1,153 passed/5 opt-in skips; parity 4 passed; three Debug builds passed. Raw bytes, first project and other-source restrictions remain. See `CHANGELOG.md`.

- [未验证] First full-suite process HOME was not isolated and entered directory maintenance; possible source-directory rename effects remain unverified. Final isolated suite passed. Original HQ exit 70 and same-ten real replay remain open. See `CHANGELOG.md` and `output/hq-claude-multiroot-fix-20260907/summary.json`.

- [排查] Grok's multi-root proposal was source-reviewed: assess and revalidate every recognized cwd with bounded local proof storage; product patch pending. Three local empty-source CLI starts passed, leaving the earlier HQ exit 70 unexplained. See `CHANGELOG.md` and `output/hq-claude-remediation-design-20260907/reviewed-plan.md`.

- [验证] HQ/M1 authorized real-data snapshot shadow is NOT_READY: 10 files/26.10 MB, four exact-byte dual ACKs; five multi-root and one incomplete-metadata capture withheld, three parsed sessions remain skip and one has no visible messages. Trial processes stopped; old services retained. Multi-root compatibility and the unexplained first CLI startup failure remain open. See `CHANGELOG.md` and `output/hq-claude-shadow-20260907-0900/summary.json`.

- [验证] `c8a9cdc4` completed the unchanged 30-minute synthetic window: CPU 1.6484%, peak RSS 24.09 MiB, all latency/auth/content gates passed and eight children joined; exact product-head CI passed. Prior CPU failures remain preserved; this is not tailnet evidence. See `CHANGELOG.md`.

- [新增] Synthetic Claude two-generation real-binary replay passed after two retained fixture-only corrections; full Service 1,156 tests/5 skips/zero failures and independent review passed. Product/profile unchanged; real host/source roots and bounded shadow authority still required. See `CHANGELOG.md`.

- [修复] Two storage revalidation routes passed strict RED→GREEN (76 opens to 8); CollectorCore 295/295, Service 1,155 tests (5 skips) and independent safety review passed. Ancestor/DB/fence checks remain; new 30-minute Release acceptance is pending. See `CHANGELOG.md`.

- [排查] Synthetic 120-second hold and bounded external sample completed with joined cleanup; storage-path validation is the next TDD candidate. Diagnostic-only, not acceptance; both CPU failures remain. See `CHANGELOG.md`.

- [验证] `87cc453c` Tests/CodeQL passed, but the second full 30-minute Release window still fails CPU (2.121%); all other metrics and final content passed. Evidence retained; dedicated synthetic profiling is next. See `CHANGELOG.md`.

- [修复] Drained claims avoid writes with bounded indexed probes; RED retained, CollectorCore 289/289 and Service 1,154 tests (4 skips) passed with independent approval. Thresholds stay unchanged; new Release CPU measurement is pending. See `CHANGELOG.md`.

- [验证] Final-tier oracle RED→GREEN; 33 focused and 1,154 Service tests passed (4 skips). Real late-200 browser check and `70e362fa` Tests CI passed; CPU gate, host-source inventory and healthy-tailnet evidence remain open. See `CHANGELOG.md`.

- [验证] 完整 30 分钟实测未过：CPU 2.145% 超 2%，RSS/追加/Web 延迟达标；4 会话正常升 premium 暴露最终计数断言错误，失败证据保留。CI 的 Service 私有 HOME 缺项已 RED→40/40 并独立批准，新 CI 与迟到 200 浏览器检查仍待验，详见 `CHANGELOG.md`。

- [修复] CI 平台修正本机 279/279（零跳过）、格式/类型检查通过，产品与测量包哈希未变；新 Linux CI 仍待验。性能稳态继续，W5 尚需补真实迟到 200 读取不重绘的浏览器证据，详见 `CHANGELOG.md`。

- [提交] `9e90471b` 已推送原 Draft PR；三角色可溯源 Release 包验证/只读安装计划通过，256 文件 bootstrap 后进入 30 分钟稳态。Linux CI 暴露 13 项工具平台边界，新增 CI 合同已 RED，仅修测试与工具保障，产品冻结，详见 `CHANGELOG.md`。

- [验证] 显式三原生二进制的完整 Service 共 1148 项、4 跳过、零失败；CLI 与 rename/crash 实跑，固定版本暂存工程漂移通过，准备 57 路径源码提交。干净 revision 包、长性能及新 CI 仍未完成，详见 `CHANGELOG.md`。

- [验证] 原生浏览器登录/退出竞态已过：新 cookie 被后续 DELETE 使用并在服务端撤销，退出后两种读取均 401；窄屏三消息已目视。57 路径源码集成门通过，全 Service 回归、干净 revision 包、长性能与新 CI 仍待验，详见 `CHANGELOG.md`。

- [修复] 六维独立审查发现 Web 登录/退出 cookie 乱序，先 3 FAIL 再串行队列 16/16 并独立关闭；TLS 短探针区分回调缺失与端口假设，修正后 15/15、正确 pin 502/错误 pin 拒绝均实证。真实浏览器重验与 30 分钟性能仍待完成，详见 `CHANGELOG.md`。

- [修复] 模板父目录 alias 已最小修复并独立通过，168 项全过；显式原生全脚本 598 项通过/2 既有跳过，lint/typecheck/build/knip/安全与不变量通过。TLS-only 复现和 W6 六维审查继续，旧 HEAD CI 不代表当前候选通过，详见 `CHANGELOG.md`。

- [验证] 三角色原生安装计划与 Collector/Service wrapper dry-run 通过且未写目标；模板 164 项通过后独立发现父目录 alias 漏检，新增 4 项已 RED。首轮长测在 TLS 证书验证处失败、稳态样本为 0，已汇合自有进程并保留证据；33 项恢复/认证回归已过，详见 `CHANGELOG.md`。

- [验证] 安装 dry-run/CI 合同合计 53 项通过，Remote 原生计划未写目标；新恢复两项 fixture 失败已定位修正待复跑，长测认证 TTL 缺口已先 RED，未改产品 TTL。角色模板与实际性能仍待验，详见 `CHANGELOG.md`。

- [验证] 三角色原生诊断包独立 verify-only 与安全加载探针通过，包快照不变、未启动服务；17 来源退休清单已补，真实主机全为未验证。零 revision 测试包不是部署制品，启动模板/故障/性能/新 CI 仍待验，详见 `CHANGELOG.md`。

- [修复] 真实浏览器发现多词查询空格变加号，单行客户端修正后 12/12 及原生 HTTPS 两项整链通过；三角色清单漏验分别 RED→Service 68、Collector/Remote 73 全过。性能统计 13 项已过但实测/故障/原生包/新 CI 未完成，详见 `CHANGELOG.md`。

- [验证] Collector/Service/Remote Release 构建均退出 0；Core 1737 项（1 既有跳过）与 App 1175 项零失败。Service 打包 59 项虽全过，独立审查仍发现嵌套清单漏验；浏览器正在执行，原生包/性能/新 CI 未过门，详见 `CHANGELOG.md`。

- [验证] 真实 Collector→双 Remote→HQ Service→Web IPC 两代链已过，保留字节/消息前缀与 normal 分层；Service/CLI 29 项、MCP 270 项、TLS helper 31 项通过。两次前序失败为 fixture 缺字段/单消息 skip；完整 browser、故障/性能/原生包及 CI 仍待验，详见 `CHANGELOG.md`。

- [验证] Service 显式 HOME/凭据文件入口完成 RED→11/11 GREEN，生产增量独立批准；全 Service 1124 项（1 既有跳过）零失败，原生 Service 构建通过。真实二进制启动/整链与 TLS 仍待验，详见 `CHANGELOG.md`。

- [验证] 原生CLI生命周期/双代双ACK已过，Worker磁盘状态34/34、Runtime透传18/18、CLI状态JSON15/15独立批准；包30项及提取后Collector282项通过，Service安全入口与真实整链仍在TDD，详见 `CHANGELOG.md`。

- [验证] Collector全套282/282、后台循环16/16、Service全套1093项（1既有跳过）及CLI参数/OFF 41项通过；真实CLI正向与打包剩余绕过仍在TDD，磁盘状态/完整W3–W6未完成，详见 `CHANGELOG.md`。

- [验证] Service Runner启动异常修复已独立批准，13/13通过；Collector冷WAL与双ACK重启13/13、打包真实布局21/21通过，后台错误恢复、真实CLI/包及完整W3–W6仍待验，详见 `CHANGELOG.md`。

### 2026-09-06

- [验证] publication31/31、CAS29/29、catalog关闭2/2及真实Service Runner链11/11已过；独立审查仍阻断启动异常清理，Collector冷WAL启动6/12失败，打包真实GRDB布局待修，详见 `CHANGELOG.md`。

- [验证] 消费器23/23、FD采集15/15、Service运行时真实handler链10/10通过；Collector原28项过、新预算与父目录丢失复现/打包symlink门待修，Runner与完整W3–W6仍未完成，详见 `CHANGELOG.md`。

- [修复] 中央消费器跨轮恢复已22/22 GREEN；独立审阅另发现 parser revision 字节比较围栏缺口，追加单项复现中，尚未最终批准，详见 `CHANGELOG.md`。

- [验证] `92c7e3cf` 三项 CI 已过；中央消费器原19项通过、新3项跨轮恢复真实RED待修，Web脚本9/9、长文合成链退出0；迟到200浏览器竞态与完整W3–W6仍待验，详见 `CHANGELOG.md`。

- [新增] 合成采集→真实归档 ACK→中央 replay/FTS→HTTP/IPC→Web 正文链已接通；中央 Service 1009过/1既有跳过、Collector279/279、Remote398/398。仍非完整 W3–W6 二进制验收，详见 `CHANGELOG.md`。
- [排查] 首次全Service命令未隔离 Foundation home，已停止；真实源是否受影响未验证。修正后先验真实XCTest home再全量通过，未做生产补救或扩大扫描，详见 `CHANGELOG.md`。

- [验证] A5d追加App/Core共2901项（1既有跳过、零失败）及MCP270/270通过，独立最终门进行中。T4a真实RED暴露12项围栏缺口，另11项测试观测/顺序已独立裁决修正，GREEN执行中，详见 `CHANGELOG.md`。

- [验证] A5d中央Service935过/1既有跳过/零失败，脚本205过/2条件跳过及类型/安全门通过；最终集成门与新CI待验。T4a57项回归执行中，旧head CodeQL仍待验，详见 `CHANGELOG.md`。

- [验证] `9b969a9c` Tests/依赖已过，CodeQL待验；A5d donor全Service过门、三文件按哈希整合后中央回归中。N4a修正额外连接复用断言后279/279，T4a新增12项草案过门待RED；均非完整运行验收，详见 `CHANGELOG.md`。

- [提交] CI 修正已推送 `9b969a9c`，新依赖过、Tests/CodeQL待验；A5d定向23/23通过、全Service运行中。N4a 276/279，三项定位为替换main后的旧连接复用；T4a新增围栏回归草案中，均未整合，详见 `CHANGELOG.md`。

- [验证] CI 单点修正五路径最终独立双门已过，逆向字节比较确认仅 `self.records`，准备正常修正提交推送；新head 16.4 CI仍待验，不夹带 donor 功能，详见 `CHANGELOG.md`。

- [修复] `010a2c5d` Swift CI 在 Xcode16.4 编译测试辅助类时失败；独立门批准仅补 `self.records`，38项测试体与生产代码不变。中央 Service 912过/1既有跳过/零失败；修正最终门及新head CI待验。A5d 23项真实RED后仅扩展实现，详见 `CHANGELOG.md`。

- [提交] A5c 已正常推送 `010a2c5d`，PR #446 仍 Draft/未合并，新三 CI 待验。T4a 45 项与 N4a 新24项真实 RED 已确认，仅各自源文件进入 GREEN；N4a 旧255全过。A5d 23项草案过门、RED运行中，详见 `CHANGELOG.md`。

- [验证] A5c 七路径最终独立双门与暂存漂移已过，冻结哈希未变；旧 head 三 CI 再核全过，准备正常提交推送，新 head CI 待验。T4a 前轮混有夹具错误，仅修夹具重跑 RED，未开实现，详见 `CHANGELOG.md`。

- [验证] A5c 独立双门后按原哈希整合：中央 Service 912 过/1 既有跳过/零失败，1 条 reader QoS 警告；脚本205过/2条件跳过及类型/安全门通过，最终暂存门与新CI待验。T4a进入45项RED，N4a/A5d仅测试草案，详见 `CHANGELOG.md`。

- [验证] A5c 修正 NUL 夹具并补快照关闭顺序真实 RED 后，38/38 GREEN、原 SQLite 重复关闭日志消失；完整 Service/独立门待验。T4a 二稿继续校正，N4a 合同过门后仅开测试草案，详见 `CHANGELOG.md`。

- [验证] `843d0038` 三项 CI 全过，PR #446 仍 Draft/未合并；A5c 首轮编译类型修正后运行 GREEN v2，37 项测试未变，T4a 初稿独立门未过并继续校正，详见 `CHANGELOG.md`。

- [验证] `843d0038` Tests/依赖已过，CodeQL 待验；T4a 修订合同经独立双门后冻结，仅开两个文件的 TEST-DRAFT，A5c 仍仅源码 GREEN、37 项测试冻结，详见 `CHANGELOG.md`。

- [验证] A5c 校正后的 37 项草稿经独立门并实际 RED：5 过/32 失败、零 skip/运行时警告；首次仅缺旧 donor CAS 基线导致编译失败，已按中央哈希同步并单列。现仅 producer 源码进入 GREEN，测试冻结，详见 `CHANGELOG.md`。
- [提交] N3-B2 已正常推送 `843d0038`，PR #446 仍 Draft/未合并；新依赖 CI 通过、Tests/CodeQL 运行中。A5c 继续测试草稿，T4a 单项领取/重放/parsed 原子提交仍为待审方案，无 job 的 skip 就绪另留 T4b，详见 `CHANGELOG.md`。
- [验证] N3-B2 十路径最终独立双门及暂存漂移已过，六个实现/路由哈希未变，准备正常提交推送；记录中的数字 producer 是命令会话编号而非 OS PID，已追加澄清，新 head CI 仍单独待验，详见 `CHANGELOG.md`。
- [验证] `18c9bc06` 三项 CI 全过；N3-B2 补充独立门后按冻结哈希进入中央，完整 Collector 255/255、脚本 205/2 条件 skip 与类型/安全/invariants 通过，保留 1 条烟测 QoS 警告。十路径最终门与新 head CI 待验，A5c 继续测试草稿校正，详见 `CHANGELOG.md`。
- [验证] `18c9bc06` Tests/依赖 CI 已过，CodeQL 待验；N3-B2 donor 254/254 和真实临时目录烟测 1/1、合并 255/255 通过，保留前两次夹具失败与 QoS 警告，补充独立门及中央整合待验。A5c 测试草稿九组修正中，详见 `CHANGELOG.md`。
- [验证] `6a33a42a` 三项 CI 全过后已推送 A5b `18c9bc06`，新依赖 CI 通过、Tests/CodeQL 待验；N3-B2 旧 196 全过／新 58 真实 RED，现仅源文件进入 GREEN。A5c 验收冻结并准备测试草案，仍未完成 W3–W6，详见 `CHANGELOG.md`。
- [验证] A5b 九路径最终整合/记录独立双门与暂存漂移通过；`6a33a42a` Tests/依赖 CI 已过、CodeQL 仍运行，下一次推送等待其通过。原生监听新增负计数补测尚待 RED，Service producer 仍仅方案，详见 `CHANGELOG.md`。
- [验证] T3b 已推送 `6a33a42a`，依赖 CI 通过、Tests/CodeQL 待验；A5b HTTP 补丁经独立双门按四哈希整合，donor 定向 68/68、donor/中央完整 Remote 各 391/391。Service producer、浏览器与完整 W3–W6 仍未完成，详见 `CHANGELOG.md`。
- [验证] T3b 十路径最终整合及记录/索引独立双门通过，原四哈希未变、暂存漂移 v2 通过，准备按授权提交推送；新 head CI 单独待验，详见 `CHANGELOG.md`。
- [验证] `5073f3f8` 三项 CI 全过；T3b App 旧调用文本扫描单行校正后全量 2,901（含 Core、1 既有 skip）零失败，MCP 270/270，保留 11 条 QoS 警告。十路径最终整合门及新提交 CI 待验，Web/原生监听草稿均未混入，详见 `CHANGELOG.md`。
- [验证] N3-B1 已推送 `5073f3f8`，Tests/依赖 CI 通过、CodeQL 待验；T3b 补充双门后按四文件哈希整合，中央 Core 1,726、Service 875（各 1 既有 skip）零失败，App/MCP 与最终整合门待验。Web 新 13 项真实 RED、旧 49 全过，两个预算补测仍待 RED，完整 W3–W6 未完成，详见 `CHANGELOG.md`。
- [验证] `8a53174b` 三项 CI 全过；N3-B1 独立实现门通过，按哈希整合后中央 Collector 196/196，脚本 205/2 条件 skip 与类型/安全/invariants 通过，暂存漂移与整合终门待验。T3b sibling 权威缺口另有 4 项真实 RED，继续 donor 修复，不混入本批，详见 `CHANGELOG.md`。
- [验证] `8a53174b` Tests/依赖已通过，CodeQL remote 仍待验；N3-B1 donor 全量 196/196，独立实现门待验。T3b 原 35 GREEN 后又用 3 项真实 RED 复现写中撤权与 history 缺失零延迟待办，最小修复复测中；A5b 草稿补验收，未整合、未部署，详见 `CHANGELOG.md`。
- [提交] `5995ad66` 三项 CI 全绿后，A5a/N3-A 九文件独立终门通过并推送 `8a53174b`；新 head 依赖通过、Tests/CodeQL 待验。N3-B1 仅 donor 测试草稿过门并获 RED 授权，T3b 草稿审阅中，完整 W3–W6 仍未完成，详见 `CHANGELOG.md`。
- [验证] `5995ad66` 的 Tests/Swift unit/UI smoke 已全过，CI Xcode 16.4 下 readiness 38/38、Core 1,681（1 既有 skip）零失败；Swift CodeQL 仍待验，功能提交继续等待其独立门，详见 `CHANGELOG.md`。
- [验证] CI 单行修正独立终门后已推送 `5995ad66`，新 head 依赖通过、Tests/CodeQL 待验；A5a/N3-A 五文件仍未提交，六套本地完整门零失败，等待功能整合终门及修正 head 全绿后再推送，未合并或部署，详见 `CHANGELOG.md`。
- [验证] 单行夹具注解修正后完整 Core 1,681 项／1 既有 skip／零失败，38 测试体与夹具字节未变；准备仅修正＋四记录的独立整合门及提交，Xcode 16.4 新 head CI 仍待验，A5/N3 五文件继续排除，详见 `CHANGELOG.md`。
- [修复] `f683ff71` 的 Swift unit/UI smoke 同在 Xcode 16.4 编译夹具时失败；独立双门批准仅补 `messages` 显式数组类型，38 测试体与生产代码不动，修后完整 Core/新 head CI 待验。A5/N3 本地完整组合门已过，但五文件明确排除本次 CI 修正提交，详见 `CHANGELOG.md`。
- [验证] T3a 已推送 `f683ff71`，依赖 CI 通过、Tests/CodeQL 待验；A5a 与 N3-A 独立双门后按五文件哈希整合，中央 Remote 372/372 零失败/跳过，Service 开跑，其他组合门仍待验。FSEvents/FTS consumer 仅方案准备，完整 W3–W6 未完成，详见 `CHANGELOG.md`。
- [验证] T3a 八路径暂存哈希与工程漂移通过，旧 head `4216479b` 三项 CI 全过，准备授权提交；Web 完整 Remote 372/372 待独立实现门，N3 修夹具后旧 156 全过／新 13 真实 RED，现仅 Owner 允许 GREEN，详见 `CHANGELOG.md`。
- [验证] T3a 八路径中央整合／记录独立双门通过，开始暂存固定版工程漂移门；旧 head CodeQL 与新 head CI 仍待验，未合并或部署，详见 `CHANGELOG.md`。
- [验证] Web A5a 真实 RED 49 项／27 失败用例后，测试冻结下 DTO/client 首次 GREEN 49/49；完整 Remote 与独立实现门待验，仍 donor-only。N3 草案双门通过，仅授权可执行 RED，详见 `CHANGELOG.md`。
- [验证] T3a 中央 Core 1,681、Service 875（各 1 既有 skip）、App 1,175、MCP 270 全部零失败，脚本 205/2 条件 skip 与 typecheck/安全/invariants 通过；最终整合门、旧 head CodeQL 和新 head CI 仍待验。Web 草案双门后首次 RED 开跑，N3 仅测试骨架，详见 `CHANGELOG.md`。
- [提交] N2 已推送 `4216479b`，PR #446 仍 Draft，依赖 CI 通过、Tests/CodeQL 运行中；T3a 独立实现双门后按三文件哈希整合，中央完整 Core 开跑，其他组合门待验；Web/N3 仍仅测试骨架，详见 `CHANGELOG.md`。
- [验证] N2 十文件最终整合／记录双门与暂存工程漂移通过，准备授权提交推送；T3a 仅在 donor 过 129 项实测，独立实现门进行中，新 head CI 与完整 W3–W6 仍待验，详见 `CHANGELOG.md`。
- [验证] N2 独立门后按哈希整合，中央 Collector 156/156、脚本 205/2 条件 skip、typecheck/安全/invariants 通过；`e94c0500` 三项 CI 全过。T3a 修正两处单消息 skip 夹具后 donor 129/129，独立实现门待验且不混入 N2；完整 W3–W6 未完成，详见 `CHANGELOG.md`。
- [验证] N2 donor 完整 156/156 零失败／跳过，前两次特殊临时路径夹具失败保留；只修夹具，独立门／整合待验。T3a 新增 34 项测试草稿、实现仍为桩；`e94c0500` Tests／依赖通过，Swift CodeQL 待验，详见 `CHANGELOG.md`。
- [提交] T2 已推送 `e94c0500`，Draft PR #446 未合并，新三项 CI 已启动；N2 未跑 GREEN，T3/Web 额度中断草稿均隔离保留，完整 W3–W6 仍推进中，详见 `CHANGELOG.md`。
- [验证] T2 九文件暂存候选通过最终整合／记录双门；旧 head `9fd6db26` 三项 CI 全通过（CodeQL Gate 10:33:35），准备授权提交推送，新 head CI 待验，N2/T3/Web 草稿不在候选中，详见 `CHANGELOG.md`。
- [验证] T2 过独立双门并按四文件哈希整合；中央 Core 1,643（1 skip）、Service 875（1 skip）、App 1,175、MCP 270 零失败，脚本 205/2 条件 skip；旧 head CodeQL product 仍待验，T3/Web 线程额度中断草稿与 N2 均未混入，详见 `CHANGELOG.md`。
- [验证] `9fd6db26` Tests/依赖检查通过，CodeQL 仍运行；T2 有界历史 GREEN 91/0 待独立门，N2 原 155 项与补充 firmlink 单项均取得真实 RED，现仅允许最小 GREEN；首版 Web 正文要求 metadata/parsed/ready 同代，未知观测不填健康，详见 `CHANGELOG.md`。
- [验证] N1＋A4 已提交推送 `9fd6db26`，PR #446 仍 Draft，新三项 CI 运行中；提交后漂移测试 10/10（含原 2 条件 skip）；T2 有界历史 2 项新测试待 RED、N2 骨架准备均未混入，详见 `CHANGELOG.md`。
- [验证] N1＋A4 十一文件候选通过组合双门和暂存哈希／固定版工程漂移门；中央 Collector 126、Remote 341 全过，脚本 205/2 条件 skip，准备提交推送，新 head CI 待验；T2/N2 未混入，详见 `CHANGELOG.md`。
- [验证] A4 独立双门通过并按哈希整合，中央 Remote 341/0；T2 donor 89/0，版本计算的全历史内存展开正补 RED 后收敛，暂未整合；现候选 archive safety/typecheck/五项 invariant 通过，详见 `CHANGELOG.md`。
- [验证] `1523487b` 三项 CI 全通过；N1 独立双门通过并按哈希整合，中央 Collector 126/0；A4 donor 完整 Remote 341/0，独立门/整合待验；T2 89 项 GREEN 正运行，N2 仅测试骨架，未部署，详见 `CHANGELOG.md`。
- [验证] N1 donor 完整 Collector 126/0，独立门/中央整合待验；真实 HTTP 定向 49/0，完整 341 仅既有 firmlink 测试 home 选址报错，正换工作树内隔离 home 重跑。T2 修正 fixture 后 45 项真实 RED，旧 44 全过，GREEN 实现中，详见 `CHANGELOG.md`。
- [验证] `1523487b` 已推送，Tests/依赖检查通过，09:19 CST CodeQL 仍在运行；N1 donor 完整 Collector 124 取得真实 RED，另独立复现旧 owner Unicode 字节栅栏绕过，GREEN/真实 HTTP/T2 仍在推进，未部署，详见 `CHANGELOG.md`。
- [验证] POSIX/T1/Web auth 已整合，六套中央完整门 Core 1,596、Service 875（各 1 既有 skip）、App 1,175、MCP 270、Collector 108、Remote 292 全部零失败；最终脚本 205/2 条件 skip，跨片双门和暂存哈希复核通过，旧 head `09de6304` 三项 CI 全通过，准备提交/新 head CI 待验；N1/T2/真实 HTTP 下一片只在 donor 写 RED，未部署，详见 `CHANGELOG.md`。
- [验证] 入口取消修复独立双门通过并整合，中央 Collector 108/0；T1 整合后的完整 Core 1,596、Service 875（各 1 既有 skip）零失败，App/其他组合门和 Web 独立门仍在推进，详见 `CHANGELOG.md`。
- [验证] `09de6304` 已推送，Tests/依赖检查通过、Swift CodeQL 待验；POSIX 中央 107/0，入口取消真实 RED 后 donor 108/0；T1 抢占 44/0 加并发连续 20 次通过并过独立门，Web auth donor 45/0，后续整合/真实接线与 W3–W6 未完成，详见 `CHANGELOG.md`。
- [验证] 本轮六套完整整合门零失败：Core 1,566、Service 875（各 1 既有 skip）、App 1,175、MCP 270、Remote 247、Collector 74；路径字节身份缺口真实 RED→GREEN 并过独立门，脚本 205/2 条件 skip，新 head CI 待验，W3–W6 未完成，详见 `CHANGELOG.md`。
- [验证] Replay5 经独立双门通过并按五文件 SHA 整合，完整 Core 1,566（1 既有性能 skip）零失败；Web logout 窄例外 RED→GREEN、安全脚本 49/49、十套脚本 203/2 条件 skip，其他组合门/HTTP 实现/新 head CI 待验，详见 `CHANGELOG.md`。
- [验证] `1660734` 的 Tests、CodeQL、依赖检查全部通过，PR #446 仍为 Draft；下一批已整合 inventory、Web IPC、bounded CAS 和 pure builder，中央定向门 68/31/127 零失败，完整组合门与新 head CI 尚待执行，详见 `CHANGELOG.md`。
- [设计] 真实 Chrome 同源 GET 不携带 Origin，已据官方规则修订为固定 API header 加严格 Fetch Metadata 缺省分支；存在但无效的 Origin 不得降级。仅设计与合成浏览器验证，HTTP/完整 ingest/双副本/W6 仍未完成，未部署，详见 `CHANGELOG.md`。
- [修复] `745de11d` 的 CI 仅 macOS 脚本门失败；旧 fixture 改为明确握手，另以 TERM/INT/HUP 三条真实 RED 证明并修复 Popen 返回前的锁释放窗口。HQ 12/12、信号组连续 12 轮、脚本 195/195、typecheck/Biome 及独立双门均通过；修正 head CI 待验，原 CI 调度窗口未归因，未修改已部署脚本，详见 `CHANGELOG.md`。
- [验证] 本批完整整合门全部通过：Core 1,521、App 1,175、Service 858、MCP 270、Remote 247、Collector 35 零失败（Core/Service 各 1 既有 skip），190 项脚本、invariants、fixture 和独立交叉门通过；准备提交推送，新 SHA CI 待验，inventory/replay/实际 Web IPC 尚在独立树，未部署，详见 `CHANGELOG.md`。
- [验证] C1 隐私/身份源及 typed Web client 已按冻结哈希整合，worker Collector 35、Core 定向 273、client 18 均零失败并过独立门；中央完整 Service 858（1 既有 skip）零失败。Remote 全套的既有 firmlink 测试环境问题仍在复验，完整 replay/HTTP/W3–W6 尚未完成，未部署，详见 `CHANGELOG.md`。

### 2026-09-05

- [验证] W4 源/epoch/解析格式 registry 已整合（worker 72/0、Grok 独立双门通过）；全文续传 14 项通过；可选 AI 解耦补获退出锁滞留真实 RED，最小 cancel/join 后 11/0 并过独立门，完整整合回归和新 head CI 待验，仍非完整 replay/Web，详见 `CHANGELOG.md`。
- [验证] 基础提交 `248e64ab` 在 Draft PR #446 的 Tests、CodeQL Gate 和依赖检查全部通过，CollectorCore 已实际进入必需 CI；后续 registry、隐私证明、全文续传及可选 AI 解耦仍在本地 TDD/整合中，不继承旧 SHA 的 CI 结论，未合并或部署，详见 `CHANGELOG.md`。
- [验证] W2 `874a63f1` 已通过全部必需 CI；角色/采集核心、共享 IPC、首片身份与 intake ledger 已本地整合，Core 1,482、Service 833（各 1 既有 skip）、App 1,175、MCP 270、Collector 9、Remote 229 均零失败，独立交叉门通过且补入 Collector CI，本波 CI 待验；完整 collector、中央 replay/Web 链未完成，未部署，详见 `CHANGELOG.md`。
- [验证] W2 默认关闭的 publication/ACK 接收端已通过独立完整 Remote 回归 229/229、零失败/跳过，包含真实子进程重启恢复与旧 archive/recovery/MCP；模型与存储最终只读门 PASS/APPROVED，本波 PR CI 待验。W3 角色/采集核心与 Web IPC 基础在独立工作树推进，未部署，详见 `CHANGELOG.md`。
- [验证] Draft PR #446 的 W1 修正 head `638a8454` 已通过 Tests、CodeQL Gate 和依赖审查；Core/App/Service/MCP/Remote 与 14 项 UI smoke 均零失败，本地 Node 1,564/1,564；完整 UI 不属于此次 PR 门。W2 接收入库继续推进，W3 角色隔离在独立工作树开发，未合并或部署，详见 `CHANGELOG.md`。
- [提交] W1 已提交推送 `52fcc86e` 并建 Draft PR #446；CI 抓到新增 invariant 的符号反引号违反文件锚点约定，已复现并仅修文档，本地完整脚本门 135/135；待新 head CI 通过后继续 W2，未合并或部署，详见 `CHANGELOG.md`。
- [设计] 新工作树已写完整 collector→HQ 索引/Web→独立双副本的七波实施顺序；Grok 经 Herdr 审出的 7 组合同缺口已修订并通过复核（PASS/APPROVED），W2 接收协议与 W3/W4 接口冻结；详见 `CHANGELOG.md` 及其链接设计/计划。
- [修复] 第一波本地完成 embedding 热查询与“App 不拥有已 adopted 的外部 Service”；查询真实 VM-step RED→GREEN，启动器含退出后迟到探测竞态，未更改生产实例。
- [验证] 两切片独立 spec/quality 门通过；Core 1,452（1 既有性能 skip）/0 失败，launcher 56/0 失败；新 collector、服务器接收协议、HQ ingest、Web 和生产切换尚未完成，不能据此宣称本机已轻量化。
- [提交] #444 已正常合并至 `81ee3a1d`；main 完整 CI 全绿，UI 61 项/2 既有 skip/0 失败，截图 31/31；PR 与 resulting-main CodeQL 均已通过。
- [部署] 1569 签名包安装复验通过；HQ 新 Service 已完成初扫（约 2 分 17 秒），post-scan 状态与两条 pending 队列验收通过。M1/HQ RemoteServer 与新构建二进制相同，保留健康实例，不重复部署。
- [部署] 本机旧 Service 等待近 30 分钟后，按继续收尾确认、复核 PID/路径/备份后仅强制结束旧 PID；launchd 已自动拉起 1569，哈希/socket/MCP/live DB quick_check 通过，Live 阶段推进后复验返回 87 会话/14 秒；初扫完成与 post-scan 同步状态未冒报。
- [验证] HQ 直连恢复后，watchdog 13:21/23/25/27 连续自然周期正常、无 degraded sentinel；此前 exit 255 保留为历史失败，详见 `CHANGELOG.md`。
- [修复] 真机验收定位到初扫逐 session 重扫 FTS 的热点；生产 SQL 仅改 2 行，确定性 VM-step 回归先 RED 后 GREEN，focused 110/110、独立 Core 1,450（1 skip）通过。无新依赖/索引/配置，待新包部署；1566 尚不含此修复。
- [部署] #443 已正常合并至 `dfc988b7`；产品代码与签名 build 1566 的 `2b31a40a` 完全相同，不为测试/文档变更重复构建。M1/HQ RemoteServer 已切换并通过实际路径、哈希、健康和鉴权验证。
- [部署] 两端旧 Service 均正常退出，未强杀；日用 App/HQ Service 已运行 1566 对应的新 helper，Live 分别 2.0s/0.7s，MCP 均 27 tools。数据库备份已校验，watchdog 恢复并通过自然周期。
- [验证] resulting-main 完整 CI 已通过：UI 61 项、2 项既有 skip、0 失败，31 张截图全通过；签名安装包复验通过，main 与此前两次 CodeQL 均已通过。
- [未完成] 12:07 CST 首次扫描仍在推进，post-scan 同步状态尚未验收；脱敏日志中的会话解析失败尚未归因。两项可选 Node 工具链上游公告仍无兼容修复，详见 `CHANGELOG.md`。
- [修复] #441/#442 已合并；完整 UI 剩余空结果断言改用 fixture 中零匹配的 HQ-only 筛选，未改产品逻辑。
- [验证] 逐张核对并刷新 8 张过期基线，31 张 CI 截图重放全部通过，阈值未放宽；新一轮完整 CI 与部署验证仍待完成，详见 `CHANGELOG.md`。

### 2026-09-02（2026-09-04 复验）

- [修复] 已按当前源码裁决完成四份清单中全部 115 个确认 ID（109 个实现簇），覆盖 High/Medium/Low 等全部确认问题；rejected、duplicate-only、stale 行保持排除，完整目录与分包证据见 `CHANGELOG.md` 和 `.grok/all-confirmed-remediation-ledger-2026-09-02.md`。
- [验证] 2026-09-04 Node build/typecheck/knip/coverage 全绿（130 files / 1,561 tests），lint exit 0，Engram 2,588（1 skip）；2026-09-02 final-source 独立门为 Core 1,449（1 skip）、MCP 265、Service 833（1 skip）、Remote 161，RemoteServer executable Debug link、adapter parity、fixture 等价重生成字节比较及 diff check 通过。
- [修复] 2026-09-04 提交前复验捕获到启动器 stderr drain 与退出分类竞态；原有 repro 在全量门中 RED。现以同一锁串行读取、子进程退出后关闭父端 writer 并 drain 到 EOF，再做 writer-busy 判定；无任意 sleep。focused、连续 20 次、launcher 54 项及 Engram 全量 2,588 项随后均通过。
- [修复] 首次 commit 被 Xcode drift hook 拦下：两个仓库外 UI fixture 会把 worktree 目录名写进 pbxproj，且 commit hook 的绝对 `GIT_DIR` 会让脚本在 `cd macos` 后误判全部生成文件。`project.yml` 现固定 `UITestFixtures` group，Git 查询显式锚定 repo root；两项回归均先 RED，两个不同目录随后生成相同 pbxproj 字节，focused 8 项、typecheck、Biome、普通及显式 `GIT_DIR` hook 均通过。
- [排查] 最终源码的 3 个 focused UI test 在任何测试体/截图执行前失败；fresh Runner 卡在连接 XCTest 前的 `AppleSystemPolicy` 签名策略评估，属于未签名测试基础设施阻断，不是产品断言。2026-08-22 旧截图不能代表本轮 UI。
- [未验证] 当前前台 UI/截图、真实 deployed-server 联调、远端 CI、签名发布包及各机器运行状态仍未验证；Service xcresult 的既有 QoS warning 和 Xcode 27 beta 的 Swift 6 migration warnings 未隐去，详见 `CHANGELOG.md`。
- [边界] 本条只记录源码修复与预部署验证；集成、CI 和三机部署状态以其后单独收口条目为准。未执行 Docker、tag、公开 release、公证或生产数据修改。

### 2026-08-31

- [提交] 主仓完整门通过后已提交 `40218c0b`（`feat: integrate HQ live ingest and product hardening`）；未 push/tag/release。完整测试计数和产物哈希见 `CHANGELOG.md`。
- [部署] 日用机已运行 Developer ID 签名的 Engram 1.0.5 (1554)；M1/HQ RemoteServer 均运行 `40218c0b`，HQ Service 运行 `40218c0b-build1554`。三机均为单实例、目标路径/哈希命中，Remote `/v1/health` 为 200。
- [验证] 日用机部署回执为 `status` 0.551s、`liveSessions` 17.425s/100；HQ `status` 0.029s、`liveSessions` 1.297s/100；MCP 27 tools。HQ T9/watchdog 字节命中仓库，4 次自然运行均 exit 0，无 degraded sentinel，root plist 未改。
- [安全切换] HQ 旧 Service 在 TERM 后继续初扫，未强杀、未用 `kickstart -k`；待 PID 28608 自然退出后才启动新 PID 42994。四处回滚点和完整过程证据见 `CHANGELOG.md`。
- [验证] HQ 初扫随后完成：`status` 恢复 running/56022/`lastScanAt` 有值；仅补跑一次 `remoteSyncStatus`，0.010s 成功，pending 两队列均为 0。日用机两小时后仍无初扫标记，health/IPC 可用但 `status` 因 last successful scan stale 如实为 degraded；日用机 `remoteSyncStatus` 仍未调用。
- [未验证] 锁屏导致菜单栏最终目检未补；真实 post-reboot 唯一关键词 16 分钟跨机 SLA 仍开放。
- [边界] 未 push/tag/GitHub Release、公证、更新 Sparkle/Homebrew、运行 Docker 或重写生产数据；当前是已提交且已部署的内部 build1554，不是新的公开发布。
- [修复] `liveSessions` 本地源码门已闭：Claude 改为仅扫描项目目录的直接常规会话文件，每个配置 root 只 canonicalize 一次，不再递归 `subagents` 或逐文件做 subagent layout；Codex 递归、symlink 拒绝、全局 newest-100、24h 边界和 TTL 语义保留。详见 `CHANGELOG.md`。
- [验证] 尾段取消先稳定 RED（取消后仍返回并污染 cache），修复后新增 5/5、focused 14/14、完整 `EngramServiceIPCTests` 259/259；两路独立终审均为 `SPEC_COMPLIANCE: PASS` / `CODE_QUALITY: APPROVED`。
- [历史节点] 该修复在本地源码收口时仍是未提交、未部署字节；当时尚未复测已安装 v1.0.5、真实 95,280 文件语料、菜单栏 Live 恢复和生产取消链。后续提交/部署结果以上方本日最新条目为准。
- [重启] 按用户授权仅重启了日常 Mac 的 `com.engram.service`；两次 bounded kickstart 将 PID 25143→93400→96776，当前 launchd 为 running、runs=3、last exit=0，socket 与 status/health 已恢复响应。
- [故障] `Live` 仍未恢复：`liveSessions` 超过 35 秒，3 小时后服务仍约 64% CPU；采样持续落在对 `~/.claude/projects` 95,280 个文件的递归枚举、realpath 与 subagent 路径判定。重启不是修复，详见 `CHANGELOG.md`。
- [历史节点] 部署前审计时，各机均非 2026-08-31 脏树新字节：日常 Mac/HQ 的 Service 为 2026-08-25 同一二进制，HQ/M1 的 RemoteServer 均为 `986e7fb0`，M1 没有运行 EngramService；该状态已由上方本日部署条目取代。
- [历史边界] 该审计 pass 未 build/install/deploy，未重启远端，未 commit/push/tag、Docker 或改生产数据；“本地服务已重启但 Live 仍降级、各机未升级”仅描述当时状态。
- [已闭合] HQ live ingest 的最终本地门已收口：单 consumer、真实 delta token、idle interval、变更后 trailing 60 秒、多页同 wake 排空、publish 后重探测及 complete-only retract ack/finalize 均已覆盖；Settings/Mock 诚实修复、origin pre-LIMIT、安装器校验和四项 UI residual 也已落入主仓。细节见 `CHANGELOG.md`。
- [验证] 最终字节通过 App 1,097、Core 1,386+1 skip、Service 793+1 skip、runner 31、Vitest 1,549+2 skip、Settings 14、Command Palette 15、UIUX+Onboarding wiring 47，以及 Onboarding hunk 之后的未签名 Debug build；74 路径审计为 68 同 blob、6 个预期差异、零缺失/意外覆盖。默认布局 UI smoke 的 runner 在任何 Onboarding test method 执行前被取消：0 case、1 canceled runner，不算产品行为通过。
- [未验证] 真实双机 16 分钟 SLA、远端 CI、真实 Dynamic Type 交互及签名真机部署仍未验证。
- [历史边界] 该本地收口 pass 没有 commit/push/tag、Docker、生产 `~/.engram`、部署、launchd 修改或服务重启；当时仍是 `d97d0257` 主脏树，后续状态以上方本日最新条目为准。
- [遗留] `live-ingest-arm-1` 仍要求首次启用后重启服务（UI 已明确提示）；硬删 session 缺 tombstone，以及 manifest GC 删除失败无 durable retry，作为低优先级真实 residual 留在 `docs/followups.md`。

### 2026-08-30

- [整合] 已把冻结的 T0–T9 主仓修复与 UI Wave 1–8/merge-gate 工作树合回同一 `d97d0257` 脏树：68 个 UI 文件逐字节采用、45 个路径保留主仓、3 个重叠文件做语义合并；xcodeproj/project.yml 未漂移，也未引入 `AsyncEntryGate.swift`。完整合并细节见 `CHANGELOG.md`。
- [验证] 合并树隔离双 home 全绿：App 聚焦 298、App 全量 1,088、Core 1,382（skip 1）、Service 769（skip 1）、MCP 254、Remote 158、Vitest 1,548（skip 2），以及 Debug build、TS build/typecheck、lint、knip、adapter parity、direct-writer、diff check。fixture schema 通过，重生成 blob 与门前一致；仅因该 fixture 本就相对 HEAD 为 dirty，`check:fixtures` 的最终 HEAD 比较如实 exit 1。
- [历史节点] UI 合并门完成时，前台 UI 自动化、远端 CI、真实跨机 16 分钟 ingest SLA 未跑，且仍是本地未发布合并态；后续部署未改变 UI/SLA 的未验证边界。
- [边界] 未使用 Docker，未 commit/push/tag/release，未部署/安装/SSH/重启/改 launchd，未读取或写入生产 `~/.engram`；测试生成器清掉的两个既有 SQLite sidecar 已按冻结哈希恢复。
- [修复] 按派工修订范围在 `d97d0257` 脏树依次完成 T0→T9；独立 spec gate 随后重开并闭合九项阻断。第四次 follow-up 修复同为 version 1 时旧 snapshot-hash 的 `failed_permanent` FTS job 永久污染 readiness：只淘汰 `id != 当前 jobId` 的旧 permanent，当前同一 permanent job 仍保持 terminal、不越界重试。其余八项及完整细节见 `CHANGELOG.md`。
- [验证] 九项 follow-up 均先有真实行为 RED；本次 `SessionSnapshotWriter` RED 证明旧 permanent 与新 job 共存且新 job 完成后仍无 live candidate。最小一行生产修复后，新 FTS 可发布，当前 permanent 的 status/retry/error 保持不变；IndexerParity 72、SessionSync 43、RemoteSyncCoordinator 40（skip 1）、隔离双 home 的 Core 1,382（skip 1）和 ServiceCore 769（skip 1）均通过。生产 TS build、测试 typecheck、direct-writer scan 与 lint 也通过；lint 仍仅有既有 1 warning/1 schema info。本次 Swift-only follow-up 未重跑 Vitest，前次 1,548（skip 2）仅保留为既有证据。
- [更正] 本条原称 Settings“启用后需重启”/occupancy 语义和 Mock 失败注入未认领；它们不属于 T0–T9 pass，但 2026-08-31 已确认随 UI 合并闭合，以上方新条目为准。HQ 脚本与 wrapper 仍只在 repo，待 owner 授权部署后验证重复启动、degraded sentinel、无控制台登录重启和真实跨机 16 分钟 SLA；远端 CI 仍未跑。
- [边界] follow-up 未修改 UI 或 xcodeproj；未使用 Docker，未开 worktree，未 commit/push/tag，未 SSH/部署/安装/重启/改 launchd，未读取或写入两台机器的生产 `~/.engram`；公开基线仍为 v1.0.5。

### 2026-08-29

- [修复] HQ 重启后 LaunchAgent 要等控制台登录才起；日常机加了 SSH 看门狗 `com.engram.hq-live-ensure`（120s），并在 HQ 装了开机 LaunchDaemon（`com.engram.*.boot`，`UserName=bing`）。详见 `CHANGELOG.md`。
- [验证] ensure 空跑不重复进程；日常机 agent last exit 0；daemon 已注册且因现有进程占用端口/锁而 exit 0；现有 pid 5669/5682 未动。
- [未验证] 下次 HQ 重启、无控制台登录时 daemon 是否真的拉起。FileVault 解锁前仍不会起。16 分钟 SLA 仍未证明。
- [边界] 未发布、未 commit。公开基线仍为 v1.0.5。未重启 HQ helper。

### 2026-08-25

- [启用] HQ 无头 `EngramService` launchd 已装（`com.engram.service`，publish on / offload off，peer=`hq`）；日常机已换成脏树 Release App，并打开 ingest 开关。详见 `CHANGELOG.md`。
- [验证] 两边 sanitizer 日志都有 `live ingest armed`。HQ 尚未写出 `live.hq.*`（卡在 Archive v2 初始扫描）；日常机 `origin=hq` 仍为 0。16 分钟 SLA 未跑。
- [未验证] 从 Spotlight/`open -a Engram` 启动日常机 App 不会带上 offload token（ad-hoc helper 读不到 Keychain）；必须走 `~/.engram/run/start-engram-app`。
- [边界] 未发布、未 commit。公开基线仍为 v1.0.5；未创建 v1.0.6，未 tag/公证/Homebrew/Sparkle。

### 2026-08-24

- [新增] 脏树上落地 HQ → 日常 Mac 单向 live ingest：独立 `makeLiveIfEnabled`（不走 `runOnce`/catalog）、ledger-join 发布、完整代才撤回、缩量闩锁、App `HQ` 徽标与 `remote://` 索引快照、MCP 先于适配器处理、Resume 诚实报错、Settings 开关与 shrink-guard 复位 IPC。详见 `CHANGELOG.md`。
- [验证] 本能力的聚焦 `_repro` 已绿（config/occupancy/candidates/codec/publish-pull/runner、Session origin、MessageParser/MCP `remote://`、Resume IPC）。完整 Swift/Vitest、live XcodeGen、HQ launchd 与 16 分钟跨机 SLA 未跑。
- [未验证] Settings 在服务已以 ingest=off 启动后打开，要等下次服务启动才会构造 live coordinator；Settings/IPC 复位没有单独 `_repro`。遗留见 `docs/followups.md`。
- [边界] 未发布、未 commit。公开基线仍为 v1.0.5；未创建 v1.0.6，未 tag/公证/Homebrew/Sparkle，未改生产 `~/.engram`。

- [更正] 撤回同日 Round-11 “Package 1→13 均已完成、leftover #4 已闭合”的过早收口；Round-12 仍确认 12 个遗留和 59 个新增确认项。详见 `CHANGELOG.md`。
- [修复] 最终收口已完成 Round-12 十三个去重 must-fix 包，并补齐 Transcript Find、Cursor 标题/摘要、Timeline 日计数、live locator/Antigravity、SearchPage 并发及 OpenPGP 脱敏等相邻高优先级修复；dual-constructor 前缀回归已在磁盘通过。
- [遗留] 未继续追逐的 runtime secrets、SessionDetail 并发及中低优先级项已按 ID、文件位置和原因登记到 `docs/followups.md`，均明确为“未声称修复”。不再启动下一轮 review/fix 循环。
- [验证] Core、Service、MCP、App 的本轮聚焦 hermetic 回归通过；完整 Swift/Vitest 套件、前台 UI 自动化、远端 CI 与共享脏树 live XcodeGen 未执行。
- [边界] 这是面向未来合并的本地停止点，不是全仓零缺陷或公开发布。公开基线仍为 v1.0.5；未创建 v1.0.6，未使用 Docker，未 commit、push、部署、安装、重启、修改生产数据、tag、GitHub Release、公证或更新 Homebrew/Sparkle。

- [更正] 撤回同日 Round-10 “四个点名遗留均已闭合”的过早收口；Round-11 仍确认 3 个未闭合项和 67 个新增确认项。Unicode/Darwin CommandCode slug、CommandCode/Qoder/Kimi 增长中 JSONL 前缀、MCP keep-hits 与 `adapterMessages` dual-throw 当时仍不完整。详见 `CHANGELOG.md`。
- [修复] 已在原脏工作树完成 Round-11 报告 Package 1→13 的去重实现与 `_repro`，保留既定 do-not-fix 契约；报告内点名包现均有本地实现，仍待 Grok 独立复审。
- [验证] Core、App、Service、MCP 聚焦 hermetic 回归及 Engram 全量 `build-for-testing`（含 UI test target 编译）通过；仓库边界脚本和 `git diff --check` 用于收口核验。
- [未验证] 本轮未重跑五个 Swift/Vitest 全量套件、前台 UI 自动化、远端 CI，也未在共享脏工程上 live XcodeGen；这些项目不能由聚焦回归替代。
- [边界] 这是 Round-11 报告范围的本地实现证据，不是全仓“零缺陷”或公开发布；HEAD 与 `origin/main` 仍为 `d97d0257`，工作树保持未提交。未使用 Docker，未 commit、push、部署、安装、重启、修改生产数据、tag、GitHub Release、公证或更新 Homebrew/Sparkle。

- [更正] 撤回同日 Round-9 “五个遗留均已修复、没有故意延期簇、parser prefix 与 live semantic probe 已完成”的过早收口；Round-10 仍确认 2 个未闭合项和 60 个新增项。独立点名遗留为 CommandCode live slug 编码反向、Qwen/Gemini/Cursor 默认扫描丢前缀、MCP semantic/hybrid BUSY 错报 `searchModeUnavailable`、dual-throw 空 `parseFailed`。此前 Round-9/8/7 撤回、2026-08-22 hermetic-home 更正与 Qoder 0/0/0 窄范围说明继续有效。详见 `CHANGELOG.md`。
- [修复] 已在原脏工作树完成 Wave CN→DI 去重实现和对应 `_repro`，保留既定 do-not-fix 契约；上述四个点名遗留及 Round-10 报告内 CN→DI 各簇现均有当前实现与聚焦回归，仍待 Grok 独立复审。
- [验证] hermetic Service 720（1 跳过）及 Core、MCP、App、Remote 五个非 UI Swift 全量 scheme 通过；Vitest 129 files / 1,539 通过 / 2 跳过，Node build、test typecheck、Biome、knip、adapter parity 与 XcodeGen 路由聚焦测试通过。两份 fixture DB 连续生成 SHA-256 稳定，schema 检查通过。
- [未验证] Grok 独立复审、远端 CI、前台 UI 自动化与共享脏树 live XcodeGen 未执行；fixture freshness 因本轮生成物相对 HEAD 的预期差异仍返回失败，adapter-format 因本机 Claude/Codex corpus 超过已验证 baseline 而 fail-closed。
- [边界] 这是 Round-10 报告范围的本地实现证据，不是全仓“零缺陷”或公开发布；HEAD 与 `origin/main` 仍为 `d97d0257`，工作树保持未提交。未使用 Docker，未 commit、push、部署、安装、重启、修改生产数据、tag、GitHub Release、公证或更新 Homebrew/Sparkle。

- [更正] 撤回 2026-08-23 “Round-8 点名遗留均已修复、activity-time usage 已完成”的过早收口；Round-9 仍确认 3 个未闭合项和 60 个新增项。`loadall-cap-5`、Copilot `parseSessionInfo`、`workitem-localtime-1`、`observability-ring-1`、本地 catalog remaining-budget 及剩余 `start_time` 成本/ready 查询当时仍未闭合。此前各轮撤回、2026-08-22 hermetic-home 更正和 Qoder 0/0/0 窄范围说明继续有效。详见 `CHANGELOG.md`。
- [历史更正] “Wave CA→CL 点名遗留均已修复、本地没有故意延期簇”的句子已由上方 Round-10 更正撤回；该轮的已落地实现与既定 do-not-fix 清单保持不动。
- [验证] Core 1,313（1 跳过）、App 1,000、Service 712（1 跳过）、MCP 245、Remote 155 项非 UI Swift 测试通过；Vitest 129 files / 1,538 通过 / 2 脏树跳过，Node build、test typecheck、Biome、knip、直接写入/模块/归档边界和 diff check 均通过。
- [未验证] Grok 独立复审、远端 CI、前台 UI 自动化及共享脏树上的 live XcodeGen 再生成未执行；后者的 tracked/untracked fixture 闸和四份 workflow 路由已通过，不能替代 live drift 结论。
- [边界] 这是 Round-9 报告范围的本地实现证据，不是全仓“零缺陷”或公开发布；HEAD 与 `origin/main` 仍为 `d97d0257`，工作树保持未提交。未使用 Docker，未 commit、push、部署、安装、重启、修改生产数据、tag、GitHub Release、公证或更新 Homebrew/Sparkle。

### 2026-08-23

- [更正] 撤回此前“Round-7 当前没有故意延期 ID”的错误收口；Round-8 仍确认 6 个未闭合项和 73 个新增项。遗留项至少包括 `loadall-cap-5`、`copilot-composite-2`、`workitem-localtime-1`、`observability-ring-1`、`remote-catalog-1`。此前 Round-6、AB→AJ、2026-08-22 hermetic-home 更正及 Qoder 0/0/0 窄范围说明继续有效。详见 `CHANGELOG.md`。
- [修复] 已在原脏工作树完成 Wave BI→BY 去重实现和对应 `_repro`；上述遗留项均已落实本地修复，其中 `remote-catalog-1` 已覆盖本地与 HTTP 跳过 65 MiB 坏对象后仍返回后续有效对象。既定 do-not-fix 清单保持不动。
- [验证] Core 1,295（1 跳过）、App 979、Service 705（1 跳过）、MCP 241、Remote 155 项非 UI Swift 测试通过；Vitest 129 files / 1,537 通过 / 2 跳过，Node build、test typecheck、Biome、knip、adapter parity、Cursor 聚焦套件、直接写入/模块边界、diff check 和临时索引 xcodeproj drift 闸通过。固定 XcodeGen 输出哈希稳定为 `ad144b3a…`，真实 Git 索引未修改。
- [未验证] Grok 独立复审、远端 CI 和用户离开后的前台 UI 自动化尚未执行；旧的 UI 运行数字不能作为本轮收口证据。
- [边界] 这是报告范围的本地实现与验证，不是全仓“零缺陷”或公开发布结论；HEAD 与 `origin/main` 仍为 `d97d0257`，工作树保持未提交。未使用 Docker，未 commit、push、部署、安装、tag、GitHub Release、公证、Homebrew/Sparkle、重启服务或修改生产数据。

### 2026-08-22

- [更正] 撤回此前“Wave L→R 无遗留确认项、测试 home 已全部隔离”的结论；Round-4 复核确认仍有 3 个不完整补丁和 72 个新增确认项，部分 App/MCP 子进程、UI 测试与进程内工厂仍可能解析宿主环境。详见 `CHANGELOG.md`。
- [进展] 本轮已推进 Wave S→Z，并完成 Wave AA 的仓库归属、日志覆盖、insight 链、MCP orphan/catalog 与 TS 子代理布局簇；RED/GREEN 证据和具体文件见 `CHANGELOG.md`。
- [历史遗留] 截至该 2026-08-22 节点，Cursor 标题、Timeline 诚实分页/项目切换、Transcript Find、Replay 截断、归档脱敏、关闭竞态、UITest 固定时钟/搜索命中仍待继续；该清单已被后续 Round-5/6 复核与修复替代，不再代表当前剩余项。
- [更正] 撤回此前“Round-2 Wave G→K 已全部收口”的结论；Round-3 复核确认仍有 7 个不完整补丁和 76 个新增确认项，旧测试计数不能证明缺陷清单已清零。详细证据见 `CHANGELOG.md`。
- [修复] 已在原脏工作树完成 Wave L→R 去重整改，覆盖 skip/FTS、密钥与测试隔离、搜索/解析、索引/归档、UI 并发与分页、远端目录、关闭路径、部署脚本、Warp 及文档真实性；do-not-fix 清单保持不动。
- [验证] 每组行为均先补或强化 `_repro` 并取得真实 RED，再做最小修复转 GREEN；Node 129 files / 1,528 passed、Core 1,179、Service 655、MCP 222、Remote 149、App 881 与无签名 Debug build 均通过，`xcodegen` 连续生成哈希一致。
- [未验证] 签名 UI 搜索 hit/miss 因本机缺少配置的 Mac Development 证书未能执行；禁用签名后 runner 在握手前被系统终止。远端 CI 未运行；未使用 Docker，未 commit、push、部署、安装、重启、发布或修改生产数据。

### 2026-08-21

- [收口] `engram-multi-review` 经裁决确认的 55 项产品缺陷已按 Wave A→F 全部修复；9 个误报保持不动。详细分组与边界见 `CHANGELOG.md`。
- [约束] 保持 Swift-first、single-writer、skip tier 不升级、按 id 可读取隐藏子会话、测试不接触生产 `~/.engram`；未恢复 Node 产品启动路径。
- [验证] 完整 `EngramCoreTests`、`EngramServiceCore`、App 单元测试（跳过 UI 自动化）、`EngramMCPTests`、`EngramRemoteServerCore` 全绿；`git diff --check` 通过，HEAD 仍为 `d97d0257`。
- [边界] 未使用 Docker，未 push、部署、安装、重启、发布或修改生产数据；`.grok/` 原始复核报告保持未跟踪且未改动。

### 2026-08-19

- [修复] Dependabot #431 的 6 处 CodeQL `init`/`analyze` 已统一固定到 v4.37.7 提交 `ff2f1c62`，共享 workflow pin 契约同步更新；未改触发条件、权限或作业结构。详见 `CHANGELOG.md`。
- [验证] 更新后的 Dependabot 头先真实复现 workflow contract 32/33 RED（仅旧 SHA 期望失败），最小同步两条契约常量后聚焦测试 33/33 GREEN。
- [安全] 仅刷新现有 semver 范围内可兼容修复的 lockfile：PostCSS 8.5.26、nanoid 3.3.18、protobufjs 7.6.5；未新增 override、未关闭 audit、未移除可选功能。详细证据见 `CHANGELOG.md`。
- [验证] Node 24 下 clean install、build、测试 typecheck、lint、knip 与 Vitest coverage 129 files / 1,525 tests 通过；真实 audit RED 从 7 个漏洞降至 4 个 high。
- [未验证] 剩余告警全部位于可选 Transformers → onnxruntime/Sharp 链，上游当前无兼容修复；未强制跨 0.x breaking 边界，`npm audit --audit-level=moderate` 继续如实失败。

### 2026-08-16

- [收尾] 已合入 #426 `main@e1331289` 与 #427 `main@986e7fb0`；Copilot checkpoint `parseSessionInfo` 和 Cline 整份 stream 超限均 fail closed。Claude 实验分支 `1680083b` 因破坏 #39 的截断后成功契约而淘汰，未开 PR、未合入，也未继续切新适配器。
- [验证] Copilot/Cline 聚焦回归、`AdapterWindowedReadTests`、完整 `EngramCoreTests`、完整 `EngramRemoteServerCore`、arm64 Release build、包双重 verify、成功切换 dry-run 与注入 503 自动回滚 dry-run 均通过；#426/#427 的 CI Gate、CodeQL Gate、Dependency Review、Swift/RemoteServer/Node/UI/fixture gates 全绿，合入后 `main@986e7fb0` 的 Tests `31947240506` 与 CodeQL `31947240571` 也通过。
- [部署] HQ/M1 均运行 `releases/986e7fb0`，二进制 SHA-256 `3a0cab83ea6078bae553b49981038625d6c5eb06445ae951f8e7d92a18f34df2`。HQ 回滚 `releases/38326d62` / `rollback/20260816T123232Z-pre-986e7fb0`；M1 回滚 `releases/a33fc3b8` / `rollback/20260816T123258Z-pre-986e7fb0`。两机 `GET /v1/health` 200、受保护接口 401/404/405 探针与只绑定 Tailscale `:8787` 通过；receipt index 冷扫后 `archive/machines` 两机均 200（M1 ~4ms，HQ 31–226ms 抽样）。
- [文档] `docs/TODO.md`、`docs/roadmap.md`、`docs/followups.md` 与 stewardship queue 已按当前事实对账：公开 `v1.0.5` 实际已于 2026-08-02 发布；当前无选中的 implementation-ready 工程项，12 个 roadmap 方向仍待 owner 决策。
- [边界] 本轮未安装 App，未改 archive/store/receipt/密钥/客户端设置，未创建 tag 或 GitHub Release，未签名公证新版本，未更新 Homebrew/Sparkle。公开 latest 仍为 `v1.0.5`。

### 2026-08-15

- [复盘] 2026-08-12 两轮复盘后的代管开发在本节点暂停：本轮未发布新版本（公开 `v1.0.5` 已于 2026-08-02 发布）；15 分钟 scheduler `019ff3bc9938` 已删。详见 `CHANGELOG.md` 与 `.memory`。
- [修复] 点名残留已上 main：#345 Cost today 本地日、#346 浏览页内容扫描刷新、#347 Release 禁止明文 settings key、#348 MCP 1 字符搜索门槛、#351 keyword 三面 id 对齐、#353 TS case-only move、#355 仓库探测失败不再烧 6h 冷却、#356 AI 设置离主线程写入。
- [变更] 后续适配器/索引战役把空会话、截断元数据、scan/FTS/回填/MCP/`parseSessionInfo`/stream fail-closed 切成大量单适配器 PR；`main` 收到 `6aefbff2`（#425）。Claude/Codex 整份 stream 保持截断后成功，不强行抛错。
- [排查] 停令之后仍有一拍已在跑的 loop 合了 #425 并开了 #426；截至本节点 #426 未再动。过程问题：队列空了仍自造下一刀、docs closeout 单独 PR、CodeQL 叠跑。
- [验证] 各 PR 以 CI Gate + CodeQL Gate + Dependency Review 为合入闸；本收工未重跑全量测试、未部署、未签名。
- [未验证] 截至本节点 #426（Copilot checkpoint `parseSessionInfo`）仍 OPEN。未安装新 App，未碰生产 `~/.engram`；后续终局见 2026-08-16 条目。

### 2026-08-09

- [修复] CodeQL Action 更新已改为原子路径：Dependabot 对 `github/codeql-action/*` 分组，3 个 `init` 与 3 个 `analyze` 同步到 v4.37.4 `f205ea1c`，共享 pin 测试一并更新；Tests/CodeQL 的 Ubuntu classifier 现先跑 workflow contract，失败会在 macOS jobs 启动前截断，durable-docs-only/无 CodeQL target 场景仍保持轻量。详见 `CHANGELOG.md`。
- [验证] 新回归在旧配置先红 2/32，修复后 workflow/classifier 40/40；Node 24 下 actionlint、build、test typecheck、lint、knip、coverage 与 diff check 通过。Lint 仍有既有 1 warning/1 schema info，`npm ci` 仍报告既有 1 moderate + 6 high advisories；未使用 Docker。
- [未验证] 当前仅为隔离 worktree 本地收据；push、替代 PR、fresh GitHub checks、关闭 #297/#298、merge 与 resulting-main CI 尚未执行。

### 2026-08-02

- [变更] GitHub 根 README 已同步公开 v1.0.5：补 latest 下载、macOS 14+ 安装路径与 Claude Code plugin 入口，修正 local-only bundle 路径、`get_memory` 类型过滤、embedding 默认值及 5 个失效/错向产品链接；plugin README 也已改正 v1.0.5 的 `EngramCLI context` 兼容说明。详见 `CHANGELOG.md`。
- [验证] 精确源码 `ea2f1817` 已制成 Engram 1.0.5 (1424) Developer ID 候选；从历史会话找回有效 Keychain profile `EngramNotary`，Apple 公证 `1de4c3e5-2a49-4fc7-b306-d2909168b417` Accepted、无 issues，staple 后完整 verifier 与最终 ZIP 解包复验均通过。最终 SHA-256 为 `8174193159c15c9e9a6a5215bf0d32f6200694c567379835a0f26b9d921e699a`，详见 `CHANGELOG.md`。
- [验证] `10.230.0.10` 隔离 staging 的哈希、版本、深层签名、Gatekeeper `Notarized Developer ID`、四个 universal binary、App/Service 进程、socket、只读 archive status、MCP 27-tool 与 #291 的未知/空版本 `-32022` smoke 均通过；进程已停，新增 `~/.engram` 测试数据已清。
- [发布] 注解标签 `v1.0.5` 精确指向 `ea2f1817`；tag Release Gate `30729409734` 全绿后，GitHub Release 已作为 latest stable 发布。线上 ZIP 的 GitHub digest 与回下载 SHA-256 均匹配最终候选，回下载 App 的完整签名、公证票据和 Gatekeeper verifier 再次通过。
- [未验证] 验证机无人登录 GUI，故 LaunchServices `open` 不能执行；远端到 Apple CloudKit 不通导致 `stapler validate` 返回 `-1004`，但本机对最终 ZIP 解包件验证 ticket 成功。候选留在远端 `~/EngramVerification/ea2f1817`；未安装、未改渠道、未部署、未用 Docker。

### 2026-08-01

- [修复] #284 协议复审确认 stdio `server/discover` 会绕过不支持版本校验；现先统一判定时代再响应，未知 modern 版本返回 `-32022`，无 `_meta` 探测保持兼容，MCP 全套 193/193 通过。详见 `CHANGELOG.md`。
- [变更] 依次把 #274(`@types/node` 26.1.2)、#276(Biome 2.5.6)、#275(OpenAI 7.1.0)更新到当时最新 `main`，每次以 fresh CI 全绿后 squash 合入；依赖组合基线为 `d5498872`，收尾文档经 #289 落地。详见 `CHANGELOG.md`。
- [清理] 删除 8 个已关闭且提交已在 `main` 的 audit 远端分支；保留含唯一提交且无 PR 的 `evidence/ax5-pr248-2026-07-25`。仅剩主 worktree。
- [空间] 验证后直接删除可再生成/会话临时目录 `macos/build`、`node_modules`、`dist`、`coverage`、`scratchpad`，回收约 1.33GB，仓库降至 301MB；临时文件不可从废纸篓恢复。
- [验证] Node 26.5.1 下 clean install、build、测试 typecheck、lint、knip、Vitest coverage 128 files / 1,518 tests 全过；最终组合态 PR Tests/CodeQL/Dependency Review 全绿。
- [未验证] Biome schema URL 仍指向 2.5.4 且有 1 条 optional-chain warning；npm/GitHub 仍有依赖安全告警，未在本轮扩展修复；未运行 Docker、部署、发布、重启服务或安装 App。

### 2026-07-31

- [复盘] MCP 两轮升级(#277–#281)双重验证复盘:5 路并行审查 + 对抗验证 + Codex 独立复核 29 项发现(1 高、约 10 中);敌意文件系统测试证实 #280 扫描替换防御真实有效,只是此前无测试钉住。详见 `CHANGELOG.md`。
- [修复] `archive_get_session` 窗口读从 O(整源解密) 降为 O(窗口),UTF-8 分页字节精确;列表索引锁外构建 + 失败退避(显式 warm 绕过)+ 毒化日志;`archive_list_captures` 全部由索引服务,去掉逐条 durable 读。
- [变更] 双端时代判定统一(`_meta` 版本键存在即 modern 意图,非字符串值 → -32022);远端 legacy 版本集收缩为 {2025-06-18, 2025-11-25},被移除修订走协商降级而非拒绝。
- [验证] 五个 PR 已按 #282→#283→#285→#284→#286 顺序全绿 squash 落地,最终 main `0e891215` 与预验证的 `retro/integration` 树逐字节一致;落地后本地复验 RemoteServerCore 142/142、MCPTests 192/192、fixture 门禁与 lint 通过,post-merge Tests/CodeQL success。
- [验证] `macmini-m1` 已部署 `releases/a33fc3b8`(回滚指针 `releases/dcc048ce`)。生产 ~25k receipt 归档 A/B:`archive_list_captures`(100 条页)7.5–14.3s → **13–17ms**;`archive_get_session`(14.8MB 源,4KiB 窗口)0.12–0.78s → **~50–70ms**;`archive_list_machines` 对照组不变(~3–5ms);重启后一次性冷预热 ~343s。协议抽检:2025-11-25 握手回显、2025-03-26 协商降级、非字符串 `_meta` 版本 → -32022,Claude Code 客户端路径 401/11ms 可达。

### 2026-07-29

- [验证] #279 dual-era remote MCP 与 #280 扫描快路径+进程内列表索引均已 squash merge 入 main（`5cfcdb48` / `2cec2354`）。`macmini-m1` 已部署 `releases/dcc048ce`（含 dual-era + index），`ENGRAM_REMOTE_MCP_ENABLED=1`；生产冷 warm ~13 分钟后 `listMachines`/`listReceipts` ~3–5ms；Claude Code HTTP 客户端 `✔ Connected`，`archive_list_machines` 体感瞬时返回 3 台机器；`archive_get_session` 可读 transcript（`structuredContent.text`）。回滚：`current` 指回 `releases/38326d62` 或关掉 MCP 变量后 kickstart。
- [性能] 远端 archive 列表：`listMachines`/`listReceipts` 增加进程内 append-only 内存索引（启动后台 warm + `createReceipt` 增量 note），配合扫描快路径让 ~25k receipt 的 MCP 列表可交互；无盘上格式变更。详见 `CHANGELOG.md`，PR #280。
- [性能] 枚举不再走 `getReceipt` 的 fsync/链校验/manifest 交叉校验；扫描路径保留 AEAD 与路径绑定校验。生产冷列表曾 ~23–25 分钟，扫描快路径后 clone 约 18s，再由内存索引消掉 per-request 全量扫。

### 2026-07-28

- [变更] Release 构建新增纯 opt-in `ENGRAM_BUILD_ROOT`：未设置时保持现有 Xcode/仓库路径，设置后仅把 DerivedData、archive 与 export log 放入指定绝对目录，最终 App 仍留在 `macos/build/EngramExport`；真实路径必须保持 Engram 项目作用域，`/Volumes` 缺失或不可写时 fail-closed，`--print-paths` 可在零写入下预检路径。异家复审后补固 macOS Bash 3.2 与 symlink 边界，聚焦测试 35/35；未签名、公证、安装或发布，详见 `CHANGELOG.md`。

### 2026-07-26

- [修复] Public macOS release baseline 已对齐实况：源码 `main@a0bcb620` 与版本元数据为 1.0.5，已安装 Developer ID 1.0.5 (1403) 来自前一提交 `9e5ff9b8`，公开 Release 仍为 `v1.0.3`。`build-release.sh` 的三条候选验证路径现同时锁 short version 与 build number；剩余签名、公证/装订、clean-machine smoke、tag/release 均列为 owner/外部门禁，本轮未碰 Keychain、secret、安装或发布，详见 `CHANGELOG.md` 与 `docs/TODO.md`。
- [修复] Xcode 27 在转录查找 detached match scan 上报告的 actor 警告已用纯 helper `nonisolated` + 非空消息回归修复，Swift 793/793、Node 1,509 项通过。无显式 AppIntents 链接的诊断包仍复现 AppKit 注册错误，但限定日志窗口未见 CoreSpotlight donation；仓库无对应 API，Apple 也在追踪同族错误。因移除链接会重引 Xcode 构建警告、Developer ID 同签名 A/B 又被 login Keychain 阻断，已撤回未证实的修复并裁决为 macOS 27 beta 系统/构建工具集成噪声。teamless 诊断包已撤回，当前安全恢复为 1.0.5 (1403)，完整证据见 `CHANGELOG.md`。
- [验证] clean `main@9e5ff9b8` 已重建并本机安装 Developer ID Engram 1.0.5 (1403)；App/Service/MCP 全部换成安装后的新进程，Service socket 与只读 archive status smoke 正常。旧 1382 签名包保存在 `~/Library/Application Support/Engram/rollback/engram-1.0.5-1382-GvAOSTyW/Engram.app`；未 notarize、staple、tag、release 或远端 deploy，完整哈希与启动期非致命日志见 `CHANGELOG.md`。
- [修复] #229/#233 被 Dependabot 拆开的 CodeQL Action 升级不能单独成立：两边分别造成 v4.37.3/v4.37.0 的确定性 config/runtime 错配。现以 #229 为载体把 3 个 `init`、3 个 `analyze` 及共享测试 pin 原子更新到官方 v4.37.3 commit `e4fba868`；exact 旧 head 已本地复现 30 项中唯一 1 项失败。push、fresh CI、merge 与 post-merge 仍未验证，详见 `CHANGELOG.md`。
- [变更] #231 updates all 19 checkout invocations to official v7.0.1 commit `3d3c42e5`; CI and exact-head local reproduction both exercised the same stale shared test pin, which is now aligned. Push, fresh CI, merge, and post-merge status remain unverified; see `CHANGELOG.md`.
- [变更] #236 的 better-sqlite3 v13 兼容性补强已覆盖两份确定性 fixture baseline、共享本地/CI freshness 闸及无需 `allowScripts` 的干净安装；旧 CI 红未 rerun。完整二进制与测试收据见 `CHANGELOG.md`，本条不宣称远端 merge/post-merge 状态。
- [变更] #234 的依赖/lockfile 内容已在 `9da69b63` 把 lint-staged 17.0.8 升到 17.2.0；真实 `git commit` 失败探针与本地 Node 全量门禁通过，未保留 hook/test 改动。fresh PR CI 仍待推送触发，多文件/特殊 glob/non-TTY 场景未单独验证；完整收据与风险见 `CHANGELOG.md`。
- [验证] #269 已 squash merge 为 main `b8024e5d`；Dependency Review 首轮 `runner_id=0`、无 runner/steps，15 分钟后被取消，仅对 failed run 做一次有收据 rerun，attempt 2 获得 runner 后扫描成功。post-merge Tests `30181348916` 与 CodeQL `30181348906` 全绿，full UI 31/31；未 deploy。
- [验证] #265 已 squash merge 为 main `b8a1cb7a`；异家 exact-head review 无发现，post-merge Tests `30182150988` 与 CodeQL `30182150998` 全绿，full UI 与截图比较通过；未 rerun、未 deploy。
- [验证] #266 已在首轮异家 review 要求澄清 row 20 窄验收后，于 exact head `11ddf467` 获 `APPROVE / NO FINDINGS`，squash merge 为 main `0cdd862c`；post-merge Tests `30182787588` 与 CodeQL `30182787590` 的 docs-only classifiers/gates 全绿，未 rerun、未 deploy。row 20 转为 Landed 只代表旧报告已补 dated correction，不代表 plugin P0 全部完成；镜像 backlog 为 22 landed + 2 partial + 11 open。
- [变更] #235 已 rebase 到 `main@0cdd862c`，tsx 由 lock-resolved 4.22.4 升至 4.23.1；registry integrity、Node engine 与 esbuild range 已核对。CLI/typed eval、build/typecheck/lint/knip、15 个聚焦测试、fixture/schema/parity 与 Node 全量 128 files / 1,508 tests 通过。format-drift 因本机 corpus 超过 baseline 而 fail-closed，旧/新版 tsx A/B 同为两项 blocked/exit 1；audit 既有 6 项不含 tsx/esbuild。
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
