# Claude Code Profile Registry and Custom Roots Design

**Date:** 2026-07-13

**Status:** Approved in conversation

## Goal

Continuously discover, index, and Archive V2-sync Claude Code transcripts stored
outside the default `~/.claude/projects` directory, including the user's
`~/.claude-*` API-model profiles and user-added Claude Code `projects` roots.
Empty transcripts must not create remote replica work, settings must show
per-profile coverage, and adding a custom path must not silently expand local
source-deletion authority.

## Current Problem

The shipped `ClaudeCodeAdapter` owns one projects root. The service therefore
discovers only `~/.claude/projects`, while shell wrappers that set
`CLAUDE_CONFIG_DIR=~/.claude-<profile>` write valid Claude Code JSONL under
separate `projects` roots.

The 2026-07-13 inventory found 13 such roots containing 14,460 JSONL files and
2.72 GiB of source bytes. Only 9,144 live files had historical index rows, 5,316
were not represented by a current index path, and Archive V2 had captured zero
files from those roots. Of the missing files, 5,269 were subagent transcripts
and 354 were lightweight structural-empty candidates.

The current parser already returns `ParserFailure.noVisibleMessages` for a
Claude transcript with no visible user, assistant, or tool messages. Exact
capture intentionally happens before parsing, however, so those captures remain
unbound and can be reconsidered by later binding sweeps unless the archive
catalog records a terminal disposition.

## Scope

This change includes:

- automatic discovery of the default root and direct home-directory matches for
  `~/.claude-*/projects`;
- user-managed additional Claude Code `projects` roots at arbitrary absolute
  filesystem locations;
- one multi-root Claude Code adapter used by indexing, transcript replay, exact
  capture, and Archive V2 binding;
- deterministic profile identity and per-profile local status;
- terminal archive handling for generation-matched `noVisibleMessages` files;
- a Data Sources settings card for automatic discovery, add/remove, and status;
- bounded IPC models and secure mutation of `~/.engram/settings.json`; and
- deployment of the resulting native app/service plus the same-release
  RemoteServer package to HQ and M1.

This change does not claim to parse arbitrary unknown agent formats. A custom
root must use the Claude Code `projects/<project>/*.jsonl` and
`projects/<project>/<session>/subagents/*.jsonl` layout. Future formats must add
their own adapter and exact-archive contract before they can appear in the root
registry.

## Considered Approaches

### A. Hard-code the 13 current wrapper directories

This is small but makes future wrappers invisible, provides no user control,
and repeats the same single-root assumption elsewhere. It is not selected.

### B. Parse `.zshrc` and derive `CLAUDE_CONFIG_DIR` values

This could mirror today's wrappers, but shell files contain executable logic and
may contain credentials. Engram must not evaluate or parse shell configuration
to discover transcripts. It is not selected.

### C. Bounded profile registry with automatic and custom roots

Resolve the default root, enumerate only direct `~/.claude-*` children, merge a
validated custom-root list, and give one adapter the resulting roots. This keeps
discovery bounded, does not inspect credentials, supports future wrappers, and
allows explicit paths outside the home-directory naming convention. It is
selected.

## Settings Contract

`~/.engram/settings.json` gains one optional object:

```json
{
  "claudeCodeProfiles": {
    "autoDiscover": true,
    "customProjectsRoots": [
      "/absolute/path/to/projects"
    ]
  }
}
```

Absence means `autoDiscover=true` and no custom roots. The default
`~/.claude/projects` root is always included when it exists and is not controlled
by this toggle.

The service is the only settings writer. It uses `SecureSettingsFileWriter` so
unrelated settings keys, owner-only permissions, and atomic replacement remain
intact. Configuration accepts at most 64 custom roots. Each path must be:

- absolute, standardized, and no longer than 4,096 UTF-8 bytes;
- an existing readable directory when first added;
- the `projects` directory itself, not its parent `CLAUDE_CONFIG_DIR`;
- distinct after symlink resolution; and
- neither `/`, the user's home directory, `~/.engram`, nor a descendant of the
  local Archive V2 store.

