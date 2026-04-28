// macos/EngramCoreWrite/ProjectMove/JsonlPatch.swift
// Mirrors src/core/project-move/jsonl-patch.ts (Node parity baseline).
//
// Byte-level path rewriter for JSONL session files. Replaces every
// occurrence of `oldPath` with `newPath` where the match is followed by
// a path-terminator character (or end-of-input). Terminators: `"` `'` `/`
// `\` `<` `>` `]` `)` `}` backtick whitespace EOF. NOT terminators (so
// `.bak`, `-v2`, `_dir` survive): `.` `,` `;` `-` `_` and alphanumerics.
//
// **Code rule:** this module MUST NOT call JSONDecoder on the input. It
// works at byte level so Python mvp.py and Swift produce byte-identical
// output (diff-test invariant).
//
// Strict UTF-8 decode: `String(data:encoding:.utf8)` returns nil on
// malformed sequences instead of inserting U+FFFD, so the strict-decode
// contract from Node maps directly. Throw `InvalidUtf8Error` rather than
// corrupt the file's original bytes.
import Darwin
import Foundation

public struct InvalidUtf8Error: ProjectMoveError, Equatable {
    public let detail: String
    public init(detail: String) { self.detail = detail }
    public var errorName: String { "InvalidUtf8Error" }
    public var errorMessage: String { "patchBuffer: input is not valid UTF-8 (\(detail))" }
}

public struct ConcurrentModificationError: ProjectMoveError, Equatable {
    public let filePath: String
    public let oldMtime: Double
    public let newMtime: Double
    public init(filePath: String, oldMtime: Double, newMtime: Double) {
        self.filePath = filePath
        self.oldMtime = oldMtime
        self.newMtime = newMtime
    }
    public var errorName: String { "ConcurrentModificationError" }
    public var errorMessage: String {
        "patchFile: \(filePath) was modified during patch (mtime \(oldMtime) → \(newMtime)). " +
        "Another process wrote to the file between read and rename. " +
        "Safe fallback: retry later; orchestrator should retry with exponential backoff."
    }
}

public enum JsonlPatchError: Error, Equatable {
    case fileTooLarge(path: String, size: Int64, limit: Int64)
    case ioError(path: String, errno: Int32, message: String)
}

public struct PatchResult: Equatable {
    public let data: Data
    public let count: Int
    public init(data: Data, count: Int) {
        self.data = data
        self.count = count
    }
}

public enum JsonlPatch {
    /// Path-terminator lookahead. Excludes `.` `,` `;` `-` `_` and
    /// alphanumerics so paths like `/p/file.bak`, `/p-v2`, `/p_dir`
    /// don't false-positive.
    public static let pathTerminatorLookahead = #"(?=["'/\\<>\])}`\s]|$)"#

    /// Hard cap: refuse to patch JSONL above this size in memory. The
    /// orchestrator either streams or fails fast — current callers all
    /// fail fast.
    public static let maxInMemoryBytes: Int64 = 128 * 1024 * 1024

    /// Replace `oldPath` with `newPath` in `data`, preserving all other
    /// bytes. Returns a new `Data` value plus the number of replacements.
    /// Round-4 NFD fallback: if the UTF-8 source was decomposed (HFS+
    /// volume) but the user typed the rename target in NFC, retry the
    /// match against `oldPath.decomposedStringWithCanonicalMapping`.
    public static func patchBuffer(
        _ data: Data,
        oldPath: String,
        newPath: String
    ) throws -> PatchResult {
        if oldPath.isEmpty || oldPath == newPath {
            return PatchResult(data: data, count: 0)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw InvalidUtf8Error(detail: "input bytes are not a valid UTF-8 sequence")
        }
        var totalCount = 0
        var working = replaceWithTerminator(
            in: text,
            needle: oldPath,
            replacement: newPath,
            count: &totalCount
        )
        let oldNfd = oldPath.decomposedStringWithCanonicalMapping
        if oldNfd != oldPath {
            working = replaceWithTerminator(
                in: working,
                needle: oldNfd,
                replacement: newPath,
                count: &totalCount
            )
        }
        if totalCount == 0 {
            return PatchResult(data: data, count: 0)
        }
        return PatchResult(data: Data(working.utf8), count: totalCount)
    }

