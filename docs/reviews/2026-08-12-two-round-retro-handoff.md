# Engram Two-Round Retro Handoff

- Generated: 2026-08-12T07:16:37
- Workflow display: **two-round-retro-2**
- Status: complete
- Phase: Synthesize
- Agents used: 31
- Report path: `/Users/bing/.grok/sessions/%2FUsers%2Fbing%2F-Code-%2Fengram/019ff303-6a32-7453-9b98-fe4b50da75c5/workflows/wf_019ff30c05707e53910da341aec47d33/scratch/two-round-retro-report.md`

## Workflow result (JSON)

```json
{
  "agent_id": "019ff31a-aa2e-71e3-a0d4-f0b29f51aea6",
  "success": true,
  "output": {
    "overall_verdict": "ACTION_NEEDED",
    "summary": "两轮对抗复盘确认 15 条去重问题（9×P1、5×P2、1×nit）：路径父链无校验且永不修复、空 agentId 身份碰撞、源禁用绕过、源开关 mass-unhide/settings-DB 分裂、project-move 两阶段提交、Popover 父过滤漂移、get_memory 空结果吞降级 warning 等。无 P0、无推翻项。判定 ACTION_NEEDED，应优先修数据完整性与控制面正确性后再视为健康可发。",
    "confirmed_findings": [
      {
        "id": "path-parent-unvalidated-no-reconcile",
        "bug_types": [
          "unvalidated-path-parent-hide",
          "dangling-parent-no-reconcile"
        ],
        "severity": "P1",
        "category": "data-integrity",
        "title": "路径父链写入无校验且 startup 永不修复，可永久隐藏会话",
        "detail": "SessionSnapshotWriter 持久化 adapter parent_session_id 仅 sticky 于 manual，无 existence/depth/skip 校验；backfillParentLinks 只处理 parent_session_id IS NULL；orphan 仅路径可达。悬空/skip/深度非法父链使子会话被 topLevelSQL 隐藏。",
        "primary_files": [
          "macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:374-382",
          "macos/EngramCoreWrite/Indexing/StartupBackfills.swift:1285-1310",
          "macos/Shared/EngramCore/Indexing/SessionVisibilityFilter.swift:36-42"
        ],
        "rounds": [
          1,
          2
        ]
      },
      {
        "id": "subagent-empty-agentid-collision",
        "bug_types": [
          "identity-key-collision"
        ],
        "severity": "P1",
        "category": "data-integrity",
        "title": "空 agentId 时子代理 id 回退为父 sessionId，可覆写父行并自父化",
        "detail": "ClaudeCode/Qoder 在 /subagents/ 且 agentId 空时用 sessionId 作主键；sessions.id 为裸 PK + ON CONFLICT(id)；路径父也是该 UUID，可导致父行被覆写、parent_session_id 自指、根会话从顶层消失。",
        "primary_files": [
          "macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:409-412",
          "macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:278-279",
          "macos/EngramCoreWrite/Database/EngramMigrations.swift:9-10"
        ],
        "rounds": [
          1,
          2
        ]
      },
      {
        "id": "source-disable-bypass-reclass",
        "bug_types": [
          "source-disable-bypass"
        ],
        "severity": "P1",
        "category": "correctness",
        "title": "disabledSources 只滤 adapter.source；Claude 重分类仍以可见行入库",
        "detail": "adaptersExcludingDisabled 按 adapter.source 丢适配器；ClaudeCodeAdapter 仍枚举 ~/.claude/projects 并 detectSource 为 lobsterai/minimax；SwiftIndexer 写 info.source；新行 hidden_at NULL 可见。setSourceEnabled 仅一次性 hide 已有行。",
        "primary_files": [
          "macos/EngramService/Core/EngramServiceRunner.swift:914-918",
          "macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:575-582",
          "macos/EngramCoreWrite/Indexing/SwiftIndexer.swift:797-798"
        ],
        "rounds": [
          1,
          2
        ]
      },
      {
        "id": "popover-toplevel-filter-drift",
        "bug_types": [
          "parent_filter_surface_drift"
        ],
        "severity": "P1",
        "category": "ux-consistency",
        "title": "菜单栏 Popover 省略顶层父过滤，子会话可作顶行出现",
        "detail": "PopoverView 手写 WHERE 仅 hidden+non-skip+HumanDrivenFilter；Home recentSessions / Sessions topLevelOnly / Timeline 均要求 parent_session_id 与 suggested_parent_id 为 NULL。",
        "primary_files": [
          "macos/Engram/Views/PopoverView.swift:266-278",
          "macos/Engram/Core/Database.swift:1214-1219",
          "macos/Shared/EngramCore/Indexing/SessionVisibilityFilter.swift:35-37"
        ],
        "rounds": [
          1,
          2
        ]
      },
      {
        "id": "source-enable-mass-unhide",
        "bug_types": [
          "source-enable-hide-clobber"
        ],
        "severity": "P1",
        "category": "data-integrity",
        "title": "setSourceEnabled(true) 整源清除 hidden_at，覆盖用户手动隐藏",
        "detail": "enable 执行 UPDATE sessions SET hidden_at=NULL WHERE source=?；disable 仅 hide 当前可见行；不更新 session_local_state.hidden_at；列表以 sessions.hidden_at 为准。",
        "primary_files": [
          "macos/EngramService/Core/EngramServiceCommandHandler.swift:1171-1201",
          "macos/EngramService/Core/EngramServiceCommandHandler.swift:1233-1242"
        ],
        "rounds": [
          2
        ]
      },
      {
        "id": "source-settings-db-split",
        "bug_types": [
          "settings-db-dual-write-split"
        ],
        "severity": "P1",
        "category": "data-integrity",
        "title": "源开关先写 settings.json 再写 SQLite，失败无共享回滚",
        "detail": "updateDisabledSourcesSetting 成功后若 writer.write 抛错，disabledSources 与会话可见性永久分叉；ServiceWriterGate catch 无法撤销外部文件写。",
        "primary_files": [
          "macos/EngramService/Core/EngramServiceCommandHandler.swift:1231-1244",
          "macos/EngramService/Core/ServiceWriterGate.swift:134-154"
        ],
        "rounds": [
          2
        ]
      },
      {
        "id": "project-move-two-phase-commit",
        "bug_types": [
          "multi-phase-commit-split"
        ],
        "severity": "P1",
        "category": "data-integrity",
        "title": "Project-move markFsDone 与 applyMigrationDb 分事务，可致 FS/DB 倾斜",
        "detail": "beginCommit 后两次 writer.write；中途进程死亡留下 fs_done + 旧 session 路径；cleanupStaleMigrations 仅标 failed；RecoverMigrations 只读诊断。",
        "primary_files": [
          "macos/EngramCoreWrite/ProjectMove/Orchestrator.swift:646-686",
          "macos/EngramCoreWrite/ProjectMove/MigrationLogStore.swift:161-184",
          "macos/EngramCoreWrite/ProjectMove/RecoverMigrations.swift:43-47"
        ],
        "rounds": [
          2
        ]
      },
      {
        "id": "get-memory-empty-suppresses-degrade",
        "bug_types": [
          "empty_result_suppresses_degrade"
        ],
        "severity": "P1",
        "category": "protocol-honesty",
        "title": "get_memory 在 keyword 也空时丢弃 embedding 失败 warning",
        "detail": "degradeReason 已计算但 emptyMemoryResult 仅 memories/message/type；非空回退路径才附 warning，导致 provider/breaker 失败与真时空库不可区分。",
        "primary_files": [
          "macos/EngramMCP/Core/MCPDatabase.swift:514-619",
          "macos/EngramMCP/Core/MCPDatabase.swift:660-669"
        ],
        "rounds": [
          2
        ]
      },
      {
        "id": "invariant2-ipc-coverage-gap",
        "bug_types": [
          "invariant-coverage-gap"
        ],
        "severity": "P1",
        "category": "tests/invariants",
        "title": "不变量 2 缺 setParentSession/confirmSuggestion 保持 skip 的产品 IPC 证明",
        "detail": "Handler 正确省略 tier 更新，但 Swift IPC round-trip 不 SELECT tier；ledger verified-by 为 backfill + UI grep；仅 TS parent-link-repo 覆盖 link 不改 tier。",
        "primary_files": [
          "docs/invariants.md:12-17",
          "macos/EngramService/Core/EngramServiceCommandHandler.swift:939-977",
          "macos/EngramServiceCoreTests/EngramServiceIPCTests.swift:3465-3483"
        ],
        "rounds": [
          1
        ]
      },
      {
        "id": "skip-parent-link-allowed",
        "bug_types": [
          "skip-parent-link-allowed"
        ],
        "severity": "P2",
        "category": "parent-invariant",
        "title": "IPC/generic validateParentLink 缺少 Codex 的 skip-parent 守卫",
        "detail": "Codex-native 拒绝 tier=skip 父；共享/IPC validateParentLink 仅 self/存在/深度，可手动把 normal 子链到 skip 父造成浏览孤儿。",
        "primary_files": [
          "macos/EngramCoreWrite/Indexing/StartupBackfills.swift:1432-1439",
          "macos/EngramCoreWrite/Indexing/StartupBackfills.swift:1856-1873",
          "macos/EngramService/Core/EngramServiceCommandHandler.swift:1456-1480"
        ],
        "rounds": [
          2
        ]
      },
      {
        "id": "premature-today-parents",
        "bug_types": [
          "premature_today_parents_status"
        ],
        "severity": "P2",
        "category": "parent-invariant",
        "title": "todayParents 在 serviceReady 即发布，早于 parent/tier backfill",
        "detail": "ServiceStatusMonitor 在 serviceReady 且 lastSuccessAt 仍 nil 时返回 .running 并带 live todayParents；recordServiceReady 早于 detached initialScan。R2 降为 P2：瞬态 KPI/badge，非永久错误。",
        "primary_files": [
          "macos/EngramService/Core/ServiceStatusMonitor.swift:56-63",
          "macos/EngramService/Core/EngramServiceRunner.swift:270-305"
        ],
        "rounds": [
          1,
          2
        ]
      },
      {
        "id": "dual-era-unledgered",
        "bug_types": [
          "missing-invariant-anchor"
        ],
        "severity": "P2",
        "category": "docs/invariants",
        "title": "已上线 dual-era MCP 契约未写入 invariants 账本",
        "detail": "docs/invariants.md 止于 §14 且 Unverified Anchors None；stdio dual-era 设计仍 Draft；产品与 PR-4 _repro 已强制 era/-32022，属流程残余非当前 wire bug。",
        "primary_files": [
          "docs/invariants.md:96-105",
          "macos/EngramMCP/Core/MCPStdioServer.swift:134-153"
        ],
        "rounds": [
          1
        ]
      },
      {
        "id": "denylist-case-exact",
        "bug_types": [
          "case-sensitive-denylist"
        ],
        "severity": "P2",
        "category": "path-confinement",
        "title": "敏感路径 denylist 大小写精确，APFS 变体可漏拦",
        "detail": "containsSensitivePathComponent 精确匹配 .ssh/Library+Keychains；非存在 dst 可不 re-case；测试仅规范大小写。同用户威胁模型下为纵深防御。",
        "primary_files": [
          "macos/EngramService/Core/EngramServiceCommandHandler.swift:2471-2491",
          "macos/EngramServiceCoreTests/ServiceSecurityHardeningTests.swift:432-461"
        ],
        "rounds": [
          1
        ]
      },
      {
        "id": "prod-test-write-intent",
        "bug_types": [
          "prod-test-mutator-surface"
        ],
        "severity": "P2",
        "category": "attack-surface",
        "title": "生产 IPC 仍提供 test.write_intent 无产品写命令",
        "detail": "无 DEBUG 门控；持 token 的同用户客户端可占 writer gate 并 bump databaseGeneration。",
        "primary_files": [
          "macos/EngramService/Core/EngramServiceCommandHandler.swift:710-717",
          "macos/Shared/Service/ServiceCapabilityToken.swift:18-22"
        ],
        "rounds": [
          1
        ]
      },
      {
        "id": "token-non-constant-time",
        "bug_types": [
          "non-constant-time-token-compare"
        ],
        "severity": "nit",
        "category": "auth",
        "title": "能力令牌使用非恒定时间字符串比较",
        "detail": "UnixSocketServiceServer 用 != 比较 capabilityToken；RemoteServer 用 constantTimeEquals。同 euid+可读 token 文件下实际风险低。",
        "primary_files": [
          "macos/EngramService/IPC/UnixSocketServiceServer.swift:144-148",
          "macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift:228-243"
        ],
        "rounds": [
          1
        ]
      }
    ],
    "new_bug_types": [
      "dangling-parent-no-reconcile",
      "skip-parent-link-allowed",
      "source-enable-hide-clobber",
      "settings-db-dual-write-split",
      "multi-phase-commit-split",
      "empty_result_suppresses_degrade"
    ],
    "residual_risks": [
      "输入 unverified 为空；无“证据不足仍当 confirmed”项。",
      "同 euid 本地模型下 denylist 大小写、token timing、test.write_intent 属于防御纵深/卫生问题，非跨用户突破。",
      "project-move 在 confirmed 的 B→C 窗口之外，fs_pending 且仅 dst 存在的更广恢复路径仍可能不完整（RecoverMigrations 只读）。",
      "空 agentId 碰撞依赖畸形/schema 漂移输入，非每个 subagent 必现，但影响是静默父行损坏。",
      "settings/DB 分裂需 SQLite 第二步抛错才触发；无自动 heal。",
      "todayParents 在首次 scan 成功后会自愈，但启动窗口 KPI/badge 仍可虚高。"
    ],
    "recommendations": [
      "路径父链：upsert 前要求父存在、depth=1、parent tier≠skip；startup reconcile 清空非法 path 父；writer 拒绝 self-parent。",
      "/subagents/ 空 agentId 拒绝索引或回退 agent-* basename；加覆写父行回归 fixture。",
      "解析后丢弃/强制隐藏 disabledSources 中的 info.source；覆盖 lobsterai 默认关闭扫描测试。",
      "setSourceEnabled：enable 仅恢复 source-disable 隐藏；双写 session_local_state；manual hide→disable→enable _repro。",
      "源开关：先 SQLite 后 settings，或 pending-intent + 失败补偿，禁止 settings 超前。",
      "Project-move：markFsDone+applyMigrationDb 单事务；启动自动完成 stuck fs_done 的路径 rewrite。",
      "PopoverView 复用 listVisibleSQL+topLevelSQL；加子会话不得出现在顶行的回归。",
      "get_memory：emptyMemoryResult 始终附带 degradeReason warning。",
      "EngramServiceIPCTests：setParentSession/confirmSuggestion 保持 tier=skip _repro；validateParentLink 拒绝 skip 父。",
      "invariants.md 增 §15 dual-era；todayParents 门控到 lastSuccessAt/backfill；denylist 大小写折叠；test.write_intent 仅测试构建；可选 constant-time token 比较。"
    ],
    "report_markdown": "## 总评\n\n两轮对抗式复盘后，**无 P0**（崩溃/跨用户突破/会话内容销毁），但确认多条 **P1 数据完整性、源控制面正确性、MCP 协议诚实性** 问题。综合判定：**ACTION_NEEDED**。应优先修复父链/身份键、源开关双写与 get_memory 降级提示，再视为健康可发。\n\n## 两轮轨迹\n\n- **R1**（原始 38）：schema-indexing / adapters / app-read / tests 偏 ACTION；IPC/MCP 偏 WATCH。存活确认 10 类 bug type。\n- **R2**（原始 29）：hotspot 深挖扩展路径父链与源禁用；write-path 新开 hide-clobber、settings/DB 分裂、project-move 两阶段提交；search-honesty 确认 get_memory 空结果吞 warning。\n- **`premature_today_parents_status`**：R2 由 P1 **降为 P2**（启动窗口瞬态 KPI）。\n- **推翻 / 未验证**：`refuted=[]`，`unverified=[]`。\n\n## 已确认问题（P0/P1/P2）\n\n### P0\n\n无。\n\n### P1\n\n1. **路径父链无校验 + 永不修复**（合并 `unvalidated-path-parent-hide` + `dangling-parent-no-reconcile`）  \n   - `SessionSnapshotWriter.swift:374-382` 写 adapter `parent_session_id` 无 existence/depth/skip 校验。  \n   - `StartupBackfills.swift:1285-1310` 仅选 `parent_session_id IS NULL`。  \n   - `SessionVisibilityFilter.swift:36-42` 顶层隐藏非空 parent → 会话可永久从默认列表消失。\n\n2. **空 agentId 身份键碰撞**（`identity-key-collision`）  \n   - `ClaudeCodeAdapter.swift:409-412`：`/subagents/` 且 agentId 空 → id=父 sessionId。  \n   - `SessionSnapshotWriter.swift:278-279` `ON CONFLICT(id)` 可覆写父行并自指 parent（R2 耦合）。\n\n3. **源禁用绕过**（`source-disable-bypass`）  \n   - `EngramServiceRunner.swift:914-918` 只滤 `adapter.source`；Claude `detectSource` 仍产出 lobsterai/minimax；新行可见入库。\n\n4. **Popover 父过滤漂移**（`parent_filter_surface_drift`）  \n   - `PopoverView.swift:266-278` 缺 parent/suggested 双 NULL；Home/Sessions/Timeline 有。\n\n5. **源 enable mass-unhide**（`source-enable-hide-clobber`）  \n   - `EngramServiceCommandHandler.swift:1233-1242` enable `hidden_at=NULL` 整源；用户手动隐藏被清。\n\n6. **settings/DB 双写分裂**（`settings-db-dual-write-split`）  \n   - 同文件先 `settings.json` 后 SQLite；gate 无法回滚外部文件。\n\n7. **Project-move 两阶段提交**（`multi-phase-commit-split`）  \n   - `Orchestrator.swift:661-686` `markFsDone` 与 `applyMigrationDb` 分 `writer.write`。\n\n8. **get_memory 空结果吞降级**（`empty_result_suppresses_degrade`）  \n   - `MCPDatabase.swift:594-619,660-669` `emptyMemoryResult` 无 warning。\n\n9. **不变量 2 IPC 覆盖缺口**（`invariant-coverage-gap`）  \n   - `docs/invariants.md:12-17`；实现正确但无 Swift IPC tier 断言。\n\n### P2\n\n10. **skip 父可被 IPC 链接**（`skip-parent-link-allowed`）— Codex 有守卫，generic/IPC 无。  \n11. **todayParents 过早发布**（`premature_today_parents_status`）— `ServiceStatusMonitor.swift:56-63`。  \n12. **dual-era 未入账本**（`missing-invariant-anchor`）— `invariants.md` 止于 §14。  \n13. **denylist 大小写精确**（`case-sensitive-denylist`）。  \n14. **生产 `test.write_intent`**（`prod-test-mutator-surface`）。\n\n### Nit\n\n15. **令牌非恒定时间比较**（`non-constant-time-token-compare`）。\n\n## 新出现的 bug type\n\nR2 新增类型名：`dangling-parent-no-reconcile`、`skip-parent-link-allowed`、`source-enable-hide-clobber`、`settings-db-dual-write-split`、`multi-phase-commit-split`、`empty_result_suppresses_degrade`。\n\n## 被推翻的误报\n\n无。两轮对抗验证未推翻任何 confirmed 项。\n\n## 残余风险（未验证）\n\n- 输入侧无 unverified 条目。  \n- 同 euid 下 timing/denylist/test 命令为纵深卫生问题。  \n- project-move 更广 `fs_pending`/仅 dst 恢复仍可能不完整。  \n- 空 agentId 路径依赖畸形输入但影响严重。  \n- todayParents 启动窗口虚高会自愈。\n\n## 优点\n\n- Manual IPC 与 Codex-native 父链校验/skip 守卫存在；clearParent 有 skip `_repro`。  \n- Dual-era MCP 产品码与 PR-4 `_repro` 已落地（缺 ledger 非缺实现）。  \n- Socket 安全：euid + 0600 token + protectedCommands。  \n- R2 对瞬态 KPI 主动降级 severity，未夸大。\n\n## 建议下一步\n\n1. Writer：path parent 校验（存在/depth/≠skip）+ startup reconcile + 拒 self-parent。  \n2. 空 agentId：拒绝索引或 path-derived id + 覆写回归。  \n3. 解析后过滤 disabledSources；enable 仅恢复 source-disable 隐藏并双写 local_state。  \n4. 源开关事务顺序或 pending-intent 补偿。  \n5. Project-move B+C 单事务 + stuck fs_done 自动 rewrite。  \n6. Popover 用 topLevelSQL；get_memory 空路径带 warning。  \n7. IPC `_repro`（link 不升 tier、skip 父拒绝）；ledger §15；todayParents 门控；denylist fold；test 命令出生产。\n\n## 结论\n\n**ACTION_NEEDED。** 可运行且无已确认 P0，但多条 P1 构成真实静默损坏与控制面/协议误导；应安排修复波次后再标健康。"
  },
  "cancelled": false,
  "tokens_used": 110613,
  "duration_ms": 125533
}
```

