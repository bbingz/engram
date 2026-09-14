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

    fileprivate init(validatedFileSetURL: URL, replayRelativePath: String) {
        self.sourceURL = validatedFileSetURL
        self.replayRelativePath = replayRelativePath
    }
}

/// Adapter-authored declaration of every file needed to replay one locator.
/// Composite capture requires the explicit confined file-set factory; ordinary
/// multi-file declarations remain unsupported rather than guessed.
public struct ArchiveSourceDescriptor: Equatable, Sendable {
    public let locator: String
    public let files: [ArchiveSourceFileDescriptor]
    public let fileSetRoot: URL?
    public let absentFiles: [ArchiveSourceFileDescriptor]
    public let vscodeWorkspaceContext: ArchiveVSCodeWorkspaceContext?
    public let geminiProjectContext: ArchiveGeminiProjectContext?
    public let kimiProjectContext: ArchiveKimiProjectContext?

    public init(locator: String, files: [ArchiveSourceFileDescriptor]) throws {
        guard let normalizedLocator = Self.normalizedAbsolutePath(locator) else {
            throw ArchiveSourceDescriptorError.invalidLocator(locator)
        }
        self.locator = normalizedLocator
        self.files = files
        self.fileSetRoot = nil
        self.absentFiles = []
        self.vscodeWorkspaceContext = nil
        self.geminiProjectContext = nil
        self.kimiProjectContext = nil
    }

    /// Explicit file-set declaration. Ordinary multi-file declarations remain
    /// unsupported; this factory supplies the confined root and absence set.
    public static func fileSet(
        locator: String, root: URL, files: [URL], absentFiles: [URL] = [],
        vscodeWorkspaceContext: ArchiveVSCodeWorkspaceContext? = nil,
        geminiProjectContext: ArchiveGeminiProjectContext? = nil,
        kimiProjectContext: ArchiveKimiProjectContext? = nil
    ) throws -> ArchiveSourceDescriptor {
        guard [vscodeWorkspaceContext != nil, geminiProjectContext != nil, kimiProjectContext != nil].filter({ $0 }).count <= 1 else {
            throw ArchiveSourceDescriptorError.invalidLocator(locator)
        }
        guard root.isFileURL, !files.isEmpty,
              files.count + absentFiles.count <= ArchiveReplayLayout.maximumFileSetDependencies,
              let rootPath = fileSetAbsolutePath(root.path), rootPath != "/",
              let normalizedLocator = fileSetAbsolutePath(locator),
              files.contains(where: { fileSetAbsolutePath($0.path) == normalizedLocator }) else {
            throw ArchiveSourceDescriptorError.invalidLocator(locator)
        }
        let normalizedRoot = URL(fileURLWithPath: rootPath)
        let rootPrefix = rootPath + "/"
        func descriptors(_ urls: [URL]) throws -> [ArchiveSourceFileDescriptor] {
            try urls.map { url in
                guard url.isFileURL, let path = fileSetAbsolutePath(url.path) else {
                    throw ArchiveSourceDescriptorError.invalidLocator(url.path)
                }
                guard path.utf8.starts(with: rootPrefix.utf8) else {
                    throw ArchiveSourceDescriptorError.pathOutsideRoot(path: path, root: rootPath)
                }
                let relative = String(path.dropFirst(rootPrefix.count))
                _ = try ArchiveReplayLayout(strategy: .singleFile, relativePaths: [relative])
                return ArchiveSourceFileDescriptor(validatedFileSetURL: URL(fileURLWithPath: path),
                    replayRelativePath: relative)
            }.sorted { $0.replayRelativePath.utf8.lexicographicallyPrecedes($1.replayRelativePath.utf8) }
        }
        let present = try descriptors(files)
        let absent = try descriptors(absentFiles)
        let paths = (present + absent).map(\.replayRelativePath)
        let aliases = paths.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        guard Set(aliases).count == paths.count,
              paths.allSatisfy({ $0.utf8.count <= ArchiveReplayLayout.maximumRelativePathBytes
                  && $0.split(separator: "/").count <= ArchiveReplayLayout.maximumRelativePathDepth }),
              !aliases.contains(where: { path in aliases.contains(where: { $0.hasPrefix(path + "/") }) }) else {
            throw ArchiveSourceDescriptorError.invalidRelativePath(locator)
        }
        return ArchiveSourceDescriptor(validatedLocator: normalizedLocator, files: present,
            fileSetRoot: normalizedRoot, absentFiles: absent, vscodeWorkspaceContext: vscodeWorkspaceContext, geminiProjectContext: geminiProjectContext,
            kimiProjectContext: kimiProjectContext)
    }

