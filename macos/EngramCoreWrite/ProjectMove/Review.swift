// macos/EngramCoreWrite/ProjectMove/Review.swift
// Mirrors src/core/project-move/review.ts (Node parity baseline).
//
// Post-move audit scan. For each session source root, finds files still
// referencing `oldPath` and classifies the hit as either:
//   - `own`   — under the migrated project's own CC dir, OR under any
//               non-CC source. These are real leftovers that need
//               attention; auto-fix sweep targets these.
//   - `other` — under a DIFFERENT project's Claude Code dir. Historical
//               reference left alone by design.
import Foundation

public struct ReviewResult: Equatable, Sendable {
    public let own: [String]
    public let other: [String]

    public init(own: [String], other: [String]) {
        self.own = own
        self.other = other
    }
}

public enum ReviewScan {
    /// Scan every configured source for residual refs to `oldPath` and
    /// classify own vs other. The own-scope CC dir is derived from
    /// `newPath` via `ClaudeCodeProjectDir.encode`.
    public static func run(
        oldPath: String,
        newPath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ReviewResult {
        let roots = SessionSources.roots(homeDirectory: homeDirectory)
        let ccRoot = roots.first { $0.id == .claudeCode }?.path
        let ownCcDir = ClaudeCodeProjectDir.encode(newPath)

        var ownSet = Set<String>()
        var otherSet = Set<String>()

        for root in roots {
            let hits = SessionSources.findReferencingFiles(
                root: root.path, needle: oldPath
            )
            for hit in hits {
                let isOther: Bool
                if let cc = ccRoot, isUnder(path: hit, parent: cc) {
                    let firstSeg = firstSegment(of: hit, after: cc)
                    isOther = firstSeg != ownCcDir
                } else {
                    isOther = false
                }
                if isOther {
                    otherSet.insert(hit)
                } else {
                    ownSet.insert(hit)
                }
            }
        }

        return ReviewResult(
            own: ownSet.sorted(),
            other: otherSet.sorted()
        )
    }

    // MARK: - internals

    private static func isUnder(path: String, parent: String) -> Bool {
        guard !parent.isEmpty else { return false }
        let normalizedParent = parent.hasSuffix("/") ? parent : parent + "/"
        return path.hasPrefix(normalizedParent)
    }

    /// First path segment under `parent`. Mirrors Node's
    /// `relative(parent, hit).split('/')[0]`.
    private static func firstSegment(of path: String, after parent: String) -> String {
        let normalizedParent = parent.hasSuffix("/") ? parent : parent + "/"
        guard path.hasPrefix(normalizedParent) else { return "" }
        let suffix = path.dropFirst(normalizedParent.count)
        if let slash = suffix.firstIndex(of: "/") {
            return String(suffix[..<slash])
        }
        return String(suffix)
    }
}
