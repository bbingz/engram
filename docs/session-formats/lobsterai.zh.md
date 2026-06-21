# LobsterAI — 磁盘会话格式(检测覆盖层)

> 本文档为英文权威版 lobsterai.md 的中文阅读副本;若有出入以英文版为准。

Last researched: 2026-06-21

> **证据基础:** 适配器源码(Swift + TypeScript)+ 适配器一致性
> 测试,并与本机的**磁盘实时数据**交叉核对:
> `~/.claude/projects/-Users-bing-lobsterai-project/`(1 个目录;仅含索引)。
> 实时数据与适配器之间的一处差异已在
> [Gotchas](#gotchas) 中标记。

## Overview

LobsterAI 的交互式转录**没有自己的磁盘格式。**
LobsterAI 构建在 [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/sessions)
之上(`@anthropic-ai/claude-agent-sdk`,与 Claude Code 同一引擎),它通过 Cowork 的
`coworkRunner.ts` 将其作为受管子进程运行
([AGENTS.md](https://github.com/netease-youdao/LobsterAI/blob/main/AGENTS.md);
[issue #139](https://github.com/netease-youdao/LobsterAI/issues/139) 显示运行栈
调用了 `@anthropic-ai/claude-agent-sdk/cli.js`)。这正是**为什么**它的转录
继承了 Claude Code 完全相同的 JSONL 记录/内容块 schema,以及完全相同的位置
(`~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`):写入它们的是该 SDK,
而非 LobsterAI。

**路由细微差别:** LobsterAI 的 `CoworkEngineRouter` 既可以分派到 Claude Agent
SDK 路径(写入 `~/.claude/projects` JSONL —— Engram 索引的就是这条路径),**也**
可以分派到 OpenClaw 引擎(在 OpenClaw 工作目录中使用基于文件的内存,不写
`~/.claude/projects` JSONL)。LobsterAI 同时明确支持多提供方 —— 它可以在云端
API 与本地模型(运行 DeepSeek/Qwen 的 Ollama)之间切换 —— 所以“没有自己的磁盘
格式”这一说法专门针对 Claude Agent SDK 的转录路径成立。此外,LobsterAI 还维护
着自己的 `lobsterai.sqlite` 应用存储(见下文)。无论哪种情况,这都不影响
Engram,它只索引存在的、符合 Claude-Code 格式的 JSONL。

完整的逐字段记录、内容块与工具格式化参考,请见
**[claude-code.md](./claude-code.md)** —— 它逐字适用。
本文档**仅**覆盖那些使会话成为 LobsterAI 而非 Claude
Code 的部分,它是一个**检测覆盖层**(在解析时决定的来源标签),
而不是一个独立的存储、解析器、schema 或目录。

在 Engram 中,LobsterAI 适配器实际上只是对 Claude
Code 适配器的薄包装,仅保留被 Claude Code 适配器分类为
`.lobsterai` 的定位符(locator):

- `ClaudeCodeDerivedSourceAdapter(source: .lobsterai, base: claudeCode)`
  注册于
  `macos/.../Adapters/SessionAdapterFactory.swift:14`(以及 `:59`)。
- 包装器本身:`macos/.../Adapters/Sources/ClaudeCodeAdapter.swift:573`
  (`ClaudeCodeDerivedSourceAdapter`);它通过
  `precondition(source == .minimax || source == .lobsterai)`
  (`ClaudeCodeAdapter.swift:578`)将自身约束到 MiniMax/LobsterAI,并将
  `projectsRoot` 默认设为
  `~/.claude/projects`(`ClaudeCodeAdapter.swift:585`)。

## What differs from Claude Code

**唯一的差异是来源标签,它由一条目录路径分量(path-component)规则决定。**
当且仅当一个会话 `.jsonl` 定位符的某个路径分量是
`lobsterai`(可带前导点,可后接一个 `._-`
分隔符再加更多文本)时,该会话才是 LobsterAI。模型名称对 LobsterAI 检测**无关紧要**
(LobsterAI 会话通常携带 `claude*` 模型)。

| 方面 | Claude Code | LobsterAI |
|---|---|---|
| 磁盘根目录 | `~/.claude/projects/` | 相同(同一根目录) |
| 存储技术 | 每会话一个 JSONL(`<uuid>.jsonl`) | 相同 |
| 记录 / 内容块 schema | 见 claude-code.md | 相同 |
| 子代理(Subagents) | `<session>/subagents/*.jsonl` | 相同 |
| Engram 来源标签 | `claude-code` | `lobsterai`("Lobster AI") |
| 区分依据 | 不适用 | **项目目录名路径分量** |

检测规则,以精确的正则 / 相等性检查表示:

```
^(?:\.?lobsterai(?:$|[._-].*))$     (case-insensitive, per path component)
```

当一个分量恰好等于 `lobsterai` / `.lobsterai`,或以
`lobsterai`/`.lobsterai` 开头并紧跟 `.`、`_`、`-`
之一时,该分量即匹配。
仅仅*包含*或*以该子串为前缀*的分量**不**
匹配(见 Gotchas)。

| 匹配? | 示例路径分量 | 结果 |
|---|---|---|
| ✓ | `lobsterai` | `lobsterai` |
| ✓ | `.lobsterai` | `lobsterai` |
| ✓ | `lobsterai-project` | `lobsterai` |
| ✓ | `.lobsterai-project` | `lobsterai` |
| ✗ | `.lobsteraiproject` (no separator) | `claude-code` |
| ✗ | `notlobsterai-project` (prefix) | `claude-code` |

它所在位置(两个适配器中的 file:line):

| 关注点 | Swift | TypeScript |
|---|---|---|
| `detectSource(model, filePath)`(先做路径检查) | `ClaudeCodeAdapter.swift:212-213` | `claude-code.ts:180-183` |
| 路径分量匹配器 | `hasLobsterAIPathComponent` `ClaudeCodeAdapter.swift:225-239`(字符串相等/`hasPrefix` 集合) | `hasLobsterAIPathComponent` `claude-code.ts:199-203`(上面的正则) |
| 仅定位符的提示(列表时) | `detectSourceHint` `ClaudeCodeAdapter.swift:241-244` | n/a |
| 来源枚举条目 | `SourceName.lobsterai` `SessionAdapter.swift:14` | `types.ts:14` |
| 显示标签 / 颜色 | n/a(Swift `SourceColors`) | `views.ts:21` `'Lobster AI'`,`:41` `#f1c40f` |

**存储位置细微差别:** 无。LobsterAI 共享 Claude Code 的根目录、文件
命名、JSONL 格式与监视器(watcher)路径(`watcher.ts:48` 列出了 `lobsterai`,但
它监视的是同一棵 `~/.claude/projects/` 树)。在 LobsterAI 的用户数据目录中存在
一个名为 `lobsterai.sqlite` 的独立原生应用存储,通过 `coworkStore.ts` /
`SqliteStore` 持久化。已确认的表包括 `cowork_sessions`、`cowork_messages`、
`user_memories` 与 `cowork_config`
([DeepWiki](https://deepwiki.com/netease-youdao/LobsterAI/4.2-session-management-and-ui))。
`mcp_servers` 表以及确切的 macOS 路径
`~/Library/Application Support/LobsterAI/lobsterai.sqlite` 是合理推断(公开文档
只说“在用户数据目录中”,在 macOS Electron 上解析为
`~/Library/Application Support/LobsterAI/`),但在所查阅的公开来源中**未**被
字面确认 —— 请将其视为未确认。无论哪种情况,Engram **不**读取这个存储;只有
Claude-Code 格式的 JSONL 转录会被索引。

## Engram mapping

分类只发生一次,在解析时,在共享的 Claude Code
解析器内部进行;LobsterAI 包装器只是过滤到最终得到的标签。

1. Claude Code 适配器列出 `~/.claude/projects/` 下的每一个 `.jsonl`(以及
   `subagents/*.jsonl`)
   定位符
   (`ClaudeCodeAdapter.swift:27-48`;派生来源的 Swift 列举:
   `listDerivedSessionLocators` `ClaudeCodeAdapter.swift:57-80`,它通过
   `detectSourceHint` 对每个定位符分类,只保留与 `source` 匹配的那些)。
2. 对每个会话,`detectSource` 在**任何基于模型的逻辑之前先运行
   路径检查**:如果某个路径分量匹配 LobsterAI 规则 →
   `lobsterai`;否则落入模型规则(若模型包含 `minimax` 则为
   `minimax`,否则为 `claude-code`)。
   - Swift:`ClaudeCodeAdapter.swift:212-223`
   - TypeScript:`claude-code.ts:180-191`
3. 仅当解析出的 `source == .lobsterai` 时,包装器才保留该会话,
   否则返回 `.unsupportedVirtualLocator`
   (`ClaudeCodeAdapter.swift:612-621`)。这可防止同一文件被基础适配器与
   派生适配器双重计数。
4. 在 UI 分组/健康度方面,LobsterAI 被报告为**派生自
   `claude-code`**(`web.ts:931-934` `DERIVED_SOURCES`)。

因此 `lobsterai` 与 `claude-code` 之分完全由
`detectSource` / `hasLobsterAIPathComponent`
(`ClaudeCodeAdapter.swift:212`+`225`,`claude-code.ts:180`+`199`)决定。下游一切
(记录解析、消息流式处理、分层)都原封不动地复用 Claude Code
路径。

## Gotchas

- **子串不算匹配 —— 仅限分隔符界定。** 该规则匹配一个
  *完整路径分量*,它等于 `lobsterai`,或以 `lobsterai` + 一个 `._-`
  分隔符开头。`notlobsterai-project` 与 `.lobsteraiproject` 是明确的
  诱饵(decoy),会解析为 `claude-code`(在
  `tests/adapters/claude-code.test.ts:84-166` 中断言)。
- **实时数据差异(本机):** 唯一看起来像 LobsterAI 的磁盘
  数据是 `~/.claude/projects/-Users-bing-lobsterai-project/`。它的名字是一个
  **cwd 编码**目录(`/Users/bing/lobsterai/project` →
  `-Users-bing-lobsterai-project`),所以 `lobsterai` 只是作为编码分量
  `-Users-bing-lobsterai-project` 的一个子串出现,而它**不是**
  分隔符界定的。因此当前适配器将这些会话分类为
  **`claude-code`,而非 `lobsterai`。** 检测依赖于一个字面命名为
  `lobsterai*`/`.lobsterai*` 的项目*目录*,而 LobsterAI 的 cwd 编码
  并不总会产生这种名字。(以磁盘上的实际情况为准:不要假设“目录包含
  lobsterai” ⇒ `lobsterai`。)
- **仅含索引的目录。** 该实时目录当前只持有
  `sessions-index.json`(一个 LobsterAI 应用索引,引用了
  已不再存在的 `<sessionId>.jsonl` 文件)。Engram 索引的是
  `.jsonl` 转录,而非 `sessions-index.json`;在没有 `.jsonl` 文件
  存在的情况下,这个目录什么也不会被索引。
- **模型混用对检测无害。** LobsterAI 会话通常携带
  `claude*` 模型,而路径检查先运行,所以模型永远不会把一条
  真正的 LobsterAI 路径降级。反过来,一个非 `lobsterai*`
  目录中的 `claude*` 模型仍保持 `claude-code`,即便它是由 LobsterAI 产生的。
- **MiniMax 共享这一完全相同的覆盖层。** 同一个 `ClaudeCodeDerivedSourceAdapter`
  和 `detectSource` 将 `minimax`(通过模型子串 `minimax`)、
  `lobsterai`(通过路径)与 `claude-code` 区分开来。`precondition`
  (`ClaudeCodeAdapter.swift:578`)将包装器限制到这两个派生
  来源。
- **Swift 与 TS 的实现形式不同,但行为相同。** Swift 使用一个
  显式的相等性/`hasPrefix` 集合(`ClaudeCodeAdapter.swift:230-237`);TS 使用
  一条正则(`claude-code.ts:202`)。两者都接受相同的 `._-` 分隔 /
  前导点变体;若任一方改动,需保持二者同步。

## Web-confirmation status (web-checked 2026-06-21)

- **Confirmed(官方):** LobsterAI 是一个 Claude-Code 派生客户端,它通过 Cowork
  的 `coworkRunner.ts` 子进程运行 Claude Agent SDK,使用 Claude Code 完全相同的
  JSONL schema 与位置(`~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`)将
  交互式会话写入 Claude Code 的存储区。Claude Agent SDK 与 Claude Code 是同一
  引擎,并会自动在该位置写入会话。
  [issue #139](https://github.com/netease-youdao/LobsterAI/issues/139)、
  [DeepWiki: Cowork System](https://deepwiki.com/netease-youdao/LobsterAI/4-cowork-system)、
  [Claude Agent SDK — sessions](https://code.claude.com/docs/en/agent-sdk/sessions)
- **Confirmed(官方):** cwd 编码规则(将绝对 cwd 中每个非字母数字字符替换为
  `-`,所以 `/Users/me/proj` → `-Users-me-proj`)真实存在,验证了实时数据这条
  gotcha:`-Users-bing-lobsterai-project` 是 `/Users/bing/lobsterai/project` 的
  cwd 编码目录(因此 `lobsterai` 只是一个内部子串,而非分隔符界定的分量,
  这些会话被分类为 `claude-code`)。
  [Claude Agent SDK — sessions](https://code.claude.com/docs/en/agent-sdk/sessions)
- **Confirmed(官方):** “Lobster AI”作为显示标签是准确的,而 LobsterAI 是一个
  真实、可识别的产品 —— 由网易有道开发的开源 Electron + React 桌面 AI 智能体
  (`netease-youdao/LobsterAI`,2026 年 2 月开源),其 Cowork 模式运行 Claude
  Agent SDK。
  [repo](https://github.com/netease-youdao/LobsterAI)、
  [allclaw.org](https://allclaw.org/entry/lobsterai)
- **Confirmed(部分,官方):** LobsterAI 会话通常携带 `claude*` 模型 —— 它默认
  使用 Anthropic Claude(OpenClaw 派生引擎默认 `anthropic/claude-sonnet-4-6`,
  并可选 `anthropic/claude-opus-4-6`),并内置一个 Claude 运行时适配器。但它明确
  支持多提供方(云端 API 或运行 DeepSeek/Qwen 的本地 Ollama),所以 `claude*`
  是一种倾向,而非保证。对 Engram 的检测无害,因为检测基于路径而非模型。
  [AGENTS.md](https://github.com/netease-youdao/LobsterAI/blob/main/AGENTS.md)、
  [openclawai.net](https://openclawai.net/blog/lobster-ai-youdao-desktop-agent)
- **Confirmed(部分,官方):** LobsterAI 维护着一个名为 `lobsterai.sqlite` 的
  独立 SQLite 应用存储(通过 `coworkStore.ts` / `SqliteStore`),其表包括
  `cowork_sessions`、`cowork_messages`、`user_memories` 与 `cowork_config`。
  `mcp_servers` 表以及确切路径
  `~/Library/Application Support/LobsterAI/lobsterai.sqlite` 在所查阅的公开来源中
  **未**被字面确认(文档只说“在用户数据目录中”);请将其视为合理但未确认。
  “Engram 不读取它”是 Engram 的设计陈述,而非可通过网络验证的 LobsterAI 事实。
  [DeepWiki: Cowork System](https://deepwiki.com/netease-youdao/LobsterAI/4-cowork-system)、
  [DeepWiki: Session Management and UI](https://deepwiki.com/netease-youdao/LobsterAI/4.2-session-management-and-ui)
- **Engram 内部设计 —— 不可通过网络验证:** 检测/分类的具体细节(正则形态、
  `hasLobsterAIPathComponent`、`ClaudeCodeDerivedSourceAdapter` 的 MiniMax/LobsterAI
  `precondition`、`DERIVED_SOURCES` 分组,以及 `unsupportedVirtualLocator` 的
  防双重计数)描述的是 Engram 自身的适配器代码,而非 LobsterAI 的磁盘格式,
  因此无法从 LobsterAI 来源通过网络回答。其唯一有外部依据的依赖项 —— Claude
  Agent SDK 的 cwd 编码 —— 已在上文确认。
  [Claude Agent SDK — sessions](https://code.claude.com/docs/en/agent-sdk/sessions)

## References (official sources)

- [netease-youdao/LobsterAI — official GitHub repo](https://github.com/netease-youdao/LobsterAI)
- [LobsterAI AGENTS.md — engine routing + SQLite storage](https://github.com/netease-youdao/LobsterAI/blob/main/AGENTS.md)
- [LobsterAI issue #139 — confirms `@anthropic-ai/claude-agent-sdk/cli.js` subprocess](https://github.com/netease-youdao/LobsterAI/issues/139)
- [DeepWiki: LobsterAI Cowork System (`coworkRunner.ts` / `coworkStore.ts` / `SqliteStore`)](https://deepwiki.com/netease-youdao/LobsterAI/4-cowork-system)
- [DeepWiki: LobsterAI Session Management and UI (`cowork_sessions` / `cowork_messages` tables)](https://deepwiki.com/netease-youdao/LobsterAI/4.2-session-management-and-ui)
- [Claude Agent SDK — Work with sessions (`~/.claude/projects/<encoded-cwd>/*.jsonl` + cwd encoding rule)](https://code.claude.com/docs/en/agent-sdk/sessions)
- [allclaw.org — LobsterAI entry](https://allclaw.org/entry/lobsterai)
- [openclawai.net — LobsterAI (Youdao desktop agent)](https://openclawai.net/blog/lobster-ai-youdao-desktop-agent)
