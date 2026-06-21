# MiniMax — 磁盘会话格式(检测叠加层)

> 本文档为英文权威版 minimax.md 的中文阅读副本;若有出入以英文版为准。

Last researched: 2026-06-21

MiniMax **并非**独立的会话存储。它是叠加在 Claude Code 之上的一个*检测叠加层*:仅通过检查模型名称,就把一个会话从 `claude-code` 重新归类为 `minimax`,而磁盘上的字节仍然是普通的 Claude Code JSONL。不存在 MiniMax 专属的文件、目录、schema 或存储技术。

> **证据基础:** 适配器源码(TypeScript `src/adapters/claude-code.ts`、Swift `ClaudeCodeAdapter.swift`)+ 一致性/单元测试,并与**实时存储** `~/.claude/projects/`(扫描了 5276 个 `*.jsonl` 文件)交叉核对。当前**没有任何**真实会话携带实际的 MiniMax `message.model` 字段(见 [Gotchas](#gotchas)),所以下面的字段表是由适配器定义、测试夹具确认的,而非从本机某个真实 MiniMax 会话采样得到。

---

## Overview

磁盘格式在各个方面都**与 Claude Code 完全一致**——相同的根目录(`~/.claude/projects/`)、相同的项目目录名编码、相同的 JSONL 记录类型、相同的 `message` / 内容块嵌套、相同的子代理布局。完整的逐记录 / 逐字段格式参考,请见 [claude-code.md](./claude-code.md)。该文档中的全部内容对 MiniMax 会话原样适用。

MiniMax 与 Claude Code 的差异恰好只有一个维度:解析时分配的 **Engram source 标签**。它被注册为一个派生适配器:

```swift
ClaudeCodeDerivedSourceAdapter(source: .minimax, base: claudeCode)
```

(`SessionAdapterFactory.swift:13`,另见 `:58`)。该派生适配器复用共享的 `ClaudeCodeAdapter` 基类进行枚举和解析,然后只保留检测出的 source 等于 `.minimax` 的会话。

---

## What differs from Claude Code

| 方面 | 取值 |
|---|---|
| Storage location | **与** Claude Code 相同:`~/.claude/projects/`(没有 MiniMax 专属路径) |
| Storage tech | **相同**:行分隔的 JSONL,每个会话一个文件 |
| File schema | **相同**的 Claude Code 记录 / 内容块 schema——见 [claude-code.md](./claude-code.md) |
| Engram source label | `minimax`(Swift 枚举 `SourceName.minimax`,`SessionAdapter.swift:13`;显示名 "MiniMax",`SourceColors.swift:40`) |
| Detection signal | 从某条 `user`/`assistant` 记录读取的模型名称(大小写不敏感的子串 `minimax`) |
| Storage-location nuance | **无。** `SourceCatalog.swift:26` 将 `minimax` 列为 `defaultPath: "~/.claude/projects"`,与 `claude-code` 路径相同 |

### The exact detection rule

当且仅当一个会话检测出的模型字符串包含子串 `minimax`(大小写不敏感),且未先被 Lobster AI 路径检查认领时,该会话被归类为 `minimax`。模型取自扫描 `user`/`assistant` 记录时找到的第一个非空 `message.model`。

优先级(自上而下,首次匹配胜出):

1. 文件路径包含 `lobsterai` 组件 → `lobsterai`
2. 模型为空 / 以 `claude` 开头 / 以 `<` 开头 → `claude-code`
3. 小写化后的模型**包含** `minimax` → **`minimax`**
4. 其他情况(例如通过 Claude 兼容客户端路由的 qwen/kimi/gemini)→ `claude-code`

权威源码(两个适配器之间逐字节一致):

```ts
// src/adapters/claude-code.ts:180-191
static detectSource(model: string, filePath?: string): SessionInfo['source'] {
  if (filePath && ClaudeCodeAdapter.hasLobsterAIPathComponent(filePath))
    return 'lobsterai';
  if (!model || model.startsWith('claude') || model.startsWith('<'))
    return 'claude-code';
  const m = model.toLowerCase();
  if (m.includes('minimax')) return 'minimax';   // ← the MiniMax rule
  return 'claude-code';
}
```

```swift
// macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:212-223
static func detectSource(model: String, filePath: String? = nil) -> SourceName {
    if let filePath, hasLobsterAIPathComponent(filePath) { return .lobsterai }
    if model.isEmpty || model.hasPrefix("claude") || model.hasPrefix("<") {
        return .claudeCode
    }
    let lowercased = model.lowercased()
    if lowercased.contains("minimax") { return .minimax }   // ← the MiniMax rule
    return .claudeCode
}
```

**检测规则所在位置:** `src/adapters/claude-code.ts:187` 和 `macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:219`。

已确认能匹配的模型字符串(来自测试):`minimax-m1`(`tests/adapters/claude-code.test.ts:122`、`EngramTests/AdapterParityTests.swift:101`)和 `minimax-text-01`(`EngramCoreTests/AdapterParityTests.swift:119`)。该规则是子串匹配,因此任何包含 `minimax` 的模型 id 都符合条件。

> **时效性说明(2026-06-21 网络核查):** 上面的 `minimax-m1` / `minimax-text-01` 字符串是有效的,但早于当前官方的 Claude Code 集成。截至 2026 年 6 月,官方 MiniMax "Claude Code" 配置文档将 `ANTHROPIC_MODEL` 设为 `"MiniMax-M3"`(M2.x 系列——`MiniMax-M2.5` / `MiniMax-M2.1`——也在使用中)。它们都包含子串 `minimax`,所以检测规则保持不变;只是当前官方的实时示例是 `MiniMax-M3` / `MiniMax-M2.5`,而非旧的夹具。这是时效性/示例更新,而非正确性错误。
> ([source](https://platform.minimax.io/docs/token-plan/claude-code))

---

## Engram mapping

单个 Claude 格式文件如何解析为 `minimax` 还是 `claude-code`:

1. **Enumerate** —— 派生适配器通过共享基类列出候选。
   `ClaudeCodeDerivedSourceAdapter.listSessionLocators()` →
   `base.listDerivedSessionLocators(source: .minimax)`
   (`ClaudeCodeAdapter.swift:600-602`、`:57-80`)。基类做一次低成本的首模型 "source hint" 扫描(至多 64 行 / 1 MB,
   `firstModelHint` `ClaudeCodeAdapter.swift:260-309`,
   `modelHint` 依次检查顶层 `model`、`message.model`,再到 `payload.model`
   `:322-333`),只保留 hint 等于 `.minimax` 的 locator。结果按 `(path, mtime, size)` 签名缓存
   (`ClaudeCodeSourceHintCache`,`:539-571`)。

2. **Parse** —— `parseSessionInfo` 从某条 `user`/`assistant` 记录上的第一个 `message.model` 提取 `detectedModel`,然后调用 `detectSource` 来设置 `source`。
   - TS:模型捕获 `src/adapters/claude-code.ts:106-108`;分类 `:146`。
   - Swift:模型捕获 `ClaudeCodeAdapter.swift:123-125`;分类 `:151`。

3. **Filter to source** —— 派生适配器仅在 `info.source == .minimax` 时接受解析结果,否则返回
   `.unsupportedVirtualLocator`
   (`ClaudeCodeDerivedSourceAdapter.parseSessionInfo`,
   `ClaudeCodeAdapter.swift:612-621`)。这保证了即使 Claude + MiniMax + Lobster 都共享同一个基类枚举器,单个物理文件也恰好被一个 source 拥有。

流式 / transcript 读取把 MiniMax 路由到 Claude-code 路径
(`MessageParser.swift:32`、`MCPTranscriptReader.swift:102,144`、
`TranscriptExportService.swift:333`),因为字节是 Claude 格式。

每个 Claude Code 字段都一一对应;唯一解释发生变化的字段是 `message.model`,它供给 `detectSource`:

| Field | Type | MiniMax 中的作用 | Example |
|---|---|---|---|
| `message.model` | string (optional) | 某条 `user`/`assistant` 记录上的第一个非空值;子串 `minimax`(大小写不敏感)→ `source = minimax`;同时存为 `SessionInfo.model` | `"minimax-m1"`、`"minimax-text-01"` |

assistant 记录示例(已匿名化;结构原样,这是纯 Claude Code JSONL):

```json
{
  "type": "assistant",
  "sessionId": "<uuid>",
  "timestamp": "2026-04-29T10:00:01.000Z",
  "message": {
    "role": "assistant",
    "model": "minimax-m1",
    "content": [{ "type": "text", "text": "<assistant text>" }]
  }
}
```

---

## Gotchas

- **检测对内容无感——它只读取 `model` 字段。** 在实时存储中,`minimax` 出现在很多会话里,但仅出现在*用户消息内容文本*中(例如某条提示词列出了像 `MiniMax M3 / M2.x` 这样的模型 SKU)。这些**不会**被检测为 MiniMax,因为 `detectSource` 依据的是 `message.model`,而绝不是消息正文文本。扫描 5276 个实时 `~/.claude/projects/*.jsonl` 文件后,发现**没有任何**会话带有实际的 MiniMax `message.model` 字段——所以在本机上,`minimax` source 当前不产生任何会话,尽管该子串在内容中很常见。
- **子串匹配,而非相等。** 任何包含 `minimax`(大小写不敏感)的模型 id 都会被归类为 MiniMax。未来某个 Anthropic/第三方模型,如果其 id 偶然包含该子串,就会被错误标记。
- **首模型胜出 / 模型混用。** 分类使用遇到的*第一个*非空 `message.model`。某个文件的第一个模型是 `claude-*`,但之后切换到 `minimax-*` 模型(或反之)的,仅由那个第一个模型来分类——会话中途的模型切换不会重新分类。反过来,靠前的一条 `minimax-*` 行会把整个文件标记为 `minimax`,而不管后面的 Claude 行。
- **对于被截断的文件,hint 与 parse 可能不一致。** 枚举使用受限扫描(64 行 / 1 MB)。如果前 64 行没有携带 `model` 而靠后的某行有,hint 可能漏掉它;权威的 `source` 始终来自完整的 `parseSessionInfo` 过程。派生适配器解析后的 `info.source == .minimax` 过滤器是最终裁决者。
- **`claude` / `<` 前缀会在 MiniMax 检查之前短路。** 以 `claude` 或 `<`(占位符)开头的模型返回 `claude-code`,永远到不了 `minimax` 分支。
- **Lobster AI 路径优先于模型。** 基于路径的 `lobsterai` 检查先运行;一个位于 `lobsterai` 项目目录下的 MiniMax 模型文件会被标记为 `lobsterai`,而非 `minimax`。

---

## Open questions / web confirmation (resolved 2026-06-21)

"叠加在 Claude Code 之上的检测叠加层"这一框定,以及子串匹配的检测规则,均已对照官方 MiniMax 来源核查。结果如下:

- **Confirmed (official):** MiniMax 是一个 Claude-Code 兼容的运行时,而非独立的会话存储。MiniMax 官方文档记载了通过 Anthropic 兼容端点在 Anthropic 的 Claude Code *内部*运行其模型——配置页面指示用户设置 `ANTHROPIC_BASE_URL="https://api.minimax.io/anthropic"`(中国:`https://api.minimaxi.com/anthropic`),并将 `ANTHROPIC_MODEL` 指向某个 MiniMax 模型。由于 MiniMax 通过环境变量覆盖在 Claude Code 内部运行,会话是由 Claude Code 自身写入 `~/.claude/projects/` 的普通 Claude Code JSONL。MiniMax 自己的第一方 CLI(`mmx-cli`)是一个多模态生成工具,并非编码会话存储。这印证了"检测叠加层,而非独立格式"的论断。
  ([source](https://platform.minimax.io/docs/token-plan/claude-code),
  [source](https://github.com/MiniMax-AI/Mini-Agent/blob/main/README.md))
- **Confirmed (official):** 每个官方 MiniMax 模型标识符都使用 `MiniMax-` 前缀,而该前缀包含大小写不敏感的子串 `minimax`:`MiniMax-M3`(官方 Claude Code 文档将 `ANTHROPIC_MODEL` 设为的模型)、`MiniMax-M2.5` / `MiniMax-M2.1`(Anthropic 兼容的编码模型)、`MiniMax-Text-01` 和 `MiniMax-VL-01`(开源的 MiniMax-01 系列),以及 `MiniMax-M1`(开源推理模型)。因此,对 `message.model` 的子串匹配检测规则能够正确地归类真实、当前的官方 MiniMax 模型。
  ([source](https://platform.minimax.io/docs/token-plan/claude-code),
  [source](https://www.minimax.io/news/minimax-01-series-2))
- **Confirmed (official):** 文档中的示例字符串 `minimax-m1` 和 `minimax-text-01` 是真实的官方 MiniMax 模型 id。`MiniMax-Text-01` 是开源 MiniMax-01 系列的基础语言模型(于 2025-01-15 发布,与 `MiniMax-VL-01` 一同);`MiniMax-M1` 是 MiniMax 的开源混合注意力推理模型(456B 参数,基于 `MiniMax-Text-01` 构建,变体为 `MiniMax-M1-40k` / `MiniMax-M1-80k`)。两者都有效;两者都包含 `minimax`。注意:它们是较早代的 id——见 [The exact detection rule](#the-exact-detection-rule) 中的时效性说明。
  ([source](https://www.minimax.io/news/minimax-01-series-2),
  [source](https://venturebeat.com/ai/minimax-m1-is-a-new-open-source-model-with-1-million-token-context-and-new-hyper-efficient-reinforcement-learning))
- **Confirmed (official):** 不存在 MiniMax 专属的磁盘会话格式。文档化的 Claude Code 集成纯粹是在 Anthropic 的 Claude Code 客户端之上做环境变量覆盖(`ANTHROPIC_BASE_URL` + `ANTHROPIC_MODEL`),所以会话字节是由 Claude Code 以标准 Claude Code JSONL 写入 `~/.claude/projects/` 的。MiniMax 的其他独立工具(`mmx-cli`、MiniMax MCP 服务器)是生成/智能体技能工具,而非 transcript 存储。这印证了"与 Claude Code 完全一致、相同的 `~/.claude/projects/`"的论断。
  ([source](https://platform.minimax.io/docs/token-plan/claude-code),
  [source](https://github.com/MiniMax-AI/Mini-Agent/blob/main/README.md))
- **Confirmed (partial):** `minimax` 子串规则在理论上过于宽泛(未来某个模型若其 id 偶然包含 `minimax` 就会被错误标记——已在 [Gotchas](#gotchas) 中说明)。官方来源确认当前实际风险很低:每个 MiniMax 模型都使用明确无歧义的 `MiniMax-` 前缀,且没有已知的主流非 MiniMax 模型 id 包含该子串。该规则当前是安全的,但正如文档坦诚指出的,理论上过于宽泛。(这部分上属于 Engram 内部设计选择,而非工具格式事实。)
  ([source](https://www.minimax.io/news/minimax-01-series-2),
  [source](https://platform.minimax.io/docs/token-plan/claude-code))

---

## References (official sources)

- [MiniMax API Docs — Claude Code (token-plan)](https://platform.minimax.io/docs/token-plan/claude-code)
- [MiniMax API Docs — M3 for AI Coding Tools](https://platform.minimax.io/docs/guides/text-ai-coding-tools)
- [MiniMax-AI/Mini-Agent (official repo, Anthropic-compatible API)](https://github.com/MiniMax-AI/Mini-Agent/blob/main/README.md)
- [MiniMax News — MiniMax-01 series open-sourced (MiniMax-Text-01 / MiniMax-VL-01)](https://www.minimax.io/news/minimax-01-series-2)
- [VentureBeat — MiniMax-M1 open-source model (based on MiniMax-Text-01)](https://venturebeat.com/ai/minimax-m1-is-a-new-open-source-model-with-1-million-token-context-and-new-hyper-efficient-reinforcement-learning)
- [MiniMax (official) on X — MiniMax-01 open-source announcement](https://x.com/MiniMax__AI/status/1879226391352549451)