    private init(validatedLocator: String, files: [ArchiveSourceFileDescriptor],
                 fileSetRoot: URL, absentFiles: [ArchiveSourceFileDescriptor],
                 vscodeWorkspaceContext: ArchiveVSCodeWorkspaceContext?,
                 geminiProjectContext: ArchiveGeminiProjectContext?,
                 kimiProjectContext: ArchiveKimiProjectContext?) {
        self.locator = validatedLocator
        self.files = files
        self.fileSetRoot = fileSetRoot
        self.absentFiles = absentFiles
        self.vscodeWorkspaceContext = vscodeWorkspaceContext
        self.geminiProjectContext = geminiProjectContext
        self.kimiProjectContext = kimiProjectContext
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

    /// Lexical-only normalization for no-follow capture. Foundation's
    /// standardizedFileURL can rewrite /private/var into the /var symlink and
    /// treats existing and absent paths differently. Never resolve links here.
    public static func fileSetAbsolutePath(_ value: String) -> String? {
        guard value.hasPrefix("/"), !value.utf8.contains(0) else { return nil }
        let components = value.split(separator: "/")
        guard !components.contains("..") else { return nil }
        return "/" + components.filter { $0 != "." }.joined(separator: "/")
    }

    public static func isCursorModernFileSet(_ manifest: ArchiveSourceManifest) -> Bool {
        manifest.schemaVersion == 2 && manifest.source == "cursor" && manifest.sessionID == nil
            && cursorModernSessionID(manifest.replayLayout, locator: manifest.locator) != nil
    }

    /// Closed raw modern inputs; legacy shared databases require a separate scoped export.
    /// Missing primary directories and source SHM/journal are observation-only.
    public static func cursorModernSessionID(_ layout: ArchiveReplayLayout, locator: String) -> String? {
        guard layout.strategy == .fileSet, layout.geminiProjectContext == nil,
              layout.kimiProjectContext == nil, layout.sqliteSession == nil,
              let files = layout.files, (1...4).contains(files.count),
              let absent = layout.absentRelativePaths, let entrypoint = layout.entrypointRelativePath,
              let canonical = fileSetAbsolutePath(locator), canonical.utf8.elementsEqual(locator.utf8),
              locator.utf8.count > entrypoint.utf8.count + 1,
              locator.utf8.suffix(entrypoint.utf8.count + 1).elementsEqual(("/" + entrypoint).utf8) else { return nil }
        let paths = files.map(\.relativePath)
        var store: String?
        var transcript: String?
        var nativeID: String?
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            let id: String
            if parts.count == 4, parts[0] == "chats", parts[3] == "store.db" {
                guard store == nil, !parts[1].hasPrefix("."), !parts[2].hasPrefix(".") else { return nil }
                store = path
                id = parts[2]
            } else if parts.count == 5, parts[0] == "projects", parts[2] == "agent-transcripts" {
                guard transcript == nil, !parts[1].hasPrefix("."), !parts[3].hasPrefix("."),
                      parts[4].utf8.elementsEqual((parts[3] + ".jsonl").utf8) else { return nil }
                transcript = path
                id = parts[3]
            } else { continue }
            if let nativeID, !nativeID.utf8.elementsEqual(id.utf8) { return nil }
            nativeID = id
        }
        guard let nativeID, let primary = transcript ?? store,
              entrypoint.utf8.elementsEqual(primary.utf8) else { return nil }
        var allowed = Set<Data>()
        var expectedAbsent = Set<Data>()
        let present = Set(paths.map { Data($0.utf8) })
        if let transcript { allowed.insert(Data(transcript.utf8)) }
        if let store {
            allowed.insert(Data(store.utf8))
            let parent = store.split(separator: "/").dropLast().joined(separator: "/")
            for path in [store + "-wal", parent + "/meta.json"] {
                let key = Data(path.utf8)
                if present.contains(key) { allowed.insert(key) }
                else { expectedAbsent.insert(key) }
            }
        }
        guard present == allowed, Set(absent.map { Data($0.utf8) }) == expectedAbsent else { return nil }
        return nativeID
    }

    /// Source-specific shape shared by Collector, replica admission and HQ.
    /// All replay paths belong to one session below the configured session-state
    /// root. The three canonical optional inputs must be present or absent.
    public static func isVSCodeFileSet(_ manifest: ArchiveSourceManifest) -> Bool {
        manifest.schemaVersion == 7 && manifest.source == "vscode" && manifest.sessionID == nil
            && manifest.replayLayout.strategy == .fileSet && manifest.replayLayout.vscodeWorkspaceContext != nil
    }

