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
        try rejectSymlinkSource(filePath)
        let attrsBefore = try FileManager.default.attributesOfItem(atPath: filePath)
        let sizeBefore = (attrsBefore[.size] as? NSNumber)?.int64Value ?? 0
        if sizeBefore > maxInMemoryBytes {
            return try patchFileStreaming(
                at: filePath,
                oldPath: oldPath,
                newPath: newPath,
                attrsBefore: attrsBefore
            )
        }
        let before = try snapshot(path: filePath)

        let buf = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let res = try patchBufferWithDotQuote(buf, oldPath: oldPath, newPath: newPath)
        if res.count == 0 { return 0 }

        // First CAS: file must not have moved between read and now.
        let after = try snapshot(path: filePath)
        if after != before {
            throw ConcurrentModificationError(
                filePath: filePath,
                oldMtime: Double(before.mtimeSec) * 1000 + Double(before.mtimeNsec) / 1_000_000,
                newMtime: Double(after.mtimeSec) * 1000 + Double(after.mtimeNsec) / 1_000_000
            )
        }

        let tmpPath = "\(filePath).engram-tmp-\(getpid())-\(randomToken())"
        do {
            try res.data.write(to: URL(fileURLWithPath: tmpPath))
            if let permissions = attrsBefore[.posixPermissions] as? NSNumber {
                chmod(tmpPath, mode_t(permissions.intValue))
            }
            try fsyncFile(at: tmpPath)
        } catch {
            _ = try? FileManager.default.removeItem(atPath: tmpPath)
            throw JsonlPatchError.ioError(
                path: tmpPath, errno: errno, message: error.localizedDescription
            )
        }

        // Second CAS: closes the gap between the first stat and rename.
        let final = try snapshot(path: filePath)
        if final != before {
            _ = try? FileManager.default.removeItem(atPath: tmpPath)
            throw ConcurrentModificationError(
                filePath: filePath,
                oldMtime: Double(before.mtimeSec) * 1000 + Double(before.mtimeNsec) / 1_000_000,
                newMtime: Double(final.mtimeSec) * 1000 + Double(final.mtimeNsec) / 1_000_000
            )
        }

        if Darwin.rename(tmpPath, filePath) != 0 {
            let code = errno
            _ = try? FileManager.default.removeItem(atPath: tmpPath)
            throw JsonlPatchError.ioError(
                path: filePath, errno: code, message: String(cString: strerror(code))
            )
        }
        fsyncDirectory(for: filePath)
        return res.count
    }

    // MARK: - internals

    private struct FileSnapshot: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let mtimeSec: Int
        let mtimeNsec: Int
    }

    private static func snapshot(path: String) throws -> FileSnapshot {
        var info = stat()
        if lstat(path, &info) != 0 {
            throw JsonlPatchError.ioError(
                path: path,
                errno: errno,
                message: String(cString: strerror(errno))
            )
        }
        return FileSnapshot(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            mtimeSec: Int(info.st_mtimespec.tv_sec),
            mtimeNsec: Int(info.st_mtimespec.tv_nsec)
        )
    }

    private static func rejectSymlinkSource(_ filePath: String) throws {
        var info = stat()
        if lstat(filePath, &info) != 0 {
            throw JsonlPatchError.ioError(
                path: filePath,
                errno: errno,
                message: String(cString: strerror(errno))
            )
        }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            throw JsonlPatchError.ioError(
                path: filePath,
                errno: ELOOP,
                message: "source is symlink"
            )
        }
    }

    private static func patchFileStreaming(
        at filePath: String,
        oldPath: String,
        newPath: String,
        attrsBefore: [FileAttributeKey: Any]
    ) throws -> Int {
        let before = try snapshot(path: filePath)
        let tmpPath = "\(filePath).engram-tmp-\(getpid())-\(randomToken())"
        FileManager.default.createFile(atPath: tmpPath, contents: nil)
        if let permissions = attrsBefore[.posixPermissions] as? NSNumber {
            chmod(tmpPath, mode_t(permissions.intValue))
        }

        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: tmpPath))
        var total = 0
        var carry = Data()
        let carryLimit = max(
            oldPath.lengthOfBytes(using: .utf8),
            oldPath.decomposedStringWithCanonicalMapping.lengthOfBytes(using: .utf8)
        ) + 8

        do {
            while true {
                let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                var combined = Data()
                combined.reserveCapacity(carry.count + chunk.count)
                combined.append(carry)
                combined.append(chunk)

                guard combined.count > carryLimit else {
                    carry = combined
                    continue
                }
                var processCount = combined.count - carryLimit
                var segment = combined.prefix(processCount)
                var decoded = String(data: segment, encoding: .utf8)
                var attempts = 0
                while decoded == nil && processCount > 0 && attempts < 4 {
                    processCount -= 1
                    attempts += 1
                    segment = combined.prefix(processCount)
                    decoded = String(data: segment, encoding: .utf8)
                }
                guard let decoded else {
                    throw InvalidUtf8Error(detail: "input bytes are not a valid UTF-8 sequence")
                }
                let patched = try patchBufferWithDotQuote(
                    Data(decoded.utf8),
                    oldPath: oldPath,
                    newPath: newPath
                )
                total += patched.count
                try output.write(contentsOf: patched.data)
                carry = combined.suffix(combined.count - processCount)
            }

            let tail = try patchBufferWithDotQuote(
                carry,
                oldPath: oldPath,
                newPath: newPath
            )
            total += tail.count
            try output.write(contentsOf: tail.data)
            output.synchronizeFile()
            try output.close()
            try input.close()

            if total == 0 {
                _ = try? FileManager.default.removeItem(atPath: tmpPath)
                return 0
            }

            let after = try snapshot(path: filePath)
            if after != before {
                _ = try? FileManager.default.removeItem(atPath: tmpPath)
                throw ConcurrentModificationError(
                    filePath: filePath,
                    oldMtime: Double(before.mtimeSec) * 1000 + Double(before.mtimeNsec) / 1_000_000,
                    newMtime: Double(after.mtimeSec) * 1000 + Double(after.mtimeNsec) / 1_000_000
                )
            }
            if Darwin.rename(tmpPath, filePath) != 0 {
                let code = errno
                _ = try? FileManager.default.removeItem(atPath: tmpPath)
                throw JsonlPatchError.ioError(
                    path: filePath,
                    errno: code,
                    message: String(cString: strerror(code))
                )
            }
            fsyncDirectory(for: filePath)
            return total
        } catch {
            try? output.close()
            try? input.close()
            _ = try? FileManager.default.removeItem(atPath: tmpPath)
            throw error
        }
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
            throw JsonlPatchError.ioError(
                path: path,
                errno: errno,
                message: String(cString: strerror(errno))
            )
        }
        defer { Darwin.close(fd) }
        if Darwin.fsync(fd) != 0 {
            throw JsonlPatchError.ioError(
                path: path,
                errno: errno,
                message: String(cString: strerror(errno))
            )
        }
    }

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
