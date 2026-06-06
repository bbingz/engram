# Claude/Qoder Project Directory Reconcile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a collision-safe startup reconcile that repairs historical Claude Code/Qoder project directories left under obsolete encoded names.

**Architecture:** Add a focused planner/applier that scans grouped source roots, derives target basenames from structured `cwd` values, and repairs only unambiguous directories whose corrected target does not already exist. Wire the Swift product into startup maintenance; mirror the planner in TypeScript as the reference implementation.

**Tech Stack:** Swift `EngramCoreWrite` + XCTest, TypeScript Node fs/promises + Vitest.

---

## Files

- Modify: `macos/EngramCoreWrite/ProjectMove/Sources.swift`
  - Owns Swift source-root helpers plus the reconcile types, planner, and
    applier. The implementation lives here to avoid regenerating the existing
    dirty `project.pbxproj` just to compile a new Swift file.
- Modify: `macos/EngramCoreWrite/Indexing/StartupBackfills.swift`
  - Adds result type/protocol method and emits startup maintenance events.
- Modify: `macos/EngramCoreWrite/Indexing/StartupComposition.swift`
  - Wires the real startup database wrapper to the reconcile applier.
- Modify: `macos/EngramCoreTests/ProjectMove/SessionSourcesTests.swift`
  - Behavior tests for Swift planner/applier, placed in the already compiled
    project-move source-root test class.
- Modify: `macos/EngramCoreTests/StartupBackfillTests.swift`
  - Startup invocation and event test coverage.
- Create: `src/core/project-move/grouped-dir-reconcile.ts`
  - TypeScript reference planner/applier.
- Create: `tests/core/project-move/grouped-dir-reconcile.test.ts`
  - Vitest coverage for TypeScript reference implementation.
- Modify: `.memory`
  - Durable handoff note after implementation.
- Modify: `CHANGELOG.md`
  - Reverse-chronological closeout entry after verification.

## Task 1: Swift Reconcile Planner/Applier

**Files:**
- Modify: `macos/EngramCoreWrite/ProjectMove/Sources.swift`
- Test: `macos/EngramCoreTests/ProjectMove/SessionSourcesTests.swift`

- [ ] **Step 1: Write failing Swift tests**

Add tests for these behaviors:

```swift
func testPlansAndAppliesMisencodedClaudeDirectory() throws
func testPlansAndAppliesMisencodedQoderDirectory() throws
func testDryRunDoesNotRenameDirectory() throws
func testSkipsWhenTargetDirectoryAlreadyExists() throws
func testApplyCountsCollisionWhenTargetAppearsAfterPlanning() throws
func testSkipsAmbiguousDirectoryWithMultipleEncodedTargets() throws
func testSkipsAlreadyCorrectDirectory() throws
func testSkipsImmediateChildSymlink() throws
func testDoesNotUseNestedSymlinkForCwdEvidence() throws
func testMissingRootIsNoop() throws
```

Use temporary roots shaped like `.claude/projects/<dir>/session.jsonl`. For the
misencoded case, use `cwd = "/Users/bing/-Code-/CCTV_Admin"` and buggy
basename `-Users-bing--Code--CCTV_Admin`; expect target
`-Users-bing--Code--CCTV-Admin`.

- [ ] **Step 2: Verify RED**

Run:

```bash
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -only-testing:EngramCoreTests/GroupedDirReconcileTests CODE_SIGNING_ALLOWED=NO
```

Expected: fail to compile because `GroupedDirReconcile` does not exist. In the
actual branch, use `-only-testing:EngramCoreTests/SessionSourcesTests` because
the tests live in the existing compiled source-root test class.

- [ ] **Step 3: Implement minimal Swift planner/applier**

Create:

```swift
public struct GroupedDirReconcileResult: Equatable, Sendable {
    public var scannedDirs: Int
    public var plannedRenames: Int
    public var appliedRenames: Int
    public var collisions: Int
    public var ambiguous: Int
    public var issues: Int
}

public enum GroupedDirReconcile {
    public static func run(
        roots: [SourceRoot],
        dryRun: Bool = false
    ) -> GroupedDirReconcileResult
}
```

Implementation requirements:

- Include only roots whose id is `.claudeCode` or `.qoder`.
- Enumerate immediate child directories with `lstat`; skip symlinks.
- Walk session files inside each child via `SessionSources.walkSessionFiles`.
- Extract structured cwd values from each JSON line using top-level `cwd` and
  `payload.cwd`.
- Derive target basename with `root.encodeProjectDir`.
- Skip already-correct directories.
- Skip ambiguous directories when discovered target basenames are not exactly
  one value.
- Skip collision when target exists and `realpath` differs from source.
- Apply with no-overwrite semantics when `dryRun == false`:
  - Swift: use `FileManager.default.copyItem(atPath: source, toPath: target)`,
    which fails if the target already exists, then remove the source only after
    the copy succeeds. If copy fails because the target appeared after planning,
    count a collision and leave the source intact. If copy succeeds but source
    removal fails, count an issue and leave both directories for manual cleanup.
  - TS: use `await cp(source, target, { recursive: true, force: false, errorOnExist: true })`,
    then `await rm(source, { recursive: true, force: false })` only after the
    copy succeeds. Treat `EEXIST`/`ERR_FS_CP_EEXIST` as an apply-time collision.
  - Tests must simulate target-appears-after-planning by creating the target
    after collecting a dry-run plan and before apply, or by using the
    planner/apply split if implemented. The expected result is collision + no
    source deletion.

- [ ] **Step 4: Verify GREEN**

Run the same source-root test command.
Expected: all new tests pass and the output must show non-zero executed tests.

## Task 2: Swift Startup Wiring

