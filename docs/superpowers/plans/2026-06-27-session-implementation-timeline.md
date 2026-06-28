# Session Implementation Timeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first usable session implementation digest and project changelog timeline from human intent plus AI completion reports.

**Architecture:** Add a deterministic CoreRead extractor that turns normalized transcript messages into work beats, operation events, session digests, and timeline items. Persist beats as an indexing side table so App/service/MCP reads do not reparse raw transcripts. Keep LLM refinement deferred; the first version must be local, reproducible, and testable.

**Tech Stack:** Swift 5.9, GRDB, existing SessionAdapter normalized messages, EngramCoreRead/Write tests.

---

### Task 1: Core Extraction Model

**Files:**
- Create: `macos/Shared/EngramCore/Indexing/ImplementationDigestExtractor.swift`
- Test: `macos/EngramCoreTests/ImplementationDigestExtractorTests.swift`

- [ ] Write RED tests for filtering system/machine turns, selecting completion reports over progress updates, classifying `合吧` as operation-only, and merging adjacent same-work dates.
- [ ] Implement the smallest extractor API:
  - `ImplementationDigestExtractor.extract(messages:) -> [SessionImplementationBeat]`
  - `ImplementationTimelineBuilder.build(beats:) -> [ImplementationTimelineItem]`
- [ ] Run targeted tests until green.

### Task 2: Persist Beats During Indexing

**Files:**
- Modify: `macos/Shared/EngramCore/Indexing/IndexingEventTypes.swift`
- Modify: `macos/EngramCoreWrite/Database/EngramMigrations.swift`
- Modify: `macos/EngramCoreWrite/Indexing/SwiftIndexer.swift`
- Modify: `macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift`
- Test: `macos/EngramCoreTests/Database/MigrationRunnerTests.swift`
- Test: `macos/EngramCoreTests/SessionSnapshotClassificationTests.swift`

- [ ] Add `session_work_beats` table with one row per extracted beat.
- [ ] Add `implementationBeats` to `AuthoritativeSessionSnapshot`.
- [ ] Have `SwiftIndexer.streamStats` feed visible user/assistant messages into the extractor.
- [ ] Replace a session's beat rows when a healthy snapshot is merged.
- [ ] Run targeted migration/writer tests until green.

### Task 3: Backfill Existing Reliable Sessions

**Files:**
- Modify: `macos/EngramCoreWrite/Indexing/EngramDatabaseIndexer.swift`
- Modify: `macos/EngramService/Core/EngramServiceRunner.swift`
- Test: `macos/EngramCoreTests/IndexerParityTests.swift`
- Test: `macos/EngramServiceCoreTests/EngramServiceIPCTests.swift`

- [ ] Add a direct backfill for reliable sources with no `session_work_beats`.
- [ ] Run it during startup after instruction backfill and before heavy indexing.
- [ ] Keep terminal parse failures non-fatal and bounded.
- [ ] Run targeted backfill/startup tests until green.

### Task 4: First Read Surface

**Files:**
- Modify: `macos/Engram/Core/Database.swift`
- Modify: `macos/Engram/Views/Pages/TimelinePageView.swift`
- Test: existing targeted UI/model tests if available.

- [ ] Add `implementationTimeline(days:humanDriven:)` read query joining beats to sessions.
- [ ] Add a Timeline segmented mode for `Sessions` vs `Work`; Work mode renders dated implementation items and suppresses operation-only events.
- [ ] Run targeted app/core tests or a build if UI tests are too broad.

### Task 5: Durable Closeout

**Files:**
- Modify: `.memory`
- Modify: `CHANGELOG.md`

- [ ] Record changed behavior, verification, and remaining risks.
- [ ] Run `git diff --check`.
