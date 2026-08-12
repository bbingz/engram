# Engram autopilot loop — 2026-08-12

## Control plane
- **Scheduler**: durable Grok task every **15m**, `fire_immediately=true`
  - Task id: `019ff3bc9938` (session scheduler; re-create if lost after process restart)
- **Objective**: continuous stewardship — CI green → merge PR #305 when safe; otherwise fix/ship next queue item; keep Codex `retro-handler` fed; update daily retro.
- **PR**: https://github.com/bbingz/engram/pull/305 (`feat/retro-p1-2026-08-12`)
- **Codex pane**: Herdr `w5:p1` / name `retro-handler`
- **Hard stops**: no notarize/v* without `docs/TODO.md` auth; no force-push main; no Node product startup.

## Each tick
1. PR checks / merge if CLEAN
2. Integrate idle Codex work or prompt next OPEN queue item
3. Land ≥1 product or test advance when not blocked
4. Update queue + daily retro when material

## Human override
- Pause: stop the scheduled task in Grok scheduler UI / delete task `019ff3bc9938`
- Deploy/release: still requires explicit human auth per TODO
