import Foundation

/// Canonical set of source ids whose Swift adapters are cache/transcript-only.
/// Windsurf reads existing Cascade JSONL cache files; Antigravity reads those
/// legacy cache files plus CLI brain transcripts. These surface a "Cache only"
/// badge in the app so the intentional no-live-sync state is honest rather than
/// implied as a broken/active sync.
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
