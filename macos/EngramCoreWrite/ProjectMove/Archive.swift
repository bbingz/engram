// macos/EngramCoreWrite/ProjectMove/Archive.swift
// Mirrors src/core/project-move/archive.ts (Node parity baseline).
//
// Suggests where to archive a project (`_archive/<category>/<name>`)
// based on the user's CLAUDE.md convention. The actual move is performed
// by the orchestrator with `options.archived = true`; this module only
// produces the suggestion + the canonical CJK category enum.
//
// Categories:
//   - 历史脚本: basename starts with `YYYYMMDD-` (one-shot scripts)
//   - 空项目: directory is empty or contains only a README
//   - 归档完成: has .git history + substantive content
//   - otherwise → throw, caller must pass `forceCategory` explicitly
import Foundation

public enum ArchiveCategory: String, Equatable, Sendable, CaseIterable {
    case historicalScripts = "历史脚本"
    case emptyProject = "空项目"
    case archivedDone = "归档完成"
}

/// Aliases the MCP / HTTP / CLI layer accepts. Matches Node's
/// `ARCHIVE_CATEGORY_ALIASES` byte-for-byte. Centralized here so every
/// caller (including HTTP `/api/project/archive`) shares one normalization
/// path — Round-4 critical bug was that the HTTP layer passed raw
/// `archived-done` through and produced English-named folders.
private let archiveCategoryAliases: [String: ArchiveCategory] = [
    "历史脚本": .historicalScripts,
    "空项目": .emptyProject,
    "归档完成": .archivedDone,
    "historical-scripts": .historicalScripts,
    "empty-project": .emptyProject,
    "archived-done": .archivedDone,
    // Soft backwards-compat for early adopters (not exposed in MCP schema).
    "empty": .emptyProject,
    "completed": .archivedDone,
]

public struct ArchiveSuggestion: Equatable, Sendable {
    /// Absolute destination path, e.g. `/Users/example/-Code-/_archive/历史脚本/WuKong`.
    public let dst: String
    public let category: ArchiveCategory
    /// Human-readable reason for the user-facing confirmation prompt.
    public let reason: String

    public init(dst: String, category: ArchiveCategory, reason: String) {
        self.dst = dst
        self.category = category
        self.reason = reason
    }
}

public struct ArchiveOptions {
    /// Where `_archive/` lives. Default: parent of `src`.
    public var archiveRoot: String?
    /// Skip the filesystem probe (for unit tests / dry inspections).
    public var skipProbe: Bool
    /// User-provided `--to` override. Bypasses heuristics so ambiguous
    /// projects can be rescued. Accepts CJK enum OR English alias.
    public var forceCategory: String?

    public init(
        archiveRoot: String? = nil,
        skipProbe: Bool = false,
        forceCategory: String? = nil
    ) {
        self.archiveRoot = archiveRoot
        self.skipProbe = skipProbe
        self.forceCategory = forceCategory
    }
}

public enum ArchiveError: Error, Equatable, LocalizedError {
    case unknownForceCategory(String)
    case cannotReadSource(String)
    case ambiguousProject(src: String, nonDotEntries: Int, hasGit: Bool)

    public var errorDescription: String? {
        switch self {
        case .unknownForceCategory(let v):
            return "suggestArchiveTarget: unknown forceCategory '\(v)'. " +
                "Expected 历史脚本 / 空项目 / 归档完成 or " +
                "historical-scripts / empty-project / archived-done."
        case .cannotReadSource(let path):
            return "suggestArchiveTarget: cannot read \(path) — please pass --to explicitly"
        case .ambiguousProject(let src, let nonDot, let hasGit):
            return "suggestArchiveTarget: cannot auto-categorize \(src) " +
                "(\(nonDot) non-dot entries, hasGit=\(hasGit)). " +
                "Please pass --to explicitly (e.g. --to 历史脚本)."
        }
    }
}

public enum Archive {
    /// Normalize a user-supplied category string to the canonical CJK enum.
    /// Returns nil if the input matches no known alias.
    public static func normalizeCategory(_ input: String?) -> ArchiveCategory? {
        guard let input, !input.isEmpty else { return nil }
        return archiveCategoryAliases[input]
    }