## Report

## 总评

两轮对抗式复盘后，**无 P0**（崩溃/跨用户突破/会话内容销毁），但确认多条 **P1 数据完整性、源控制面正确性、MCP 协议诚实性** 问题。综合判定：**ACTION_NEEDED**。应优先修复父链/身份键、源开关双写与 get_memory 降级提示，再视为健康可发。

## 两轮轨迹

- **R1**（原始 38）：schema-indexing / adapters / app-read / tests 偏 ACTION；IPC/MCP 偏 WATCH。存活确认 10 类 bug type。
- **R2**（原始 29）：hotspot 深挖扩展路径父链与源禁用；write-path 新开 hide-clobber、settings/DB 分裂、project-move 两阶段提交；search-honesty 确认 get_memory 空结果吞 warning。
- **`premature_today_parents_status`**：R2 由 P1 **降为 P2**（启动窗口瞬态 KPI）。
- **推翻 / 未验证**：`refuted=[]`，`unverified=[]`。

## 已确认问题（P0/P1/P2）

### P0

无。

### P1

1. **路径父链无校验 + 永不修复**（合并 `unvalidated-path-parent-hide` + `dangling-parent-no-reconcile`）  
   - `SessionSnapshotWriter.swift:374-382` 写 adapter `parent_session_id` 无 existence/depth/skip 校验。  
   - `StartupBackfills.swift:1285-1310` 仅选 `parent_session_id IS NULL`。  
   - `SessionVisibilityFilter.swift:36-42` 顶层隐藏非空 parent → 会话可永久从默认列表消失。