    /// Byte-level literal replace of `<oldPath>."` → `<newPath>."`. Mirrors
    /// mvp.py's `auto_fix_dot_quote`: a `.` followed by `"` cannot be a
    /// filename extension (it's a sentence-end quote), so it's safe to
    /// rewrite even though the main regex excludes `.`.
    public static func autoFixDotQuote(
        _ data: Data,
        oldPath: String,
        newPath: String
    ) -> PatchResult {
        let needle = Data((oldPath + ".\"").utf8)
        let replacement = Data((newPath + ".\"").utf8)
        if needle == replacement || data.range(of: needle) == nil {
            return PatchResult(data: data, count: 0)
        }
        var output = Data()
        output.reserveCapacity(data.count)
        var cursor = data.startIndex
        var count = 0
        while cursor <= data.endIndex {
            if let hit = data.range(of: needle, in: cursor..<data.endIndex) {
                output.append(data[cursor..<hit.lowerBound])
                output.append(replacement)
                cursor = hit.upperBound
                count += 1
            } else {
                output.append(data[cursor..<data.endIndex])
                break
            }
        }
        if count == 0 {
            return PatchResult(data: data, count: 0)
        }
        return PatchResult(data: output, count: count)
    }

    /// Combined main + dot-quote sweep — use this in the orchestrator's
    /// CAS window so both transformations are atomic and reversible.
    public static func patchBufferWithDotQuote(
        _ data: Data,
        oldPath: String,
        newPath: String
    ) throws -> PatchResult {
        let first = try patchBuffer(data, oldPath: oldPath, newPath: newPath)
        let second = autoFixDotQuote(first.data, oldPath: oldPath, newPath: newPath)
        return PatchResult(data: second.data, count: first.count + second.count)
    }

    /// Read, patch, atomically rename a single file with mtime CAS. Returns
    /// the number of replacements (0 = file untouched, no write performed).
    /// Re-stats twice — once before the write, once after — so a concurrent
    /// writer between read and rename surfaces as `ConcurrentModificationError`.
    public static func patchFile(
        at filePath: String,
        oldPath: String,
        newPath: String
    ) throws -> Int {
        let attrsBefore = try FileManager.default.attributesOfItem(atPath: filePath)
        let sizeBefore = (attrsBefore[.size] as? NSNumber)?.int64Value ?? 0
        if sizeBefore > maxInMemoryBytes {
            throw JsonlPatchError.fileTooLarge(
                path: filePath, size: sizeBefore, limit: maxInMemoryBytes
            )
        }
        let mtimeBefore = mtimeMs(attrsBefore)

        let buf = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let res = try patchBufferWithDotQuote(buf, oldPath: oldPath, newPath: newPath)
        if res.count == 0 { return 0 }

        // First CAS: file must not have moved between read and now.
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: filePath)
        let mtimeAfter = mtimeMs(attrsAfter)
        if mtimeAfter != mtimeBefore {
            throw ConcurrentModificationError(
                filePath: filePath, oldMtime: mtimeBefore, newMtime: mtimeAfter
            )
        }

        let tmpPath = "\(filePath).engram-tmp-\(getpid())-\(randomToken())"
        do {
            try res.data.write(to: URL(fileURLWithPath: tmpPath))
        } catch {
            throw JsonlPatchError.ioError(
                path: tmpPath, errno: errno, message: error.localizedDescription
            )
        }

        // Second CAS: closes the gap between the first stat and rename.
        let attrsFinal = try FileManager.default.attributesOfItem(atPath: filePath)
        let mtimeFinal = mtimeMs(attrsFinal)
        if mtimeFinal != mtimeBefore {
            _ = try? FileManager.default.removeItem(atPath: tmpPath)
            throw ConcurrentModificationError(
                filePath: filePath, oldMtime: mtimeBefore, newMtime: mtimeFinal
            )
        }

        if Darwin.rename(tmpPath, filePath) != 0 {
            let code = errno
            _ = try? FileManager.default.removeItem(atPath: tmpPath)
            throw JsonlPatchError.ioError(
                path: filePath, errno: code, message: String(cString: strerror(code))
            )
        }
        return res.count
    }

    // MARK: - internals

    private static func replaceWithTerminator(
        in text: String,
        needle: String,
        replacement: String,
        count: inout Int
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: needle)
        let pattern = escaped + pathTerminatorLookahead
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: range)
        if matches.isEmpty {
            return text
        }
        var result = text
        for match in matches.reversed() {
            if let r = Range(match.range, in: result) {
                result.replaceSubrange(r, with: replacement)
            }
        }
        count += matches.count
        return result
    }

    private static func mtimeMs(_ attrs: [FileAttributeKey: Any]) -> Double {
        guard let date = attrs[.modificationDate] as? Date else { return 0 }
        return date.timeIntervalSince1970 * 1000
    }

    private static func randomToken() -> String {
        var raw = [UInt8](repeating: 0, count: 4)
        arc4random_buf(&raw, 4)
        return raw.map { String(format: "%02x", $0) }.joined()
    }
}
