import Foundation

public enum TranscriptSizeGuardError: LocalizedError, Equatable {
    case fileTooLarge(source: String, sizeBytes: Int64, maxBytes: Int64)

    public var code: String {
        "transcriptTooLarge"
    }

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge(let source, let sizeBytes, let maxBytes):
            return "\(source) transcript is too large (\(sizeBytes) bytes; limit \(maxBytes) bytes)"
        }
    }
}

public enum TranscriptSizeGuard {
    public static let maxFullJSONTranscriptBytesEnvironmentKey = "ENGRAM_MAX_FULL_JSON_TRANSCRIPT_BYTES"
    public static let defaultMaxFullJSONTranscriptBytes: Int64 = 10 * 1024 * 1024

    public static func maxFullJSONTranscriptBytes(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int64 {
        guard
            let raw = environment[maxFullJSONTranscriptBytesEnvironmentKey],
            let parsed = Int64(raw),
            parsed > 0
        else {
            return defaultMaxFullJSONTranscriptBytes
        }
        return parsed
    }

    public static func validateFullJSONTranscript(
        filePath: String,
        source: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard
            let size = (try? FileManager.default.attributesOfItem(atPath: filePath)[.size]) as? NSNumber
        else {
            return
        }

        let maxBytes = maxFullJSONTranscriptBytes(environment: environment)
        let sizeBytes = size.int64Value
        if sizeBytes > maxBytes {
            throw TranscriptSizeGuardError.fileTooLarge(
                source: source,
                sizeBytes: sizeBytes,
                maxBytes: maxBytes
            )
        }
    }
}
