// macos/Engram/Core/BrowseReloadCoalescer.swift
import Foundation

/// Browse pages (Sessions / Home / Timeline / Projects / Activity) key an
/// `.task(id:)` on their filters plus `serviceStatusStore.totalSessions`. That
/// task re-runs for two very different reasons: the user changed a filter, or a
/// background index tick bumped the session count. Treating both the same way
/// makes indexing churn cancel in-flight loads and reset pagination/scroll (#3).
///
/// This helper is pure so the branch is unit-testable.
enum BrowseReloadCoalescer {
    /// Debounce window for index-tick reloads. Rapid ticks cancel and restart
    /// the `.task`, so only the settled count triggers a refresh.
    static let debounceInterval: Duration = .milliseconds(600)

    /// - Parameters:
    ///   - filterKey: the current filter signature (everything except the
    ///     session count).
    ///   - lastFilterKey: the signature at the previous load (`nil` on first run).
    /// - Returns: whether to debounce before loading, and whether to preserve the
    ///   already-loaded pagination. A filter change reloads immediately from the
    ///   first page; an index tick (filters unchanged) debounces and preserves.
    static func plan<Key: Equatable>(
        filterKey: Key,
        lastFilterKey: Key?
    ) -> (debounce: Bool, preservePagination: Bool) {
        let filtersChanged = lastFilterKey != filterKey
        return (debounce: !filtersChanged, preservePagination: !filtersChanged)
    }

    /// When an index tick refreshes a paginated list, refetch the rows already on
    /// screen (rounded up to whole pages) instead of collapsing to the first page.
    static func refreshLimit(loadedCount: Int, pageSize: Int) -> Int {
        guard pageSize > 0 else { return loadedCount }
        guard loadedCount > pageSize else { return pageSize }
        let pages = (loadedCount + pageSize - 1) / pageSize
        return pages * pageSize
    }
}
