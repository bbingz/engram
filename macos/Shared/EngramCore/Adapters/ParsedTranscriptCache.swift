import Foundation

/// Small bounded LRU cache of fully-parsed transcripts, keyed on
/// (locator, file mtime + size). Whole-document adapters (Gemini CLI, Cline,
/// VS Code, Cursor) parse the entire file/DB before windowing, so paginated
/// reads would otherwise re-parse the whole document on every page. Caching the
/// parsed `[NormalizedMessage]` lets paging within a browsing session parse
/// once; the mtime/size signature invalidates the entry the moment the file
/// changes.
///
/// The cache is deliberately tiny (a handful of entries) so it respects the
/// existing 10 MB per-file size guard without accumulating memory across a
/// large scan.
actor ParsedTranscriptCache {
    struct Signature: Equatable, Sendable {
        let mtime: Double  // modificationDate as timeIntervalSince1970
        let size: Int64

        /// Signature of the file backing `path`. `path` may be a plain file
        /// locator or the on-disk file that backs a virtual locator (the caller
        /// strips any `?composer=` / `::` suffix first).
        static func forFile(_ path: String) -> Signature? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                return nil
            }
            let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            return Signature(mtime: mtime, size: size)
        }
    }

    private struct Entry {
        let signature: Signature
        let messages: [NormalizedMessage]
    }

    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var order: [String] = []  // least-recent first, most-recent last

    init(capacity: Int = 4) {
        self.capacity = max(capacity, 1)
    }

    /// Returns the cached parse for `locator` when the stored signature matches,
    /// else `nil`. A `nil` signature (stat failed) never hits the cache.
    func cached(locator: String, signature: Signature?) -> [NormalizedMessage]? {
        guard let signature,
              let entry = entries[locator],
              entry.signature == signature
        else {
            return nil
        }
        touch(locator)
        return entry.messages
    }

    /// Stores a fresh parse. A `nil` signature is not cached (it could not be
    /// validated for staleness).
    func store(locator: String, signature: Signature?, messages: [NormalizedMessage]) {
        guard let signature else { return }
        entries[locator] = Entry(signature: signature, messages: messages)
        touch(locator)
        while order.count > capacity, let evict = order.first {
            order.removeFirst()
            entries.removeValue(forKey: evict)
        }
    }

    private func touch(_ locator: String) {
        if let index = order.firstIndex(of: locator) {
            order.remove(at: index)
        }
        order.append(locator)
    }
}