2. **空 agentId 身份键碰撞**（`identity-key-collision`）  
   - `ClaudeCodeAdapter.swift:409-412`：`/subagents/` 且 agentId 空 → id=父 sessionId。  
   - `SessionSnapshotWriter.swift:278-279` `ON CONFLICT(id)` 可覆写父行并自指 parent（R2 耦合）。

3. **源禁用绕过**（`source-disable-bypass`）  
   - `EngramServiceRunner.swift:914-918` 只滤 `adapter.source`；Claude `detectSource` 仍产出 lobsterai/minimax；新行可见入库。

4. **Popover 父过滤漂移**（`parent_filter_surface_drift`）  
   - `PopoverView.swift:266-278` 缺 parent/suggested 双 NULL；Home/Sessions/Timeline 有。

5. **源 enable mass-unhide**（`source-enable-hide-clobber`）  
   - `EngramServiceCommandHandler.swift:1233-1242` enable `hidden_at=NULL` 整源；用户手动隐藏被清。

6. **settings/DB 双写分裂**（`settings-db-dual-write-split`）  
   - 同文件先 `settings.json` 后 SQLite；gate 无法回滚外部文件。

7. **Project-move 两阶段提交**（`multi-phase-commit-split`）  
   - `Orchestrator.swift:661-686` `markFsDone` 与 `applyMigrationDb` 分 `writer.write`。

