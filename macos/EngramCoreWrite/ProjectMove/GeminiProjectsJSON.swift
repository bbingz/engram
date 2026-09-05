// macos/EngramCoreWrite/ProjectMove/GeminiProjectsJSON.swift
// Mirrors src/core/project-move/gemini-projects-json.ts (Node parity baseline).
//
// Maintains the Gemini CLI project registry (`~/.gemini/projects.json`)
// during a project move. The file maps absoluteCwd → projectName and
// the Gemini adapter uses it to reverse-resolve session files. If we
// rename the tmp dir without updating the JSON, sessions detach silently.
//
// Two layouts observed in the wild:
//   { "projects": { "<cwd>": "<name>", … } }   (current)
//   { "<cwd>": "<name>", … }                    (legacy)
// Both are preserved on round-trip.
import Darwin
import Foundation

public struct GeminiProjectsEntry: Equatable, Sendable {
    public let cwd: String
    public let name: String
    public init(cwd: String, name: String) {
        self.cwd = cwd
        self.name = name
    }
}

public struct GeminiProjectsJsonUpdatePlan: Equatable, Sendable {
    public let filePath: String
    public let oldEntry: GeminiProjectsEntry?
    public let newEntry: GeminiProjectsEntry
    /// Snapshot of the file's original bytes for byte-exact reverse.
    /// `nil` means the file did not exist before the migration.
    public let originalText: String?

    public init(
        filePath: String,
        oldEntry: GeminiProjectsEntry?,
        newEntry: GeminiProjectsEntry,
        originalText: String?
    ) {
        self.filePath = filePath
        self.oldEntry = oldEntry
        self.newEntry = newEntry
        self.originalText = originalText
    }
}

public enum GeminiProjectsJSONError: Error, Equatable {
    case invalidJson(path: String, message: String)
    case writeFailed(path: String, errno: Int32, message: String)
}

private struct ProjectsJsonShape {
    var wrapped: Bool
    var map: [String: String]
}

public enum GeminiProjectsJSON {
    /// Plan the projects.json update. Captures the snapshot for compensation
    /// AND tells the orchestrator exactly which entry will change. Pure —
    /// does not write.
    public static func plan(
        filePath: String,
        oldCwd: String,
        newCwd: String
    ) throws -> GeminiProjectsJsonUpdatePlan {
        let (shape, originalText) = try load(filePath)
        let oldEntry = shape.map[oldCwd].map { GeminiProjectsEntry(cwd: oldCwd, name: $0) }
        let newEntry = GeminiProjectsEntry(
            cwd: newCwd,
            name: SessionSources.encodeGemini(newCwd)
        )
        return GeminiProjectsJsonUpdatePlan(
            filePath: filePath,
            oldEntry: oldEntry,
            newEntry: newEntry,
            originalText: originalText
        )
    }

    /// Apply the plan: remove the old entry (if any), add the new entry,
    /// write atomically. Caller MUST have already cleared collision via
    /// `collectOtherCwdsSharingProjectName`.
    public static func apply(plan: GeminiProjectsJsonUpdatePlan) throws {
        var (shape, _) = try load(plan.filePath)
        if let old = plan.oldEntry {
            shape.map.removeValue(forKey: old.cwd)
        }
        shape.map[plan.newEntry.cwd] = plan.newEntry.name
        try writeAtomic(plan.filePath, content: serialize(shape))
    }

    /// Reverse the update. Restores the byte-exact snapshot if we captured
    /// one; otherwise removes the entry we inserted and unlinks the file
    /// when the resulting map is empty (Round-4 Gemini Minor).
    public static func reverse(plan: GeminiProjectsJsonUpdatePlan) throws {
        if let snapshot = plan.originalText {
            try writeAtomic(plan.filePath, content: snapshot)
            return
        }
        var (shape, _) = try load(plan.filePath)
        shape.map.removeValue(forKey: plan.newEntry.cwd)
        if shape.map.isEmpty {
            // We created the file from scratch and we're the only contributor
            // — fully restore the pre-migration state by unlinking it.
            _ = try? FileManager.default.removeItem(atPath: plan.filePath)
            return
        }
        try writeAtomic(plan.filePath, content: serialize(shape))
    }