The settings file may retain a custom directory that later becomes unavailable;
status reports it as missing and the adapter skips it without blocking other
profiles. Removing a custom root stops future discovery but never deletes its
sessions, captures, receipts, or source files.

## Profile Resolution

Add a pure `ClaudeCodeProfileResolver` in the shared adapter layer. It returns a
stable, path-sorted list of:

```swift
struct ClaudeCodeProfile: Equatable, Sendable {
    enum Origin: String, Codable, Sendable { case `default`, automatic, custom }
    let id: String
    let displayName: String
    let projectsRoot: String
    let origin: Origin
    let sourceReclamationAllowed: Bool
}
```

IDs are deterministic hashes of the canonical root path with a readable origin
prefix. Display names use `Default` for `~/.claude/projects`, the
`.claude-` suffix for automatically discovered roots, and the selected folder's
parent name for custom roots.

Automatic discovery enumerates only direct children of the home directory whose
name starts with `.claude-`, then checks for an immediate `projects` child. It
does not recursively scan the home directory, open profile settings, inspect
environment variables, or read shell files.

Default and automatic `~/.claude-*` profiles participate in the already-approved
global reclamation policy. Arbitrary custom roots are index-and-archive only in
this release: `sourceReclamationAllowed=false` prevents source-file quarantine
or deletion even after dual receipts. Local CAS reclamation may still follow the
existing independent gates.

## Adapter Architecture

`ClaudeCodeAdapter` becomes a multi-root adapter while preserving its existing
single-root initializer for focused tests and callers. At every locator listing
it resolves the current profile set, walks each existing projects root, merges
and deterministically sorts absolute locators, and removes canonical duplicates.

Parsing remains the existing Claude JSONL parser. For locators under the default
root, current MiniMax/LobsterAI derived-source behavior remains unchanged. A
locator under an automatic or custom profile is normalized to:

- `source = claude-code`;
- `originator = claude-code`; and
- the model reported by the transcript, unchanged.

Profile identity is maintained by the registry's canonical root-to-locator
mapping and exposed in profile status. This release does not add provider names
to `SourceName` and does not add a `sessions` schema column solely for a path
label. That avoids an enum explosion for arbitrary API providers while keeping
the actual model searchable through the existing model field.

The exact archive descriptor chooses the longest canonical profile root that
contains the locator and creates a replay-relative path under that root. A
locator outside every currently resolved root fails closed as unsupported. Full
absolute locators remain the capture identity, so equal filenames in different
profiles cannot collide.

The derived MiniMax/LobsterAI adapters enumerate only the default root. They must
not reclassify an API-profile locator away from `claude-code`, because Archive V2
capture and binding require the adapter source and indexed source to agree.

## Empty Transcript Disposition

Capture-before-parse remains unchanged:

```text
exact local capture -> index parse -> bind or terminal-ignore -> remote policy
```

The Archive V2 index snapshot is extended with a bounded per-target parse state.
When all of the following are true, the service marks the capture
`ignored_no_visible_messages` and advances the binding cursor without creating a
binding or replica receipt:

1. `file_index_state` uses the current schema;
2. parse status is terminal with `failure_kind=noVisibleMessages`;
3. device, inode, size, and mtime match the fresh file stat; and
4. the exact capture generation matches that same fresh stat.

An ignored capture remains in the local catalog and its CAS objects are not
deleted by this operation. Missing, transient, malformed, stale-generation, and
ambiguous cases are not converted to ignored. Existing eligible legacy bindings
are not reclassified because remote eligibility and receipts are intentionally
immutable after publication.

Catalog unbound queries select only binding-runnable captures. Status reports
ignored-empty counts separately so an empty backlog cannot masquerade as work or
cause repeated binding sweeps.

## Service and IPC

