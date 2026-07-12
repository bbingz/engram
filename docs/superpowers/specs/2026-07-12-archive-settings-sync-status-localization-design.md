# Archive Settings Sync Status and Localization Design

**Date:** 2026-07-12

**Status:** Approved in conversation

## Goal

Make the existing Archive & Storage settings page fully usable in Simplified
Chinese and show the authoritative Archive V2 dual-replica synchronization
state without adding polling, background work, or a second status model.

## UI behavior

Add a compact **Archive Sync Status** group above the reclamation controls. It
loads `EngramServiceArchiveV2StatusResponse` through the existing
`archiveV2Status()` client call when the page appears and when the user presses
**Refresh Status**. The same refresh runs after a recovery drill and after a
manual reclamation cycle.

The group shows:

- an overall state: synchronizing, complete, needs attention, disabled, or
  unavailable;
- dual-replica progress as `verified / remote-policy-eligible`;
- one row each for HQ and M1 with verified, retrying, queued, and quarantined
  counts;
- unbound archive count as secondary information, explicitly not labelled as a
  synchronization failure;
- a manual refresh button.

The page does not continuously poll. A status fetch failure leaves reclamation
controls usable and shows a localized unavailable state.

## Localization

Add Simplified Chinese translations for every user-visible string introduced
by `ArchiveSettingsSection`, including headings, buttons, explanatory text,
status labels, formatted counts, success messages, and errors. Dynamic strings
use `String(localized:)` and `String.localizedStringWithFormat`; HQ and M1 stay
unchanged as replica identifiers.

## Scope

- Reuse the existing service DTO and client method.
- Do not change archive capture, replication, recovery, or reclamation logic.
- Do not change the current enabled state or 30-day hot window.
- Do not add a timer, service command, database table, dependency, or settings
  option.

## Verification

- A failing-then-passing XCTest checks that the page calls `archiveV2Status()`
  and exposes stable accessibility identifiers for the summary and both
  replicas.
- A catalog test checks every Archive settings key has a translated `zh-Hans`
  value.
- The focused Engram tests and Debug build pass.
- After local deployment, the Chinese page is inspected and the displayed
  counts are compared with the installed CLI `archive status --json` output.