    /// Collision probe: find OTHER cwds that share the target project name
    /// (excluding `srcCwd`). Renaming the tmp dir without resolving these
    /// would steal sessions from those projects.
    public static func collectOtherCwdsSharingProjectName(
        filePath: String,
        targetProjectName: String,
        srcCwd: String
    ) throws -> [String] {
        let (shape, _) = try load(filePath)
        return shape.map.compactMap { (cwd, name) in
            (name == targetProjectName && cwd != srcCwd) ? cwd : nil
        }
        .sorted()
    }

    // MARK: - internals

    private static func load(_ filePath: String) throws -> (ProjectsJsonShape, String?) {
        let url = URL(fileURLWithPath: filePath)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let err as CocoaError where err.code == .fileReadNoSuchFile {
            return (ProjectsJsonShape(wrapped: true, map: [:]), nil)
        } catch let err as NSError where err.domain == NSCocoaErrorDomain
            && err.code == NSFileReadNoSuchFileError {
            return (ProjectsJsonShape(wrapped: true, map: [:]), nil)
        }
        let originalText = String(data: data, encoding: .utf8)

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw GeminiProjectsJSONError.invalidJson(
                path: filePath,
                message: "gemini-projects-json: \(filePath) is not valid JSON — " +
                    error.localizedDescription
            )
        }
        guard let dict = object as? [String: Any] else {
            return (ProjectsJsonShape(wrapped: false, map: [:]), originalText)
        }
        let wrapped: Bool
        let rawMap: Any?
        if let inner = dict["projects"] {
            wrapped = true
            rawMap = inner
        } else {
            wrapped = false
            rawMap = dict
        }
        var map: [String: String] = [:]
        if let mapDict = rawMap as? [String: Any] {
            for (k, v) in mapDict {
                if let s = v as? String { map[k] = s }
            }
        }
        return (ProjectsJsonShape(wrapped: wrapped, map: map), originalText)
    }

    private static func serialize(_ shape: ProjectsJsonShape) -> String {
        let top: [String: Any] = shape.wrapped ? ["projects": shape.map] : shape.map
        let data = (try? JSONSerialization.data(
            withJSONObject: top,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data("{}".utf8)
        let body = String(data: data, encoding: .utf8) ?? "{}"
        return body + "\n"
    }

    private static func writeAtomic(_ filePath: String, content: String) throws {
        let directory = (filePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        let tmp = "\(filePath).engram-tmp-\(getpid())-\(Int(Date().timeIntervalSince1970 * 1000))"
        let permissions = (
            (try? FileManager.default.attributesOfItem(atPath: filePath)[.posixPermissions]) as? NSNumber
        )?.intValue ?? 0o600
        let created = FileManager.default.createFile(
            atPath: tmp,
            contents: Data(content.utf8),
            attributes: [.posixPermissions: permissions]
        )
        guard created else {
            throw GeminiProjectsJSONError.writeFailed(
                path: tmp,
                errno: EIO,
                message: "create temp file failed"
            )
        }
        do {
            try fsyncFile(at: tmp)
        } catch {
            _ = try? FileManager.default.removeItem(atPath: tmp)
            throw error
        }
        if Darwin.rename(tmp, filePath) != 0 {
            let code = errno
            _ = try? FileManager.default.removeItem(atPath: tmp)
            throw GeminiProjectsJSONError.writeFailed(
                path: filePath,
                errno: code,
                message: String(cString: strerror(code))
            )
        }
        fsyncDirectory(for: filePath)
    }

    private static func fsyncDirectory(for filePath: String) {
        let directory = (filePath as NSString).deletingLastPathComponent
        let fd = Darwin.open(directory, O_RDONLY)
        guard fd >= 0 else { return }
        _ = Darwin.fsync(fd)
        Darwin.close(fd)
    }

    private static func fsyncFile(at path: String) throws {
        let fd = Darwin.open(path, O_RDONLY)
        if fd < 0 {
            throw GeminiProjectsJSONError.writeFailed(
                path: path,
                errno: errno,
                message: String(cString: strerror(errno))
            )
        }
        defer { Darwin.close(fd) }
        if Darwin.fsync(fd) != 0 {
            throw GeminiProjectsJSONError.writeFailed(
                path: path,
                errno: errno,
                message: String(cString: strerror(errno))
            )
        }
    }
}

// MARK: - Kimi work-dir registry

public struct KimiWorkDirUpdate: Equatable, Sendable {
    public let index: Int
    public let oldPath: String
    public let newPath: String
    public let kaos: String?
    public let oldWorkspaceName: String
    public let newWorkspaceName: String

    public init(
        index: Int,
        oldPath: String,
        newPath: String,
        kaos: String?,
        oldWorkspaceName: String,
        newWorkspaceName: String
    ) {
        self.index = index
        self.oldPath = oldPath
        self.newPath = newPath
        self.kaos = kaos
        self.oldWorkspaceName = oldWorkspaceName
        self.newWorkspaceName = newWorkspaceName
    }
}

public struct KimiProjectsJsonUpdatePlan: Equatable, Sendable {
    public let filePath: String
    public let updates: [KimiWorkDirUpdate]
    public let originalText: String?

    public init(
        filePath: String,
        updates: [KimiWorkDirUpdate],
        originalText: String?
    ) {
        self.filePath = filePath
        self.updates = updates
        self.originalText = originalText
    }
}

public enum KimiProjectsJSONError: Error, Equatable {
    case invalidJson(path: String, message: String)
    case concurrentModification(path: String, index: Int)
    case writeFailed(path: String, errno: Int32, message: String)
}

private struct KimiJsonShape {
    var object: [String: Any]
    var workDirs: [[String: Any]]
}

public enum KimiProjectsJSON {
    public static func plan(
        filePath: String,
        oldPaths: [String],
        newPath: String
    ) throws -> KimiProjectsJsonUpdatePlan {
        let (shape, originalText) = try load(filePath)
        let aliases = uniqueAliases(oldPaths)
        let updates = shape.workDirs.enumerated().compactMap { index, workDir -> KimiWorkDirUpdate? in
            guard let path = workDir["path"] as? String,
                  let matched = matchingPrefix(path, aliases: aliases)
            else { return nil }
            let suffix = String(path.dropFirst(matched.count))
            let rewritten = newPath + suffix
            let kaos = workDir["kaos"] as? String
            return KimiWorkDirUpdate(
                index: index,
                oldPath: path,
                newPath: rewritten,
                kaos: kaos,
                oldWorkspaceName: SessionSources.encodeKimi(path, kaos: kaos),
                newWorkspaceName: SessionSources.encodeKimi(rewritten, kaos: kaos)
            )
        }
        return KimiProjectsJsonUpdatePlan(
            filePath: filePath,
            updates: updates,
            originalText: originalText
        )
    }

    public static func apply(plan: KimiProjectsJsonUpdatePlan) throws {
        guard !plan.updates.isEmpty else { return }
        var (shape, _) = try load(plan.filePath)
        for update in plan.updates {
            guard shape.workDirs.indices.contains(update.index),
                  shape.workDirs[update.index]["path"] as? String == update.oldPath
            else {
                throw KimiProjectsJSONError.concurrentModification(
                    path: plan.filePath,
                    index: update.index
                )
            }
            shape.workDirs[update.index]["path"] = update.newPath
        }
        shape.object["work_dirs"] = shape.workDirs
        try writeAtomic(plan.filePath, content: try serialize(shape.object))
    }

    public static func reverse(plan: KimiProjectsJsonUpdatePlan) throws {
        guard !plan.updates.isEmpty else { return }
        if let originalText = plan.originalText {
            try writeAtomic(plan.filePath, content: originalText)
        } else {
            _ = try? FileManager.default.removeItem(atPath: plan.filePath)
        }
    }

    public static func collectOtherPathsSharingWorkspace(
        plan: KimiProjectsJsonUpdatePlan
    ) throws -> [String] {
        guard !plan.updates.isEmpty else { return [] }
        let (shape, _) = try load(plan.filePath)
        let updatedIndices = Set(plan.updates.map(\.index))
        let plannedNames = Set(plan.updates.flatMap {
            [$0.oldWorkspaceName, $0.newWorkspaceName]
        })
        var conflicts = Set<String>()
        for (index, workDir) in shape.workDirs.enumerated() where !updatedIndices.contains(index) {
            guard let path = workDir["path"] as? String else { continue }
            let name = SessionSources.encodeKimi(path, kaos: workDir["kaos"] as? String)
            if plannedNames.contains(name) { conflicts.insert(path) }
        }
        return conflicts.sorted()
    }

    private static func uniqueAliases(_ paths: [String]) -> [String] {
        var aliases: [String] = []
        for value in paths.flatMap(ProjectPathVariants.variants) {
            if !aliases.contains(where: { $0.utf8.elementsEqual(value.utf8) }) {
                aliases.append(value)
            }
        }
        return aliases
    }

    private static func matchingPrefix(_ path: String, aliases: [String]) -> String? {
        aliases.first { alias in
            path.utf8.elementsEqual(alias.utf8)
                || path.utf8.starts(with: (alias + "/").utf8)
        }
    }

    private static func load(_ filePath: String) throws -> (KimiJsonShape, String?) {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return (KimiJsonShape(object: [:], workDirs: []), nil)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return (KimiJsonShape(object: [:], workDirs: []), nil)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw KimiProjectsJSONError.invalidJson(
                path: filePath,
                message: "kimi-projects-json: invalid JSON — \(error.localizedDescription)"
            )
        }
        guard let dictionary = object as? [String: Any] else {
            throw KimiProjectsJSONError.invalidJson(
                path: filePath,
                message: "kimi-projects-json: top-level value must be an object"
            )
        }
        let rawWorkDirs = dictionary["work_dirs"] ?? []
        guard let workDirs = rawWorkDirs as? [[String: Any]] else {
            throw KimiProjectsJSONError.invalidJson(
                path: filePath,
                message: "kimi-projects-json: work_dirs must be an array of objects"
            )
        }
        guard let originalText = String(data: data, encoding: .utf8) else {
            throw KimiProjectsJSONError.invalidJson(
                path: filePath,
                message: "kimi-projects-json: file must be UTF-8"
            )
        }
        return (KimiJsonShape(object: dictionary, workDirs: workDirs), originalText)
    }

    private static func serialize(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    private static func writeAtomic(_ filePath: String, content: String) throws {
        let directory = (filePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        let tmp = "\(filePath).engram-tmp-\(getpid())-\(UUID().uuidString)"
        let permissions = (
            (try? FileManager.default.attributesOfItem(atPath: filePath)[.posixPermissions]) as? NSNumber
        )?.intValue ?? 0o600
        guard FileManager.default.createFile(
            atPath: tmp,
            contents: Data(content.utf8),
            attributes: [.posixPermissions: permissions]
        ) else {
            throw KimiProjectsJSONError.writeFailed(
                path: tmp,
                errno: EIO,
                message: "create temp file failed"
            )
        }
        let fd = Darwin.open(tmp, O_RDONLY)
        guard fd >= 0 else {
            _ = try? FileManager.default.removeItem(atPath: tmp)
            throw KimiProjectsJSONError.writeFailed(
                path: tmp,
                errno: errno,
                message: String(cString: strerror(errno))
            )
        }
        let syncResult = Darwin.fsync(fd)
        let syncErrno = errno
        Darwin.close(fd)
        guard syncResult == 0 else {
            _ = try? FileManager.default.removeItem(atPath: tmp)
            throw KimiProjectsJSONError.writeFailed(
                path: tmp,
                errno: syncErrno,
                message: String(cString: strerror(syncErrno))
            )
        }
        guard Darwin.rename(tmp, filePath) == 0 else {
            let code = errno
            _ = try? FileManager.default.removeItem(atPath: tmp)
            throw KimiProjectsJSONError.writeFailed(
                path: filePath,
                errno: code,
                message: String(cString: strerror(code))
            )
        }
        let directoryFD = Darwin.open(directory, O_RDONLY)
        if directoryFD >= 0 {
            _ = Darwin.fsync(directoryFD)
            Darwin.close(directoryFD)
        }
    }
}
