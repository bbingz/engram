# Design Doc: Windowed archive source reads

- **Status**: Accepted
- **Owner**: retro PR-2
- **Date**: 2026-07-31
- **Related**: MCP retrospective findings F01 (high) and F18 (medium) on merged
  PRs #277–#281; `docs/remote-mcp-2026-07-28-design.md` (windowed-read section)

## Problem

The remote MCP tool `archive_get_session` reads a byte window of an archived
source. Two defects were confirmed by the retrospective on #277–#281.

**F01 — a windowed read costs a whole-source read.** `MCPRemoteEndpoint.getSession`
called `ArchiveStore.getManifest`, which routes through `validatedManifest`. That
helper fetched, AES-GCM-decrypted and SHA-256-folded **every** chunk of the source
to check `wholeSourceSHA256` before the window loop sliced any bytes; the chunks
the window actually needed were then fetched a second time by that loop. A 1-byte
window on a 1 GiB source processed 1 GiB. There is no manifest cache, so paging a
1 GiB source at the 256 KiB default cost ~4096 full-source validations. Both the
code comment at the call site and the design doc claimed the opposite ("skipped
without being fetched or decrypted").

**F18 — pages could not be reassembled.** The window was sliced at arbitrary byte
offsets and decoded with `String(decoding:as: UTF8.self)`, a *repairing* decode. A
multibyte character straddling an `offset + max_bytes` boundary became U+FFFD in
the tail of one page and in the head of the next, so concatenating pages did not
reproduce the source and the loss was silent — no flag in `structuredContent`.
CJK/emoji transcripts hit this at most page seams.

## Goals / Non-goals

- Goals: window read cost proportional to `max_bytes`, not to source size;
  byte-exact paging (concatenated pages == source); no loss of integrity for the
  bytes actually served; existing full-validation callers unchanged.
- Non-goals: caching manifests or chunks; changing chunk size; rate limiting;
  fixing the other retrospective findings (F02–F17, F19–F29).

## Current state

Before this change (at `0bd4d5fc`):

- `macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift:1093` —
  `getSession` called `store.getManifest(digest:)`, decoded the manifest itself,
  then ran a window loop that called `store.getObject` per overlapping chunk.
- `macos/EngramRemoteServer/Core/ArchiveStore.swift:406` — `getManifest` read the
  manifest envelope and then called `validatedManifest(..., durableReferences:
  false)`.
- `macos/EngramRemoteServer/Core/ArchiveStore.swift:630-655` — `validatedManifest`
  looped over every chunk: `getObject`, `rawByteCount` check, `rawSHA256` check,
  and a running `wholeSourceSHA256` fold.
- `macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift:1129` — the window
  was decoded with the repairing `String(decoding:as: UTF8.self)`, and
  `nextOffset` advanced by the raw window byte count.

## Proposed design

### `ArchiveStore.readSourceWindow(manifestDigest:offset:maxBytes:)`

A new read path alongside `getManifest`, returning `ArchiveSourceWindow`
(`manifest`, `bytes`, `totalBytes`). It:

1. validates the digest and reads the manifest **envelope** through the existing
   `readEnvelope` (AES-GCM open with the manifest digest as authenticated data,
   plus the directory-identity checks that path already performs);
2. decodes it through the new `decodedManifest` helper — digest match plus
   canonical decode, which also enforces the model-level chunk invariants
   (contiguous ordinals, non-final chunks exactly `chunkSize`, chunk sizes summing
   to `rawByteCount`);
3. walks chunks in ordinal order accumulating a running offset from
   `rawByteCount`, and calls `getObject` **only** for chunks overlapping
   `[offset, offset + maxBytes)`;
4. verifies each fetched chunk against its manifest reference (`rawByteCount` and
   `rawSHA256`) via the new `chunkObject` helper;
5. returns the assembled window plus the source's total byte count.

`validatedManifest` is refactored onto the same two helpers, so whole-chunk
verification is now *scoped* rather than duplicated: `decodedManifest` +
`chunkObject` per chunk + the `wholeSourceSHA256` fold. Its behavior, error codes
and callers (`putManifest`, `getManifest`, `createReceiptWithResult`) are
unchanged.

### Integrity relaxation — deliberate and bounded

`readSourceWindow` does **not** compute `wholeSourceSHA256`. That fold is only
computable by reading every chunk, which is exactly the cost the path exists to
avoid; keeping it would make the fix a no-op.

What still holds for the bytes served:

- the manifest is authenticated (envelope AEAD keyed to its digest) and its
  digest is checked against the request's `manifest_sha256`;
- every chunk object is authenticated by its own envelope AEAD, and additionally
  checked against the manifest's `rawByteCount` and `rawSHA256`;
- so a served byte range is bound to the manifest the caller asked for, and a
  tampered or substituted chunk object still fails closed.

What is given up: the cross-chunk statement "these chunks, concatenated, are the
source that was captured". A manifest that is internally consistent but lists
chunks whose concatenation does not match `wholeSourceSHA256` would be detected by
`getManifest` and not by `readSourceWindow`. Such a manifest can only be produced
by the archive writer, which computes both from the same bytes, and the manifest
itself is AEAD-authenticated at rest — so this is a writer-bug class, not an
attacker class. `GET /v2/archive/manifests/{digest}` keeps the strong check.

### UTF-8 page boundaries

`getSession` snaps the window to UTF-8 scalar boundaries before the (still
repairing) decode:

- **start** snaps forward past continuation bytes, only when `offset > 0`;
- **end** snaps backward to drop a scalar the window cuts short, only when the
  window does not reach EOF (at EOF there is no next page to complete it);
- `offset` in `structuredContent` reports the **effective** start, so
  `offset + byteCount == nextOffset` always holds. For a caller paging from
  `nextOffset` (or from 0) the effective start always equals the requested one;
  it differs only when the caller picks an offset inside a character;
- `nextOffset` advances from the snapped end, so no byte is skipped or repeated
  and concatenated pages reproduce the source exactly.

Degradation, by design: a window too small to hold one whole scalar is returned
unsnapped, so paging still advances (that page keeps the pre-fix behavior); and
genuinely invalid stored bytes still repair to U+FFFD, as they must for a tool
whose result type is text.

No new response field is required. `offset` is the only field whose meaning is
sharpened (effective, not requested), and it is unchanged for every caller that
starts at 0 or follows `nextOffset`.

No schema change, no migration, no backfill, no service IPC change, no UI change,
no new Swift file.

## Invariants affected

- **1. Single-Writer Discipline** — preserved. `readSourceWindow` is read-only.
- **8. Service Socket Security** — untouched; this is the remote HTTP endpoint,
  not the local service socket.
- **12. EngramMCP Is Read-Only Except Service IPC Writes** — the remote endpoint
  keeps the stronger form: no write path at all.

No new invariant. The archive red lines (no `EngramCoreRead`/`EngramCoreWrite` in
`EngramRemoteServerCore`, no DELETE routes) are untouched and still enforced by
their existing guard tests.

## Alternatives considered

- **Cache validated manifests in `ArchiveStore`.** Turns O(source) per page into
  O(source) once per process, but still pays a full-source read on the first page
  of any source and adds cache invalidation to a security-sensitive store. Loses.
- **Keep `wholeSourceSHA256` but verify only overlapping chunks.** Impossible: the
  fold is over all chunks in order.
- **Verify the whole source once per receipt at publish time and record it.**
  `createReceiptWithResult` already does verify the whole source when the receipt
  is created, which is why the read-path fold is redundant defense rather than the
  only defense — but making the read path *depend* on that record would add state
  this change does not need.
- **Return the window as base64 to avoid UTF-8 questions entirely.** Breaks the
  tool contract (`text`) and every existing client; a transcript window is text.
- **Snap only the end, not the start.** Sufficient for clients that follow
  `nextOffset`, but leaves an arbitrary-offset caller with a leading U+FFFD and a
  reported offset that does not match the returned bytes.

## Test plan

- `ArchiveStoreTests.testWindowedSourceReadSkipsNonOverlappingChunks_repro` —
  two-chunk source (8 MiB + tail); chunk 0's object file is **deleted**, then a
  window inside chunk 1 is read successfully. Fails before the fix
  (`missingReference`). Also asserts `getManifest` still throws there.
- `ArchiveStoreTests.testWindowedSourceReadRejectsCorruptOverlappingChunk_repro` —
  one ciphertext byte of the overlapping chunk is flipped in place; the windowed
  read fails `conflict`, while a window over the untouched chunk still reads.
- `ArchiveStoreTests.testGetManifestStillValidatesEveryChunkObject` — pins the
  full-validation path: `getManifest` reads and verifies every chunk.
- `ArchiveRouteTests.testMCPGetSessionPagesUTF8ScalarBoundariesExactly_repro` —
  a mixed 1/2/3/4-byte transcript paged at `max_bytes: 7`: no page contains
  U+FFFD, `offset`/`byteCount`/`nextOffset` agree, and the concatenation equals
  the source. Fails before the fix at the first seam.
- Not tested: the degradation case where `max_bytes` is smaller than a single
  scalar (documented behavior, no client uses it — the default is 256 KiB), and
  the writer-bug manifest class the integrity relaxation gives up on (it cannot be
  constructed through the public store API).

## Rollout

Server-side only: rebuild and redeploy `EngramRemoteServer` on the archive host.
No client change is required — the response shape is additive-compatible, and
`offset` only differs for callers that request a mid-character offset. Revert is a
plain revert of the commits; nothing persists.

## Risks and open questions

- **Integrity posture change** (low likelihood, medium impact): a corrupted
  archive whose per-chunk digests still match would be served by the read path and
  caught only by `getManifest`. Accepted above.
- **Snapping arithmetic** (low/low): an off-by-one would either duplicate or drop
  bytes at a seam; the paging test asserts exact reassembly rather than page
  contents, so any such error fails it.
- **Open**: `archive_list_captures` still pays a durable `getReceipt` per entry
  (retrospective F07) — same tool family, different fix, out of scope here.