Add two capability-gated commands:

- `claudeCodeProfilesStatus` takes no payload and returns current settings plus a
  bounded profile status list;
- `configureClaudeCodeProfiles` accepts the full desired `autoDiscover` value and
  custom-root array, validates it, atomically persists it, and signals the
  Archive V2 backlog drainer.

Each status row contains only local data:

- profile ID, display name, canonical path, origin, availability, and
  reclamation eligibility;
- discovered JSONL files and source bytes;
- indexed live locator count;
- exact captures and ignored-empty captures;
- HQ-verified and M1-verified manifest counts; and
- pending/error state represented by bounded symbols, never raw parser or remote
  response bodies.

Status is calculated only on explicit page load or Refresh. It does not create a
timer or background polling loop. Newly saved roots are visible immediately,
Archive V2 discovery is signalled immediately, and indexing uses the next normal
index opportunity. The deployed auto-discovered roots are picked up during the
service startup scan.

## Settings UI

The Data Sources settings page gains one `Claude Code Profiles` group above MCP
setup:

- an `Automatically discover ~/.claude-*/projects` toggle;
- rows for default, automatic, and custom profiles;
- per-row discovered, indexed, archived, HQ, M1, ignored-empty, availability,
  and local-reclamation state;
- `Add Projects Folder...`, using `NSOpenPanel` in directory-only mode;
- Remove for custom rows only; and
- Save and Refresh buttons with stable accessibility identifiers.

The UI uses localized English and Simplified Chinese strings. It explains that
the selected folder must be a Claude Code `projects` directory, custom folders
are not automatically locally reclaimed, and configuration changes do not
delete existing data.

## Failure Handling

- One unreadable profile is omitted from locator enumeration and reported
  without blocking other profiles.
- Invalid custom settings fail closed: existing valid settings remain unchanged.
- Duplicate/symlink-equivalent roots collapse to one canonical profile.
- A configuration change during an active capture sweep applies on the next
  resolver refresh; generation validation prevents stale publication.
- Removing a profile while capture or replication is active does not cancel or
  delete already captured work.
- Profile status database failures return a symbolic unavailable state while the
  app remains usable.
- Remote failure behavior, retry jitter, dual receipts, recovery drills, and
  reclamation gates remain owned by Archive V2 and are not bypassed.

## Testing

Focused tests must prove:

- default-on automatic discovery, bounded direct-child matching, deterministic
  ordering, symlink deduplication, and custom validation;
- multi-root locator enumeration, source normalization, default derived-source
  preservation, archive replay roots, and runtime settings refresh;
- secure settings round-trip without clobbering unrelated keys;
- IPC compatibility, validation, capability registration, and bounded status;
- settings UI identifiers, English/Chinese localization, add/remove behavior,
  and no automatic polling;
- generation-matched `noVisibleMessages` capture becomes terminal ignored and
  never gets binding/receipt work;
- stale or non-terminal parse state is not ignored;
- custom-root source reclamation is denied while default/automatic profiles keep
  the existing global reclamation behavior; and
- the backlog drainer handles the expanded locator set without restoring the old
  15-minute/20-row throughput ceiling.

## Deployment and Verification

The implementation is complete only when:

1. focused Core, Service, App, wire, localization, archive safety, and backlog
   drainer tests pass;
2. full relevant Swift schemes and repository checks pass;
3. an independent review finds no unresolved Critical or Important issue;
4. the feature branch is merged to `main` and pushed;
5. a Release app is built, verified, atomically installed to
   `/Applications/Engram.app`, and its app/service processes are restarted;
6. the same-release RemoteServer package is deployed and restarted on HQ and M1
   with matching package hashes and healthy telemetry;
7. the live profile status discovers the expected `~/.claude-*` roots;
8. a non-empty API-profile transcript reaches both verified receipts;
9. a canonical empty transcript produces no remote receipt; and
10. no custom-root source file is eligible for local reclamation.
