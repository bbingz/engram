# 2026-04-29 Open-source publication

- Public repo: https://github.com/bbingz/engram
- Public branch/history: orphan `public-main`, remote `main` at `dadd3362 Initial public release`.
- Private full-history backup: `/Users/bing/codex-exports/engram-private-full-history-20260429.bundle`.
- Remote cleanup: old remote feature/fix branches deleted; `v1.0` tag moved to the clean root commit.
- Repo visibility: public; description updated; GitHub secret scanning and push protection enabled.
- Release: https://github.com/bbingz/engram/releases/tag/v1.0, universal zip SHA256 `0ca9e48bc60d62469bf50c90f57e33d4921582089c6987c21bfcc7087c61268e`.
- Verification: sensitive-string scan on HEAD clean except expected redaction regex/docs, `npm run lint`, `npm test` (113 files / 1276 tests), unsigned macOS Debug build passed.
- Guardrail: do not push local private-history branches to the public remote; public remote should keep only `main` and `v1.0`.
