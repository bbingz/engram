import Foundation

public enum ArchiveSourceDescriptorError: Error, Equatable, Sendable {
    case invalidLocator(String)
    case locatorFileMismatch(locator: String, file: String)
    case invalidRelativePath(String)
    case pathOutsideRoot(path: String, root: String)
}

public struct ArchiveSourceFileDescriptor: Equatable, Sendable {
    public let sourceURL: URL
    public let replayRelativePath: String

    public init(sourceURL: URL, replayRelativePath: String) throws {
        guard sourceURL.isFileURL,
              let normalizedSource = ArchiveSourceDescriptor.normalizedAbsolutePath(sourceURL.path)
        else {
            throw ArchiveSourceDescriptorError.invalidLocator(sourceURL.path)
        }
        do {
            _ = try ArchiveReplayLayout(
                strategy: .singleFile,
                relativePaths: [replayRelativePath]
            )
        } catch {
            throw ArchiveSourceDescriptorError.invalidRelativePath(replayRelativePath)
        }
        self.sourceURL = URL(fileURLWithPath: normalizedSource)
        self.replayRelativePath = replayRelativePath
    }
}

/// Adapter-authored declaration of every file needed to replay one locator.
/// Task 3 only accepts the single-file shape, but the array keeps composite
/// declarations explicit so they can be rejected instead of guessed.
public struct ArchiveSourceDescriptor: Equatable, Sendable {
    public let locator: String
    public let files: [ArchiveSourceFileDescriptor]

    public init(locator: String, files: [ArchiveSourceFileDescriptor]) throws {
        guard let normalizedLocator = Self.normalizedAbsolutePath(locator) else {
            throw ArchiveSourceDescriptorError.invalidLocator(locator)
        }
        self.locator = normalizedLocator
        self.files = files
    }

    public static func singleFile(
        locator: String,
        sourceURL: URL,
        replayRelativePath: String
    ) throws -> ArchiveSourceDescriptor {
        guard let normalizedLocator = normalizedAbsolutePath(locator),
              let normalizedFile = normalizedAbsolutePath(sourceURL.path)
        else {
            throw ArchiveSourceDescriptorError.invalidLocator(locator)
        }
        guard normalizedLocator == normalizedFile else {
            throw ArchiveSourceDescriptorError.locatorFileMismatch(
                locator: normalizedLocator,
                file: normalizedFile
            )
        }
        return try ArchiveSourceDescriptor(
            locator: normalizedLocator,
            files: [
                ArchiveSourceFileDescriptor(
                    sourceURL: URL(fileURLWithPath: normalizedFile),
                    replayRelativePath: replayRelativePath
                ),
            ]
        )
    }

    public func singleFileReplayLayout() throws -> ArchiveReplayLayout {
        guard files.count == 1 else {
            throw ArchiveV2ValidationError.invalidReplayPathCount(
                expected: 1,
                actual: files.count
            )
        }
        return try ArchiveReplayLayout(
            strategy: .singleFile,
            relativePaths: [files[0].replayRelativePath]
        )
    }

    public static func normalizedAbsolutePath(_ value: String) -> String? {
        guard value.hasPrefix("/"), !value.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    public static func relativePath(path: URL, under root: URL) throws -> String {
        guard let normalizedPath = normalizedAbsolutePath(path.path),
              let normalizedRoot = normalizedAbsolutePath(root.path)
        else {
            throw ArchiveSourceDescriptorError.invalidLocator(path.path)
        }
        let pathComponents = URL(fileURLWithPath: normalizedPath).pathComponents
        let rootComponents = URL(fileURLWithPath: normalizedRoot).pathComponents
        guard pathComponents.count > rootComponents.count,
              Array(pathComponents.prefix(rootComponents.count)) == rootComponents
        else {
            throw ArchiveSourceDescriptorError.pathOutsideRoot(
                path: normalizedPath,
                root: normalizedRoot
            )
        }
        let relative = pathComponents.dropFirst(rootComponents.count).joined(separator: "/")
        do {
            _ = try ArchiveReplayLayout(strategy: .singleFile, relativePaths: [relative])
        } catch {
            throw ArchiveSourceDescriptorError.invalidRelativePath(relative)
        }
        return relative
    }
}

/// Conformance is the archive eligibility boundary. A regular file alone is
/// never enough to opt an adapter into exact capture.
public protocol ExactArchiveSourceAdapter: SessionAdapter {
    func archiveSourceDescriptor(locator: String) async throws -> ArchiveSourceDescriptor
}