8. **get_memory 空结果吞降级**（`empty_result_suppresses_degrade`）  
   - `MCPDatabase.swift:594-619,660-669` `emptyMemoryResult` 无 warning。

9. **不变量 2 IPC 覆盖缺口**（`invariant-coverage-gap`）  
   - `docs/invariants.md:12-17`；实现正确但无 Swift IPC tier 断言。

### P2

10. **skip 父可被 IPC 链接**（`skip-parent-link-allowed`）— Codex 有守卫，generic/IPC 无。  
11. **todayParents 过早发布**（`premature_today_parents_status`）— `ServiceStatusMonitor.swift:56-63`。  
12. **dual-era 未入账本**（`missing-invariant-anchor`）— `invariants.md` 止于 §14。  
13. **denylist 大小写精确**（`case-sensitive-denylist`）。  
14. **生产 `test.write_intent`**（`prod-test-mutator-surface`）。

### Nit

15. **令牌非恒定时间比较**（`non-constant-time-token-compare`）。

## 新出现的 bug type

R2 新增类型名：`dangling-parent-no-reconcile`、`skip-parent-link-allowed`、`source-enable-hide-clobber`、`settings-db-dual-write-split`、`multi-phase-commit-split`、`empty_result_suppresses_degrade`。

## 被推翻的误报

