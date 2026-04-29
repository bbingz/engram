# PR7: Session Resume Workflow — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable resuming AI sessions from both the GUI (Resume button in top bar) and CLI (`engram --resume`), with auto-detection of installed CLI tools and terminal launching.

**Architecture:** Node-side `ResumeCoordinator` detects installed CLI tools, builds resume commands. HTTP API `POST /api/session/:id/resume` returns the command. Swift `ResumeDialog` shows UI, `TerminalLauncher` executes via AppleScript. CLI entry `src/cli/resume.ts` provides terminal-based resume flow.

**Tech Stack:** TypeScript (child_process for CLI detection), SwiftUI (sheet/dialog), AppleScript (terminal launch), Node CLI

**Spec:** `docs/superpowers/specs/2026-03-19-eight-prs-learning-from-agent-sessions-design.md` (PR7 section)

---

## File Structure

### New Files (Node)
| File | Responsibility |
|------|---------------|
| `src/core/resume-coordinator.ts` | Detect CLI tools, build resume commands per source |
| `src/cli/resume.ts` | CLI entry: `engram --resume` interactive flow |
| `tests/resume-coordinator.test.ts` | Test command building for each source |

### New Files (Swift)
| File | Responsibility |
|------|---------------|
| `macos/Engram/Views/Resume/ResumeDialog.swift` | Resume sheet: detected CLI, terminal picker, launch button |
| `macos/Engram/Views/Resume/TerminalLauncher.swift` | AppleScript-based terminal launch (Terminal.app, iTerm2, Ghostty) |

### Modified Files
| File | Changes |
|------|---------|
| `src/web.ts` | Add `POST /api/session/:id/resume` endpoint |
| `macos/Engram/Views/TopBarView.swift` | Wire Resume button to ResumeDialog |
| `package.json` | Update bin entry for CLI resume subcommand |

---

## Task 1: ResumeCoordinator (Node)

- [ ] **Step 1: Write tests**

```typescript
describe('ResumeCoordinator', () => {
  it('builds claude resume command', () => {
    const cmd = buildResumeCommand('claude-code', 'session-abc123', '/path/to/project')
    expect(cmd).toEqual({ tool: 'claude', command: 'claude', args: ['--resume', 'session-abc123'], cwd: '/path/to/project' })
  })
  it('builds codex resume command', () => {
    const cmd = buildResumeCommand('codex', 'session-xyz', '/path')
    expect(cmd).toEqual({ tool: 'codex', command: 'codex', args: ['--resume', 'session-xyz'], cwd: '/path' })
  })
  it('returns open-directory fallback for unsupported tools', () => {
    const cmd = buildResumeCommand('cursor', 'id', '/path')
    expect(cmd).toEqual({ tool: 'cursor', command: 'open', args: ['-a', 'Cursor', '/path'], cwd: '/path' })
  })
})
```

- [ ] **Step 2: Implement resume-coordinator.ts**

Key functions:
- `detectTool(source)`: run `which claude/codex/gemini` via `execSync`, return path + version or null
- `buildResumeCommand(source, sessionId, cwd)`: return `{ tool, command, args[], cwd }` or `{ error, hint }`
- Support: claude-code (--resume), codex (--resume), gemini-cli (--resume), cursor/others (open directory fallback)

- [ ] **Step 3: Add POST /api/session/:id/resume in web.ts**

Lookup session by ID, call `buildResumeCommand`, return JSON response.

- [ ] **Step 4: Tests + commit**

`git commit -m "feat(resume): add ResumeCoordinator with CLI detection and command building"`

---

## Task 2: CLI Resume (`engram --resume`)

- [ ] **Step 1: Create src/cli/resume.ts**

Interactive CLI flow:
1. Read daemon port from `~/.engram/settings.json` (default 3456)
2. Detect current directory (`process.cwd()`)
3. Call `GET /api/sessions?project={dirname}&limit=10` from daemon
4. Display numbered list: "1. Claude · title · 2h ago · 23 msgs"
5. Prompt user selection (readline)
6. Call `POST /api/session/{id}/resume`
7. Execute returned command via `execSync` or `spawn`

- [ ] **Step 2: Update package.json bin**

The existing bin entry points to `dist/index.js` (MCP server). Add a CLI dispatcher that checks args: if `--resume` → run resume flow, else → MCP server.

- [ ] **Step 3: Test manually**

```bash
cd ~/Code/coding-memory
node dist/cli/resume.js
```

- [ ] **Step 4: Commit**

`git commit -m "feat(resume): add CLI resume flow with interactive session selection"`

---

## Task 3: TerminalLauncher (Swift)

- [ ] **Step 1: Create TerminalLauncher.swift**

Static methods to launch commands in different terminals:
```swift
static func launch(command: String, args: [String], cwd: String, terminal: TerminalType)

enum TerminalType: String, CaseIterable {
    case terminal = "Terminal"
    case iterm = "iTerm2"
    case ghostty = "Ghostty"
}
```

Implementation uses NSAppleScript:
- Terminal.app: `tell app "Terminal" to do script "cd {cwd} && {command} {args}"`
- iTerm2: `tell app "iTerm2" to create window with default profile command "cd {cwd} && {command} {args}"`
- Ghostty: `open -a Ghostty` + write to stdin (or AppleScript if supported)

- [ ] **Step 2: Commit**

`git commit -m "feat(resume): add TerminalLauncher with Terminal/iTerm2/Ghostty support"`

---

## Task 4: ResumeDialog (Swift)

- [ ] **Step 1: Create ResumeDialog.swift**

Sheet view showing:
- Session title + source + time ago
- Detected CLI tool + version (fetched from `POST /api/session/{id}/resume`)
- Resume command preview (monospace)
- Terminal picker: segmented control (Terminal / iTerm2 / Ghostty)
- Cancel + Resume buttons

On Resume: call `TerminalLauncher.launch(...)` and dismiss.

- [ ] **Step 2: Wire to TopBarView**

Resume button in TopBarView sets `showResumeSheet = true` (disabled if `selectedSession == nil`). Attach `.sheet(isPresented:) { ResumeDialog(...) }`.

- [ ] **Step 3: Commit**

`git commit -m "feat(resume): add ResumeDialog with terminal picker"`

---

## Task 5: Final Verification

- [ ] **Step 1: npm test + npm run build**
- [ ] **Step 2: xcodegen generate + Xcode build**
- [ ] **Step 3: GUI test** — select session, click Resume, verify dialog shows, pick Terminal, click Resume, terminal opens with correct command
- [ ] **Step 4: CLI test** — `cd ~/Code/some-project && node dist/cli/resume.js` — select session, verify tool launches
- [ ] **Step 5: Final commit**

`git commit -m "feat(resume): PR7 complete — session resume from GUI and CLI"`
