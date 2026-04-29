// macos/EngramCoreWrite/ProjectMove/GeminiProjectsJSON.swift
// Mirrors src/core/project-move/gemini-projects-json.ts (Node parity baseline).
//
// Maintains the Gemini CLI project registry (`~/.gemini/projects.json`)
// during a project move. The file maps absoluteCwd → projectBasename and
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
            name: (newCwd as NSString).lastPathComponent
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
    /// `collectOtherCwdsSharingBasename`.
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

    /// Collision probe: find OTHER cwds that share the target basename
    /// (excluding `srcCwd`). Renaming the tmp dir without resolving these
    /// would steal sessions from those projects.
    public static func collectOtherCwdsSharingBasename(
        filePath: String,
        targetBasename: String,
        srcCwd: String
    ) throws -> [String] {
        let (shape, _) = try load(filePath)
        return shape.map.compactMap { (cwd, name) in
            (name == targetBasename && cwd != srcCwd) ? cwd : nil
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
        try content.write(toFile: tmp, atomically: false, encoding: .utf8)
        if Darwin.rename(tmp, filePath) != 0 {
            let code = errno
            _ = try? FileManager.default.removeItem(atPath: tmp)
            throw GeminiProjectsJSONError.writeFailed(
                path: filePath,
                errno: code,
                message: String(cString: strerror(code))
            )
        }
    }
}
