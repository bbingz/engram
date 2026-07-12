import Darwin
import EngramCoreRead
import Foundation

public enum ArchiveLocatorClassification: Equatable, Sendable {
    case declaredSingleFile(URL)
    case missing
    case unsupportedComposite
    case unsupportedVirtual
    case unsupportedAdapter
    case unsafe(String)
}

public enum ArchiveLocatorClassifier {
    public static func normalize(_ locator: String) -> String? {
        ArchiveSourceDescriptor.normalizedAbsolutePath(locator)
    }

    public static func classify(
        adapter: any SessionAdapter,
        locator: String
    ) async throws -> ArchiveLocatorClassification {
        try Task.checkCancellation()
        if isVirtual(locator) {
            return .unsupportedVirtual
        }
        guard let adapter = adapter as? any ExactArchiveSourceAdapter else {
            return .unsupportedAdapter
        }
        let descriptor = try await adapter.archiveSourceDescriptor(locator: locator)
        try Task.checkCancellation()
        return classify(descriptor: descriptor, enumeratedLocator: locator)
    }

    static func classify(
        descriptor: ArchiveSourceDescriptor,
        enumeratedLocator: String
    ) -> ArchiveLocatorClassification {
        guard let normalizedLocator = normalize(enumeratedLocator),
              descriptor.locator == normalizedLocator else {
            return .unsafe("descriptor locator does not match enumerated locator")
        }
        guard descriptor.files.count == 1 else {
            return .unsupportedComposite
        }
        let sourceURL = descriptor.files[0].sourceURL.standardizedFileURL
        guard sourceURL.path == normalizedLocator else {
            return .unsafe("descriptor file does not match enumerated locator")
        }

        var info = stat()
        guard lstat(sourceURL.path, &info) == 0 else {
            return errno == ENOENT ? .missing : .unsafe("lstat failed: \(errno)")
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            return .declaredSingleFile(sourceURL)
        case S_IFDIR:
            return .unsupportedComposite
        case S_IFLNK:
            return .unsafe("symlink locator")
        default:
            return .unsafe("non-regular locator")
        }
    }

    static func isVirtual(_ locator: String) -> Bool {
        locator.contains("::") || locator.contains("?composer=")
    }
}