    public static func isClineFileSet(_ manifest: ArchiveSourceManifest) -> Bool {
        let layout = manifest.replayLayout
        guard manifest.source == "cline", manifest.schemaVersion == 2, manifest.sessionID == nil,
              layout.strategy == .fileSet, layout.geminiProjectContext == nil, layout.kimiProjectContext == nil,
              let primary = layout.entrypointRelativePath, let files = layout.files, files.count == 1,
              let file = files.first, file.relativePath.utf8.elementsEqual(primary.utf8),
              file.byteOffset == 0, file.rawByteCount == manifest.rawByteCount,
              file.wholeSourceSHA256 == manifest.wholeSourceSHA256, file.generation == manifest.generation,
              let absent = layout.absentRelativePaths,
              let normalized = fileSetAbsolutePath(manifest.locator), normalized.utf8.elementsEqual(manifest.locator.utf8),
              manifest.locator.utf8.suffix(primary.utf8.count + 1).elementsEqual(("/" + primary).utf8) else { return false }
        let parts = primary.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].hasPrefix("."), !parts[0].isEmpty else { return false }
        if parts[1] == "ui_messages.json" { return absent.isEmpty }
        return parts[1] == "claude_messages.json" && absent.count == 1
            && absent[0].utf8.elementsEqual((parts[0] + "/ui_messages.json").utf8)
    }

    public static func isCopilotFileSet(_ manifest: ArchiveSourceManifest) -> Bool {
        let layout = manifest.replayLayout
        guard manifest.source == "copilot", manifest.schemaVersion == 2,
              manifest.sessionID == nil, layout.strategy == .fileSet,
              let primary = layout.entrypointRelativePath, let absent = layout.absentRelativePaths,
              let files = layout.files, !files.isEmpty,
              let normalizedLocator = fileSetAbsolutePath(manifest.locator),
              normalizedLocator.utf8.elementsEqual(manifest.locator.utf8),
              manifest.locator.utf8.suffix(primary.utf8.count + 1).elementsEqual(("/" + primary).utf8) else { return false }
        let components = primary.split(separator: "/").map(String.init)
        guard let session = components.first,
              (components.count == 2 && components[1] == "events.jsonl")
                || (components.count == 3 && components[1] == "checkpoints" && components[2] == "index.md") else { return false }
        let canonical = [session + "/events.jsonl", session + "/workspace.yaml", session + "/checkpoints/index.md"]
        let present = files.map(\.relativePath)
        guard absent.allSatisfy({ path in canonical.contains { $0.utf8.elementsEqual(path.utf8) } }),
              canonical.allSatisfy({ path in (present + absent).contains { $0.utf8.elementsEqual(path.utf8) } }) else { return false }
        return present.allSatisfy { path in
            let parts = path.split(separator: "/").map(String.init)
            guard parts.first?.utf8.elementsEqual(session.utf8) == true else { return false }
            if parts.count == 2 { return parts[1] == "events.jsonl" || parts[1] == "workspace.yaml" }
            return parts.count == 3 && parts[1] == "checkpoints" && parts[2].lowercased().hasSuffix(".md")
        }
    }

    /// Gemini replays one transcript, its real project-root slot and exactly
    /// one session-ID sidecar slot. HQ additionally binds that slot to parsed ID.
    public static func isCursorLegacySession(_ manifest: ArchiveSourceManifest) -> Bool {
        guard manifest.schemaVersion == 6, manifest.source == "cursor", manifest.sessionID == nil,
              manifest.replayLayout.strategy == .singleFile,
              manifest.replayLayout.relativePaths == ["session.cursor-legacy.json"],
              let context = manifest.replayLayout.cursorLegacySession else { return false }
        return manifest.locator.utf8.elementsEqual(context.logicalLocator.utf8)
    }

    public static func isOpenCodeSessionImage(_ manifest: ArchiveSourceManifest) -> Bool {
        guard manifest.schemaVersion == 4, manifest.source == "opencode", manifest.sessionID == nil,
              manifest.replayLayout.strategy == .singleFile,
              manifest.replayLayout.relativePaths == ["session.sqlite"],
              let context = manifest.replayLayout.sqliteSession else { return false }
        return manifest.locator.utf8.elementsEqual((context.databaseLocator + "::" + context.nativeSessionID).utf8)
    }

    /// CLI brain transcript only. Cache JSONL and opaque `.pb` conversations
    /// are not this shape. Lexical — this module cannot import Adapters.
    public static func windsurfHookNativeID(logicalLocator: String) -> String? {
        guard let canonical = fileSetAbsolutePath(logicalLocator),
              canonical.utf8.elementsEqual(logicalLocator.utf8) else { return nil }
        let parts = logicalLocator.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[parts.count - 2] == "transcripts",
              let file = parts.last, file.hasSuffix(".jsonl") else { return nil }
        let id = String(file.dropLast(6))
        return id.isEmpty || id.hasPrefix(".") ? nil : id
    }

    public static func isWindsurfHookTranscript(_ manifest: ArchiveSourceManifest) -> Bool {
        let layout = manifest.replayLayout
        guard manifest.source == "windsurf", manifest.schemaVersion == 1, manifest.sessionID == nil,
              layout.strategy == .singleFile, layout.relativePaths.count == 1,
              layout.entrypointRelativePath == nil, layout.files == nil, layout.absentRelativePaths == nil,
              layout.vscodeWorkspaceContext == nil, layout.geminiProjectContext == nil,
              layout.kimiProjectContext == nil, layout.sqliteSession == nil,
              layout.cursorLegacySession == nil,
              let id = windsurfHookNativeID(logicalLocator: manifest.locator) else { return false }
        return layout.relativePaths[0].utf8.elementsEqual((id + ".jsonl").utf8)
    }

    public static func isAntigravityCLITranscript(_ manifest: ArchiveSourceManifest) -> Bool {
        let layout = manifest.replayLayout
        guard manifest.source == "antigravity", manifest.schemaVersion == 1, manifest.sessionID == nil,
              layout.strategy == .singleFile, layout.relativePaths.count == 1,
              layout.entrypointRelativePath == nil, layout.files == nil, layout.absentRelativePaths == nil,
              layout.vscodeWorkspaceContext == nil, layout.geminiProjectContext == nil,
              layout.kimiProjectContext == nil, layout.sqliteSession == nil,
              layout.cursorLegacySession == nil else { return false }
        let relative = layout.relativePaths[0]
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[1] == ".system_generated", parts[2] == "logs",
              parts[3] == "transcript.jsonl", !parts[0].isEmpty, parts[0] != ".", parts[0] != "..",
              !parts[0].utf8.contains(0) else { return false }
        guard let canonical = fileSetAbsolutePath(manifest.locator),
              canonical.utf8.elementsEqual(manifest.locator.utf8),
              manifest.locator.utf8.suffix(relative.utf8.count + 1).elementsEqual(("/" + relative).utf8) else {
            return false
        }
        let locatorParts = manifest.locator.split(separator: "/", omittingEmptySubsequences: false)
        guard locatorParts.count >= 5,
              locatorParts.suffix(3).map(String.init) == [".system_generated", "logs", "transcript.jsonl"] else {
            return false
        }
        let nativeID = String(locatorParts[locatorParts.count - 4])
        return nativeID.utf8.elementsEqual(parts[0].utf8)
    }

    public static func isGeminiFileSet(_ manifest: ArchiveSourceManifest) -> Bool {
        let layout = manifest.replayLayout
        guard manifest.source == "gemini-cli", manifest.sessionID == nil,
              (manifest.schemaVersion == 2 && layout.geminiProjectContext == nil)
                || (manifest.schemaVersion == 3 && layout.geminiProjectContext != nil),
              layout.strategy == .fileSet, let primary = layout.entrypointRelativePath,
              let files = layout.files, let absent = layout.absentRelativePaths,
              let locator = fileSetAbsolutePath(manifest.locator),
              locator.utf8.elementsEqual(manifest.locator.utf8),
              locator.utf8.suffix(primary.utf8.count + 1).elementsEqual(("/" + primary).utf8)
        else { return false }
        let parts = primary.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[1] == "chats",
              (parts[2].hasSuffix(".json") || parts[2].hasSuffix(".jsonl")),
              !parts[2].hasSuffix(".engram.json") else { return false }
        let paths = files.map(\.relativePath) + absent
        guard paths.count == 3,
              paths.contains(where: { $0.utf8.elementsEqual((parts[0] + "/.project_root").utf8) }),
              files.contains(where: { $0.relativePath.utf8.elementsEqual(primary.utf8) }) else { return false }
        let sidecars = paths.filter { $0 != primary && $0 != parts[0] + "/.project_root" }
        guard sidecars.count == 1 else { return false }
        let sidecar = sidecars[0].split(separator: "/").map(String.init)
        return sidecar.count == 3 && sidecar[0].utf8.elementsEqual(parts[0].utf8)
            && sidecar[1] == "chats" && sidecar[2].hasSuffix(".engram.json")
            && sidecar[2].utf8.count > ".engram.json".utf8.count
    }

    public static func isKimiFileSet(_ manifest: ArchiveSourceManifest) -> Bool {
        let layout = manifest.replayLayout
        guard manifest.source == "kimi", manifest.schemaVersion == 5, manifest.sessionID == nil,
              layout.strategy == .fileSet, layout.geminiProjectContext == nil, layout.sqliteSession == nil,
              let context = layout.kimiProjectContext, let primary = layout.entrypointRelativePath,
              let files = layout.files, layout.absentRelativePaths != nil,
              let locator = fileSetAbsolutePath(manifest.locator),
              locator.utf8.elementsEqual(manifest.locator.utf8),
              locator.utf8.suffix(primary.utf8.count + 1).elementsEqual(("/" + primary).utf8),
              files.contains(where: { $0.relativePath.utf8.elementsEqual(primary.utf8) })
        else { return false }
        let parts = primary.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 3 && parts[2] == "context.jsonl"
            && parts[0].utf8.elementsEqual(context.workspaceName.utf8)
            && parts[1].utf8.elementsEqual(context.nativeSessionID.utf8)
    }

    /// Closed four-member Grok session plus optional `compaction/INDEX.md`
    /// and present `compaction/segment_*.md`. Entrypoint is the preferred
    /// present primary (`chat_history.jsonl` > `updates.jsonl` > `summary.json`).
    /// Auxiliary members are not size-capped here; daily updates.jsonl can
    /// exceed 100MiB (largest observed 278611574 B).
    public static func isGrokFileSet(_ manifest: ArchiveSourceManifest) -> Bool {
        let layout = manifest.replayLayout
        guard manifest.source == "grok", manifest.schemaVersion == 2, manifest.sessionID == nil,
              layout.strategy == .fileSet, layout.geminiProjectContext == nil,
              layout.kimiProjectContext == nil, layout.vscodeWorkspaceContext == nil,
              layout.sqliteSession == nil, layout.cursorLegacySession == nil,
              let primary = layout.entrypointRelativePath, let files = layout.files,
              let absent = layout.absentRelativePaths,
              let locator = fileSetAbsolutePath(manifest.locator),
              locator.utf8.elementsEqual(manifest.locator.utf8),
              locator.utf8.suffix(primary.utf8.count + 1).elementsEqual(("/" + primary).utf8),
              files.contains(where: { $0.relativePath.utf8.elementsEqual(primary.utf8) })
        else { return false }
        let parts = primary.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let primaryNames = ["chat_history.jsonl", "updates.jsonl", "summary.json"]
        let memberNames = ["chat_history.jsonl", "updates.jsonl", "summary.json", "prompt_context.json"]
        let safe: (String) -> Bool = { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }
        guard parts.count == 3, primaryNames.contains(where: { $0.utf8.elementsEqual(parts[2].utf8) }),
              parts.allSatisfy(safe) else {
            return false
        }
        let declared = files.map(\.relativePath) + absent
        let core = memberNames.map { parts[0] + "/" + parts[1] + "/" + $0 }
        let index = parts[0] + "/" + parts[1] + "/compaction/INDEX.md"
        guard declared.count <= ArchiveReplayLayout.maximumFileSetDependencies,
              declared.count == Set(declared).count,
              core.allSatisfy({ path in declared.contains { $0.utf8.elementsEqual(path.utf8) } }),
              declared.contains(where: { $0.utf8.elementsEqual(index.utf8) }) else {
            return false
        }
        for path in declared {
            let member = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard member.count >= 3, member.allSatisfy(safe),
                  member[0].utf8.elementsEqual(parts[0].utf8),
                  member[1].utf8.elementsEqual(parts[1].utf8) else {
                return false
            }
            if member.count == 3 {
                guard memberNames.contains(where: { $0.utf8.elementsEqual(member[2].utf8) }) else { return false }
            } else if member.count == 4, member[2] == "compaction" {
                if member[3] == "INDEX.md" { continue }
                let stem = member[3].hasPrefix("segment_") && member[3].hasSuffix(".md")
                    ? String(member[3].dropFirst("segment_".count).dropLast(".md".count)) : ""
                guard !stem.isEmpty, safe(stem),
                      files.contains(where: { $0.relativePath.utf8.elementsEqual(path.utf8) }) else {
                    return false
                }
            } else {
                return false
            }
        }
        let presentNames = files.map { URL(fileURLWithPath: $0.relativePath).lastPathComponent }
        guard let preferred = primaryNames.first(where: { name in
            presentNames.contains { $0.utf8.elementsEqual(name.utf8) }
        }) else { return false }
        return preferred.utf8.elementsEqual(parts[2].utf8)
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
