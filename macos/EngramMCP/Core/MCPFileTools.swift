import Darwin
import EngramCoreWrite
import Foundation

enum MCPFileTools {
    /// Single source of truth for how many AI session roots `project_review`
    /// scans. tools/list descriptions must derive the count from this, not
    /// hardcode a stale number (L06).
    static var projectReviewSourceRootCount: Int {
        let home = ProcessInfo.processInfo.environment["HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return ProjectReviewPathSupport.sourceRoots(
            homeDirectory: URL(fileURLWithPath: home, isDirectory: true)
        ).count
    }

    static func projectReview(
        oldPath: String,
        newPath: String,
        maxItems: Int
    ) -> OrderedJSONValue {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let homeDirectory = URL(fileURLWithPath: home, isDirectory: true)
        let review = ReviewScan.run(
            oldPath: oldPath,
            newPath: newPath,
            homeDirectory: homeDirectory
        )
        let cap = max(maxItems, 1)

        var entries: [(String, OrderedJSONValue)] = [
            ("own", .array(review.own.prefix(cap).map(OrderedJSONValue.string))),
            ("other", .array(review.other.prefix(cap).map(OrderedJSONValue.string))),
        ]

        let ownOverflow = max(0, review.own.count - cap)
        let otherOverflow = max(0, review.other.count - cap)
        if ownOverflow > 0 || otherOverflow > 0 {
            entries.append((
                "truncated",
                .object([
                    ("own", .int(ownOverflow)),
                    ("other", .int(otherOverflow)),
                ])
            ))
        }

        return .object(entries)
    }
}

func trimTrailingSlash(_ path: String) -> String {
    guard path.count > 1 else { return path }
    return path.hasSuffix("/") ? String(path.dropLast()) : path
}

private func findReferencingFiles(root: String, needle: String) -> [String] {
    guard !needle.isEmpty, FileManager.default.fileExists(atPath: root) else { return [] }
    let allowedExtensions = Set(["json", "jsonl"])
    let allowedFilenames = Set([".project_root", "workspace.yaml"])
    guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey]) else {
        return []
    }

    var hits: [String] = []
    for case let fileURL as URL in enumerator {
        guard allowedExtensions.contains(fileURL.pathExtension)
            || allowedFilenames.contains(fileURL.lastPathComponent)
        else { continue }
        if boundedRegularFileContains(path: fileURL.path, needle: needle) {
            hits.append(fileURL.path)
        }
    }
    return hits.sorted()
}

private func boundedRegularFileContains(path: String, needle: String) -> Bool {
    let needleBytes = Array(needle.utf8)
    guard !needleBytes.isEmpty else { return false }

    let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }

    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
        return false
    }

    let chunkSize = 64 * 1_024
    var buffer = [UInt8](repeating: 0, count: chunkSize)
    var overlap: [UInt8] = []
    let retainedCount = max(needleBytes.count - 1, 0)

    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            read(descriptor, bytes.baseAddress, bytes.count)
        }
        guard count >= 0 else { return false }
        if count == 0 { return false }

        var searchable = overlap
        searchable.append(contentsOf: buffer.prefix(count))
        if Data(searchable).range(of: Data(needleBytes)) != nil {
            return true
        }
        overlap = retainedCount > 0 ? Array(searchable.suffix(retainedCount)) : []
    }
}