**Files:**
- Modify: `macos/EngramCoreWrite/Indexing/StartupBackfills.swift`
- Modify: `macos/EngramCoreWrite/Indexing/StartupComposition.swift`
- Modify: `macos/EngramCoreTests/StartupBackfillTests.swift`

- [ ] **Step 1: Write failing startup tests**

Add a `RecordingStartupDatabase.reconcileGroupedSourceDirs()` method to the
test double and assert `runStartupMaintenanceAndParents` calls it before
`downgradeSubagentTiers`, `cleanupStaleMigrations`, and the final `ready`
count calls. The expected call-order fragment must be:

```swift
[
    "deduplicateFilePaths",
    "optimizeFts",
    "vacuumIfNeeded",
    "reconcileInsights",
    "reconcileGroupedSourceDirs",
    "backfillFilePaths"
]
```

Add an event assertion:

```swift
XCTAssertTrue(events.contains {
    $0.event == "db_maintenance"
      && $0.payload["action"] == .string("reconcile_grouped_dirs")
      && $0.payload["applied"] == .int(2)
})
```

- [ ] **Step 2: Verify RED**

Run:

```bash
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -only-testing:EngramCoreTests/StartupBackfillTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because the protocol method is missing, or assertion
failure because the call/event is absent.

- [ ] **Step 3: Wire startup database**

Add `func reconcileGroupedSourceDirs() throws -> GroupedDirReconcileResult` to
`StartupBackfillDatabase`. Implement it in `WriterStartupBackfillDatabase` by
calling:

```swift
GroupedDirReconcile.run(roots: SessionSources.roots())
```

Call it in `runStartupMaintenanceAndParents` after `reconcileInsights()` and
before `backfillFilePaths()`. Emit
`db_maintenance/action=reconcile_grouped_dirs` when any count is non-zero.

- [ ] **Step 4: Verify GREEN**

Run the same `StartupBackfillTests` command.
Expected: pass.

## Task 3: TypeScript Reference Implementation

**Files:**
- Create: `src/core/project-move/grouped-dir-reconcile.ts`
- Create: `tests/core/project-move/grouped-dir-reconcile.test.ts`

- [ ] **Step 1: Write failing Vitest tests**

Mirror Swift behavior:

```ts
it('plans and applies a misencoded claude directory')
it('plans and applies a misencoded qoder directory')
it('does not rename in dry-run mode')
it('skips target collisions')
it('counts a collision when the target appears after planning')
it('skips ambiguous directories')
it('skips already-correct directories')
it('skips immediate child symlinks')
it('does not use nested symlinks for cwd evidence')
it('returns zero counts for missing roots')
```

- [ ] **Step 2: Verify RED**

Run:

```bash
npx vitest run tests/core/project-move/grouped-dir-reconcile.test.ts
```

Expected: fail because the module does not exist.

- [ ] **Step 3: Implement TypeScript planner/applier**

Export:

```ts
export interface GroupedDirReconcileResult {
  scannedDirs: number;
  plannedRenames: number;
  appliedRenames: number;
  collisions: number;
  ambiguous: number;
  issues: number;
}

export async function reconcileGroupedProjectDirs(opts?: {
  roots?: SourceRoot[];
  dryRun?: boolean;
}): Promise<GroupedDirReconcileResult>
```

Use `getSourceRoots()` by default, include only `claude-code` and `qoder`, use
`lstat` to skip symlinks, parse structured cwd values from JSON lines, skip
collisions, and apply with the same no-overwrite copy/delete strategy as Swift
only when not dry-run.

- [ ] **Step 4: Verify GREEN**

Run the same Vitest command.
Expected: pass.

## Task 4: Full Verification, Review, Commit

**Files:**
- Modify: `.memory`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Run focused checks**

```bash
npx vitest run tests/core/project-move/grouped-dir-reconcile.test.ts tests/core/project-move/encode-cc.test.ts tests/core/project-move/orchestrator.integration.test.ts
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -only-testing:EngramCoreTests/SessionSourcesTests -only-testing:EngramCoreTests/StartupBackfillTests -only-testing:EngramCoreTests/OrchestratorTests CODE_SIGNING_ALLOWED=NO
npx biome check src/core/project-move/grouped-dir-reconcile.ts tests/core/project-move/grouped-dir-reconcile.test.ts
git diff --check
```

- [ ] **Step 2: Request subagent review**

Ask a read-only reviewer to inspect the diff against this plan, focusing on
collision safety including apply-time races, structured-cwd proof, symlink
behavior at every traversed level, Qoder parity, and startup blast radius. Fix
any Critical or Important finding before proceeding.

- [ ] **Step 3: Update durable handoff**

Append a concise English entry to `.memory` and a reverse-chronological
`CHANGELOG.md` entry with verification commands and residual risks.

- [ ] **Step 4: Commit and push**

```bash
git add macos/EngramCoreWrite/ProjectMove/Sources.swift \
  macos/EngramCoreWrite/Indexing/StartupBackfills.swift \
  macos/EngramCoreWrite/Indexing/StartupComposition.swift \
  macos/EngramCoreTests/ProjectMove/SessionSourcesTests.swift \
  macos/EngramCoreTests/StartupBackfillTests.swift \
  src/core/project-move/grouped-dir-reconcile.ts \
  tests/core/project-move/grouped-dir-reconcile.test.ts \
  .memory CHANGELOG.md
git commit -m "fix(project-move): reconcile grouped source dirs"
git push
```

## Self-Review

- Spec coverage: The plan covers Swift product startup, TS reference parity,
  collision safety, ambiguity skips, dry-run, and missing-root no-op.
- Placeholder scan: No TBD/TODO placeholders remain.
- Type consistency: Swift result type and TS result interface use the same
  field names for cross-runtime handoff.
