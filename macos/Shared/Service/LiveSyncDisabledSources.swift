import Foundation

/// Canonical set of source ids whose adapters are constructed with
/// `enableLiveSync: false` in `SessionAdapterFactory.defaultAdapters()`
/// (Windsurf is cache-only; Antigravity reads brain transcripts / legacy cache
/// but does not run live gRPC sync). These surface a "Cache only" badge in the
/// app so the intentional live-sync-off state is honest rather than implied as
/// a broken/active sync.
///
/// The ids are the `SourceName` raw values `"windsurf"` / `"antigravity"`.
/// `"antigravity-legacy"` is intentionally excluded: it is never a real
/// `sessions.source` value (only a defensive string in adapter classification),
/// so including it would be dead and never match.
enum LiveSyncDisabledSources {
    static let ids: Set<String> = ["windsurf", "antigravity"]

    static func isLiveSyncDisabled(_ source: String) -> Bool {
        ids.contains(source)
    }
}
