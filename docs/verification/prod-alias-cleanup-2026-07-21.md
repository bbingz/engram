# Prod project_aliases cleanup — 2026-07-21

## Context

After shipping #228 (`3ba6e2a3`) — basename normalize for `manage_project_alias`
plus `rewritePathShapedProjectAliases` on every mutating touch — authorized a
one-shot production cleanup of legacy absolute-path rows in
`~/.engram/index.sqlite`.

## Preconditions

- Installed app: `1.0.4 (20260721142837)` Developer ID, `release-verify` PASS
- EngramService running: `~/.engram/run/engram-service.sock` + `cmd.token`
- Backup: `~/.engram/backups/index.sqlite.before-alias-cleanup-20260721144628.bak`
  (sqlite `.backup`, 18 alias rows)

## Before (RO)

- Total: **18**
- Path-shaped (`/` in alias or canonical): **10**
- Basename: **8**

Notable path rows:

| alias (raw) | canonical (raw) | rewrite outcome |
|---|---|---|
| `/Users/bing/-Code-` | `/Users/bing/-Code-/_maintenance` | `-Code-` → `_maintenance` |
| `/Users/bing/-Code-/CIP/3-cip-patched` | `/Users/bing/-Code-/CIP-Patched` | basename pair kept |
| `/Users/bing/-Code-/CIP/4-cip-pro` | `/Users/bing/-Code-/CIP-Pro` | basename pair kept |
| `/Users/bing/-Code-/CIP/CIP_Pro` | `/Users/bing/-Code-/CIP-Pro` | basename pair kept |
| `/Users/bing/-Code-/CIP/5-cip-Salary` | `/Users/bing/-Code-/CIP-Salary` | basename pair kept |
| `/Users/bing/-Code-/CIP/6-cip-Salary-decompiled` | `/Users/bing/-Code-/CIP-Salary` | basename pair kept |
| `/Users/bing/-Code-/CIP-Salary-Decompiled` | `/Users/bing/-Code-/CIP-Salary` | basename pair kept |
| `/Users/bing/-Code-/CIP-Salary/CIP-Salary-Decompiled` | `/Users/bing/-Code-/CIP-Salary` | basename pair kept (dedup with above) |
| `/Users/bing/-Code-/CIP-Salary/CIP-Salary` | `/Users/bing/-Code-/CIP-Salary` | **self-key dropped** |
| `/Users/bing/-Code-/_项目扫描报告` | `/Users/bing/-Code-/_maintenance/_项目扫描报告` | **self-key dropped** |

## Write path

Official service only — no direct SQLite writer:

```text
manageProjectAlias add
  old_project=coding-memory
  new_project=engram
  actor=alias-cleanup-script
```

Framed Unix-socket request with `capability_token` from `~/.engram/run/cmd.token`.
Response: `ok:true`, `changed:0` (pair already existed); rewrite still ran inside
the same writer transaction via `rewritePathShapedProjectAliases`.

## After (RO)

- Total: **15**
- Path-shaped: **0**
- Basename: **15**
- Expected set matched actual (no missing / no unexpected extras)

Bidirectional resolution samples (undirected BFS over alias↔canonical):

- `CIP-Pro` ↔ `{4-cip-pro, CIP_Pro, CIP-Pro}`
- `CIP-Salary` ↔ `{5-cip-Salary, 6-cip-Salary-decompiled, CIP-Salary, CIP-Salary-Decompiled}`
- `-Code-` ↔ `{-Code-, _maintenance}`

## Rollback

Stop Engram / EngramService, then restore from the backup above (WAL-safe
copy into `~/.engram/index.sqlite`), then relaunch the app.

## Residual (product, not dirty data)

Same-basename different-parent full-path ghost remove edge (Codex P2 from
#228 review): normalize rejects equal basenames before remove can target a
path-shaped row that rewrites to a self-key. No production rows of that shape
remained after this cleanup. Track only if a future host reintroduces
path-shaped aliases without going through the fixed service path.