无。两轮对抗验证未推翻任何 confirmed 项。

## 残余风险（未验证）

- 输入侧无 unverified 条目。  
- 同 euid 下 timing/denylist/test 命令为纵深卫生问题。  
- project-move 更广 `fs_pending`/仅 dst 恢复仍可能不完整。  
- 空 agentId 路径依赖畸形输入但影响严重。  
- todayParents 启动窗口虚高会自愈。

## 优点

- Manual IPC 与 Codex-native 父链校验/skip 守卫存在；clearParent 有 skip `_repro`。  
- Dual-era MCP 产品码与 PR-4 `_repro` 已落地（缺 ledger 非缺实现）。  
- Socket 安全：euid + 0600 token + protectedCommands。  
- R2 对瞬态 KPI 主动降级 severity，未夸大。

## 建议下一步

1. Writer：path parent 校验（存在/depth/≠skip）+ startup reconcile + 拒 self-parent。  
2. 空 agentId：拒绝索引或 path-derived id + 覆写回归。  
3. 解析后过滤 disabledSources；enable 仅恢复 source-disable 隐藏并双写 local_state。  
4. 源开关事务顺序或 pending-intent 补偿。  
5. Project-move B+C 单事务 + stuck fs_done 自动 rewrite。  
6. Popover 用 topLevelSQL；get_memory 空路径带 warning。  
7. IPC `_repro`（link 不升 tier、skip 父拒绝）；ledger §15；todayParents 门控；denylist fold；test 命令出生产。