    /// Suggest an archive target for `src`. Rules match the user's
    /// CLAUDE.md convention. Throws when the project is ambiguous and the
    /// caller hasn't supplied `forceCategory` — the CLI / Swift UI is
    /// expected to surface the choice to the user.
    public static func suggestTarget(
        src: String,
        options: ArchiveOptions = ArchiveOptions()
    ) throws -> ArchiveSuggestion {
        let trimmed = trimTrailingSlashes(src)
        let name = (trimmed as NSString).lastPathComponent
        let archiveRoot = options.archiveRoot ?? defaultArchiveRoot(of: trimmed)

        // Force override path (Gemini critical #1 escape hatch).
        if let forced = options.forceCategory, !forced.isEmpty {
            guard let normalized = normalizeCategory(forced) else {
                throw ArchiveError.unknownForceCategory(forced)
            }
            return ArchiveSuggestion(
                dst: join(archiveRoot, normalized.rawValue, name),
                category: normalized,
                reason: "user-specified via --to \(normalized.rawValue)"
            )
        }

        // Rule 1: YYYYMMDD- prefix → 历史脚本.
        if matchesYYYYMMDDPrefix(name) {
            return ArchiveSuggestion(
                dst: join(archiveRoot, ArchiveCategory.historicalScripts.rawValue, name),
                category: .historicalScripts,
                reason: "basename starts with YYYYMMDD- prefix (one-shot script)"
            )
        }

        if options.skipProbe {
            return ArchiveSuggestion(
                dst: join(archiveRoot, ArchiveCategory.archivedDone.rawValue, name),
                category: .archivedDone,
                reason: "default (probe skipped)"
            )
        }

        // Filesystem probe.
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: trimmed)
        } catch {
            throw ArchiveError.cannotReadSource(trimmed)
        }
        let nonDotEntries = entries.filter { !$0.hasPrefix(".") }
        let hasGit = entries.contains(".git")

        // Rule 2: empty or README-only → 空项目.
        let looksEmpty: Bool
        let emptyReason: String
        if nonDotEntries.isEmpty {
            looksEmpty = true
            emptyReason = "directory is empty"
        } else if nonDotEntries.count == 1, isReadme(nonDotEntries[0]) {
            looksEmpty = true
            emptyReason = "only contains README"
        } else {
            looksEmpty = false
            emptyReason = ""
        }
        if looksEmpty {
            return ArchiveSuggestion(
                dst: join(archiveRoot, ArchiveCategory.emptyProject.rawValue, name),
                category: .emptyProject,
                reason: emptyReason
            )
        }

        // Rule 3: has .git + substantive content → 归档完成.
        if hasGit && !nonDotEntries.isEmpty {
            let gitPath = join(trimmed, ".git")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: gitPath) {
                let type = attrs[.type] as? FileAttributeType
                if type == .typeDirectory {
                    let headPath = join(gitPath, "HEAD")
                    if FileManager.default.fileExists(atPath: headPath) {
                        return ArchiveSuggestion(
                            dst: join(archiveRoot, ArchiveCategory.archivedDone.rawValue, name),
                            category: .archivedDone,
                            reason: "git repository with substantive content"
                        )
                    }
                } else if type == .typeRegular {
                    // .git as a file = worktree / submodule. Accept without
                    // further probe (Node parity).
                    return ArchiveSuggestion(
                        dst: join(archiveRoot, ArchiveCategory.archivedDone.rawValue, name),
                        category: .archivedDone,
                        reason: "git worktree/submodule with substantive content"
                    )
                }
            }
            // .git exists but malformed → fall through to ambiguous.
        }

        // Rule 4: ambiguous.
        throw ArchiveError.ambiguousProject(
            src: trimmed,
            nonDotEntries: nonDotEntries.count,
            hasGit: hasGit
        )
    }

    // MARK: - internals

    private static func trimTrailingSlashes(_ path: String) -> String {
        var s = path
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func defaultArchiveRoot(of src: String) -> String {
        join((src as NSString).deletingLastPathComponent, "_archive")
    }

    private static func matchesYYYYMMDDPrefix(_ name: String) -> Bool {
        guard name.count >= 9 else { return false }
        let prefix = name.prefix(8)
        guard prefix.allSatisfy({ $0.isNumber }) else { return false }
        return name[name.index(name.startIndex, offsetBy: 8)] == "-"
    }

    private static func isReadme(_ name: String) -> Bool {
        name.lowercased().hasPrefix("readme")
    }

    private static func join(_ parts: String...) -> String {
        var result = parts.first ?? ""
        for piece in parts.dropFirst() {
            result = (result as NSString).appendingPathComponent(piece)
        }
        return result
    }
}
