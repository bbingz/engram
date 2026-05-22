import Foundation

final class StreamingLineReader {
    private let fileURL: URL
    private let chunkSize: Int
    private let maxLineBytes: Int
    private(set) var failures: [ParserFailure] = []

    init(
        fileURL: URL,
        chunkSize: Int = 64 * 1024,
        maxLineBytes: Int = ParserLimits.default.maxLineBytes
    ) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ParserFailure.fileMissing
        }
        self.fileURL = fileURL
        self.chunkSize = chunkSize
        self.maxLineBytes = maxLineBytes
    }

    func readLines() throws -> AnySequence<String> {
        let handle = try FileHandle(forReadingFrom: fileURL)
        // HandleHolder closes the file in deinit. The closure captures it, so
        // when the caller drops the iterator early (break, .prefix, throw)
        // the holder is released and the fd is closed instead of leaking
        // until process exit.
        let holder = HandleHolder(handle: handle)
        var buffer = Data()
        var eof = false
        let maxLineBytes = self.maxLineBytes
        let chunkSize = self.chunkSize

        return AnySequence {
            AnyIterator { [weak self, holder] in
                _ = holder // keep handle alive until iterator is released
                while true {
                    if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        let lineData = buffer[buffer.startIndex..<newlineIndex]
                        buffer = Data(buffer[(newlineIndex + 1)...])
                        if lineData.count > maxLineBytes {
                            self?.failures.append(.lineTooLarge)
                            continue
                        }
                        guard let line = String(data: lineData, encoding: .utf8) else {
                            self?.failures.append(.invalidUtf8)
                            continue
                        }
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty { continue }
                        return trimmed
                    }

                    if eof {
                        holder.closeNow()
                        guard !buffer.isEmpty else { return nil }
                        let remaining = buffer
                        buffer = Data()
                        if remaining.count > maxLineBytes {
                            self?.failures.append(.lineTooLarge)
                            return nil
                        }
                        guard let line = String(data: remaining, encoding: .utf8) else {
                            self?.failures.append(.invalidUtf8)
                            return nil
                        }
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        return trimmed.isEmpty ? nil : trimmed
                    }

                    if buffer.count > maxLineBytes {
                        self?.failures.append(.lineTooLarge)
                        buffer = Data()
                        while true {
                            let chunk = holder.handle.readData(ofLength: chunkSize)
                            if chunk.isEmpty {
                                eof = true
                                break
                            }
                            if let newlineIndex = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                                buffer = Data(chunk[(newlineIndex + 1)...])
                                break
                            }
                        }
                        continue
                    }

                    let chunk = holder.handle.readData(ofLength: chunkSize)
                    if chunk.isEmpty {
                        eof = true
                    } else {
                        buffer.append(chunk)
                    }
                }
            }
        }
    }
}

private final class HandleHolder {
    let handle: FileHandle
    private var closed = false
    private let lock = NSLock()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func closeNow() {
        lock.lock()
        defer { lock.unlock() }
        if !closed {
            try? handle.close()
            closed = true
        }
    }

    deinit {
        closeNow()
    }
}