## 结论

**ACTION_NEEDED。** 可运行且无已确认 P0，但多条 P1 构成真实静默损坏与控制面/协议误导；应安排修复波次后再标健康。

## Phase history (last 40)

```json
[
  {
    "event": "workflow_started",
    "at": "2026-08-11T22:57:59.173407+00:00"
  },
  {
    "event": "phase_entered",
    "detail": "Round 1 review",
    "at": "2026-08-11T22:57:59.184112+00:00"
  },
  {
    "event": "log",
    "detail": "Round 1: launching 6 read-only experts (scope=swift-product)",
    "at": "2026-08-11T22:57:59.184148+00:00"
  },
  {
    "event": "log",
    "detail": "R1 service-ipc-security: WATCH, 4 findings",
    "at": "2026-08-11T23:03:07.565120+00:00"
  },
  {
    "event": "log",
    "detail": "R1 schema-indexing-tier: ACTION, 6 findings",
    "at": "2026-08-11T23:03:07.565187+00:00"
  },
  {
    "event": "log",
    "detail": "R1 mcp-protocol: WATCH, 6 findings",
    "at": "2026-08-11T23:03:07.565208+00:00"
  },
  {
    "event": "log",
    "detail": "R1 adapters-parsers: ACTION, 6 findings",
    "at": "2026-08-11T23:03:07.565233+00:00"
  },
  {
    "event": "log",
    "detail": "R1 app-read-ux-consistency: ACTION, 8 findings",
    "at": "2026-08-11T23:03:07.565249+00:00"
  },
  {
    "event": "log",
    "detail": "R1 test-invariants-residuals: ACTION, 8 findings",
    "at": "2026-08-11T23:03:07.565264+00:00"
  },
  {
    "event": "log",
    "detail": "R1 raw findings: 38",
    "at": "2026-08-11T23:03:07.565289+00:00"
  },
  {
    "event": "phase_entered",
    "detail": "Round 1 verify",
    "at": "2026-08-11T23:03:07.565305+00:00"
  },
  {
    "event": "log",
    "detail": "R1 verifying 10 findings",
    "at": "2026-08-11T23:03:07.565321+00:00"
  },
  {
    "event": "log",
    "detail": "R1 verified: 10 real, 0 refuted, 0 unverified",
    "at": "2026-08-11T23:05:20.913524+00:00"
  },
  {
    "event": "phase_entered",
    "detail": "Round 2 review",
    "at": "2026-08-11T23:05:20.913636+00:00"
  },
  {
    "event": "log",
    "detail": "Round 2: hotspot deep-dive + novelty angles; established patterns: unvalidated-path-parent-hide, identity-key-collision, source-disable-bypass, parent_filter_surface_drift, premature_today_parents_status, invariant-coverage-gap, missing-invariant-anchor, case-sensitive-denylist, non-constant-time-token-compare, prod-test-mutator-surface",
    "at": "2026-08-11T23:05:20.913657+00:00"
  },
  {
    "event": "log",
    "detail": "R2 hotspot-deep-dive: ACTION, 8 findings",
    "at": "2026-08-11T23:11:27.028230+00:00"
  },
  {
    "event": "log",
    "detail": "R2 write-path-invariants: ACTION, 7 findings",
    "at": "2026-08-11T23:11:27.028417+00:00"
  },
  {
    "event": "log",
    "detail": "R2 search-embedding-honesty: ACTION, 6 findings",
    "at": "2026-08-11T23:11:27.028445+00:00"
  },
  {
    "event": "log",
    "detail": "R2 release-residual-docs: ACTION, 8 findings",
    "at": "2026-08-11T23:11:27.028466+00:00"
  },
  {
    "event": "log",
    "detail": "R2 raw findings: 29",
    "at": "2026-08-11T23:11:27.028492+00:00"
  },
  {
    "event": "phase_entered",
    "detail": "Round 2 verify",
    "at": "2026-08-11T23:11:27.028534+00:00"
  },
  {
    "event": "log",
    "detail": "R2 verifying 10 findings",
    "at": "2026-08-11T23:11:27.028552+00:00"
  },
  {
    "event": "log",
    "detail": "R2 verified: 10 real, 0 refuted, 0 unverified",
    "at": "2026-08-11T23:13:58.826219+00:00"
  },
  {
    "event": "phase_entered",
    "detail": "Synthesize",
    "at": "2026-08-11T23:13:58.826373+00:00"
  },
  {
    "event": "log",
    "detail": "Report written to scratch/two-round-retro-report.md",
    "at": "2026-08-11T23:16:04.394438+00:00"
  },
  {
    "event": "workflow_completed",
    "at": "2026-08-11T23:16:04.394982+00:00"
  }
]
```
