// macos/Engram/Core/StreamingJSONLReader.swift
import Foundation
import os.log

/// Streaming JSONL reader that yields one JSON line per iteration using 64KB-chunked file reads.
/// Prevents OOM on large session files by never loading the entire file into memory.
final class StreamingJSONLReader: Sequence, IteratorProtocol {
    private let fileHandle: FileHandle
    private let chunkSize: Int
    private let maxLineLength: Int
    private var buffer: Data
    private var closed: Bool = false
    private var eof: Bool = false

    private static let log = OSLog(subsystem: "com.engram.app", category: "StreamingJSONLReader")

    /// Create a streaming reader for the given JSONL file.
    /// - Parameters:
    ///   - filePath: Path to the JSONL file.
    ///   - chunkSize: Read chunk size in bytes (default 64KB).
    ///   - maxLineLength: Lines exceeding this length are skipped (default 8MB).
    init?(filePath: String, chunkSize: Int = 64 * 1024, maxLineLength: Int = 8 * 1024 * 1024) {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return nil }
        self.fileHandle = handle
        self.chunkSize = chunkSize
        self.maxLineLength = maxLineLength
        self.buffer = Data()
    }

    func next() -> String? {
        while true {
            // Try to find a newline in the buffer
            if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[(newlineIndex + 1)...])

                // Check line length before converting to string
                if lineData.count > maxLineLength {
                    os_log(.error, log: StreamingJSONLReader.log,
                           "Skipping oversized line: %d bytes (max %d)",
                           lineData.count, maxLineLength)
                    continue
                }

                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                return trimmed
            }

            // No newline found — read more data
            if eof {
                // Process any remaining data in the buffer (file didn't end with newline)
                if !buffer.isEmpty {
                    let remaining = buffer
                    buffer = Data()

                    if remaining.count > maxLineLength {
                        os_log(.error, log: StreamingJSONLReader.log,
                               "Skipping oversized final line: %d bytes (max %d)",
                               remaining.count, maxLineLength)
                        return nil
                    }

                    guard let line = String(data: remaining, encoding: .utf8) else { return nil }
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return trimmed.isEmpty ? nil : trimmed
                }
                return nil
            }

            // Check if buffer without a newline already exceeds maxLineLength
            if buffer.count > maxLineLength {
                os_log(.error, log: StreamingJSONLReader.log,
                       "Skipping oversized line in progress: %d bytes (max %d)",
                       buffer.count, maxLineLength)
                // Discard buffer and keep reading until we find the next newline
                buffer = Data()
                var discarding = true
                while discarding {
                    let chunk = fileHandle.readData(ofLength: chunkSize)
                    if chunk.isEmpty {
                        eof = true
                        return next()
                    }
                    if let newlineIndex = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                        // Keep everything after the newline
                        buffer = Data(chunk[(newlineIndex + 1)...])
                        discarding = false
                    }
                    // If no newline in chunk, keep discarding
                }
                continue
            }

            let chunk = fileHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                eof = true
                // Loop back to process remaining buffer
                continue
            }
            buffer.append(chunk)
        }
    }

    /// Close the underlying file handle. Idempotent — safe to call multiple times.
    func close() {
        guard !closed else { return }
        closed = true
        fileHandle.closeFile()
    }

    deinit {
        close()
    }
}
