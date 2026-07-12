import EngramCoreRead
import XCTest

final class ArchiveModelTests: XCTestCase {
    private let captureDigest = String(repeating: "a", count: 64)
    private let sourceDigest = String(repeating: "b", count: 64)
    private let chunkDigest = String(repeating: "c", count: 64)
    private let manifestDigest = String(repeating: "d", count: 64)
    private let machineID = "123e4567-e89b-12d3-a456-426614174000"

    func testSHA256KnownVectorsAndValidation() {
        XCTAssertEqual(
            ArchiveV2Hash.sha256(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            ArchiveV2Hash.sha256(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertTrue(ArchiveV2Hash.isValidSHA256(sourceDigest))
        XCTAssertFalse(ArchiveV2Hash.isValidSHA256(String(repeating: "A", count: 64)))
        XCTAssertFalse(ArchiveV2Hash.isValidSHA256(String(repeating: "a", count: 63)))
    }

    func testCanonicalManifestEncodingIsStableAndRoundTrips() throws {
        let manifest = try makeManifest()

        let encoded = try ArchiveCanonicalJSON.encode(manifest)

        let expected = "{\"captureID\":\"\(captureDigest)\",\"capturedAt\":\"2026-07-11T00:00:00.000Z\",\"chunkSize\":8388608,\"chunks\":[{\"ordinal\":0,\"rawByteCount\":5,\"rawSHA256\":\"\(chunkDigest)\"}],\"generation\":{\"ctimeNs\":6,\"device\":1,\"inode\":2,\"mode\":33188,\"mtimeNs\":5,\"size\":5},\"locator\":\"/tmp/source.jsonl\",\"machineID\":\"\(machineID)\",\"rawByteCount\":5,\"replayLayout\":{\"relativePaths\":[\"sessions/session.jsonl\"],\"strategy\":\"singleFile\"},\"schemaVersion\":1,\"sessionID\":\"session-1\",\"source\":\"codex\",\"wholeSourceSHA256\":\"\(sourceDigest)\"}"
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), expected)
        XCTAssertEqual(
            try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: encoded),
            manifest
        )
    }

    func testCanonicalDecodeRejectsReorderedKeys() throws {
        let canonical = try ArchiveCanonicalJSON.encode(makeManifest())
        let canonicalString = String(decoding: canonical, as: UTF8.self)
        let withoutSchemaVersion = canonicalString.replacingOccurrences(
            of: ",\"schemaVersion\":1",
            with: ""
        )
        let reordered = Data(
            ("{\"schemaVersion\":1," + String(withoutSchemaVersion.dropFirst())).utf8
        )

        XCTAssertThrowsError(
            try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: reordered)
        )
    }

    func testCanonicalDecodeRejectsInsignificantWhitespace() throws {
        let canonical = try ArchiveCanonicalJSON.encode(makeManifest())
        var withLeadingWhitespace = Data(" \n".utf8)
        withLeadingWhitespace.append(canonical)

        XCTAssertThrowsError(
            try ArchiveCanonicalJSON.decode(
                ArchiveSourceManifest.self,
                from: withLeadingWhitespace
            )
        )
    }

    func testCanonicalDecodeRejectsUTF8BOM() throws {
        let canonical = try ArchiveCanonicalJSON.encode(makeManifest())
        var withBOM = Data([0xEF, 0xBB, 0xBF])
        withBOM.append(canonical)

        XCTAssertThrowsError(
            try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: withBOM)
        )
    }

    func testCanonicalDecodeRejectsAlternateEscapedSlashBytes() throws {
        let canonical = try ArchiveCanonicalJSON.encode(makeManifest())
        let alternate = Data(
            String(decoding: canonical, as: UTF8.self)
                .replacingOccurrences(
                    of: "/tmp/source.jsonl",
                    with: "\\/tmp\\/source.jsonl"
                )
                .utf8
        )

        XCTAssertThrowsError(
            try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: alternate)
        )
    }

    func testCanonicalDecodeRejectsDuplicateKeys() throws {
        let canonical = try ArchiveCanonicalJSON.encode(makeManifest())
        let canonicalString = String(decoding: canonical, as: UTF8.self)
        let duplicate = Data(
            ("{\"schemaVersion\":1," + String(canonicalString.dropFirst())).utf8
        )

        XCTAssertThrowsError(
            try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: duplicate)
        )
    }

    func testDigestValidationRejectsUppercaseAndShortValues() {
        XCTAssertThrowsError(
            try ArchiveChunkReference(
                ordinal: 0,
                rawSHA256: String(repeating: "A", count: 64),
                rawByteCount: 1
            )
        )
        XCTAssertThrowsError(
            try ArchiveChunkReference(
                ordinal: 0,
                rawSHA256: String(repeating: "a", count: 63),
                rawByteCount: 1
            )
        )
    }

    func testManifestRejectsNonContiguousChunkOrdinals() throws {
        let chunk = try ArchiveChunkReference(
            ordinal: 1,
            rawSHA256: chunkDigest,
            rawByteCount: 5
        )

        XCTAssertThrowsError(try makeManifest(chunks: [chunk], rawByteCount: 5)) { error in
            XCTAssertEqual(
                error as? ArchiveV2ValidationError,
                .nonContiguousChunkOrdinal(expected: 0, actual: 1)
            )
        }
    }

    func testManifestRejectsAggregateByteMismatch() throws {
        let chunk = try ArchiveChunkReference(
            ordinal: 0,
            rawSHA256: chunkDigest,
            rawByteCount: 5
        )

        XCTAssertThrowsError(try makeManifest(chunks: [chunk], rawByteCount: 4)) { error in
            XCTAssertEqual(
                error as? ArchiveV2ValidationError,
                .aggregateRawByteCountMismatch(expected: 4, actual: 5)
            )
        }
    }

    func testManifestDecodeRevalidatesSchemaVersion() throws {
        let encoded = try ArchiveCanonicalJSON.encode(makeManifest())
        let invalid = try XCTUnwrap(
            String(data: encoded, encoding: .utf8)?.replacingOccurrences(
                of: "\"schemaVersion\":1",
                with: "\"schemaVersion\":2"
            ).data(using: .utf8)
        )

        XCTAssertThrowsError(
            try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: invalid)
        )
    }

    func testReplayLayoutRejectsInvalidV1Paths() throws {
        let invalidPathSets = [
            [],
            [""],
            ["."],
            ["/absolute/session.jsonl"],
            ["sessions//session.jsonl"],
            ["sessions/./session.jsonl"],
            ["sessions/../session.jsonl"],
            ["sessions/session\u{0}.jsonl"],
            ["session.jsonl", "session.jsonl"],
            ["one.jsonl", "two.jsonl"],
        ]

        for relativePaths in invalidPathSets {
            XCTAssertThrowsError(
                try ArchiveReplayLayout(
                    strategy: .singleFile,
                    relativePaths: relativePaths
                ),
                "Expected rejection for \(relativePaths)"
            )
        }
    }

    func testReplayLayoutDecodeRevalidatesRelativePath() throws {
        let encoded = try ArchiveCanonicalJSON.encode(makeManifest())
        let invalid = try XCTUnwrap(
            String(data: encoded, encoding: .utf8)?.replacingOccurrences(
                of: "sessions/session.jsonl",
                with: "/absolute/session.jsonl"
            ).data(using: .utf8)
        )

        XCTAssertThrowsError(
            try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: invalid)
        )
    }

    func testReceiptValidatesAgainstCanonicalBoundManifest() throws {
        let manifestBytes = try ArchiveCanonicalJSON.encode(makeManifest())
        let receipt = try makeReceipt(manifestSHA256: ArchiveV2Hash.sha256(manifestBytes))

        XCTAssertNoThrow(
            try receipt.validate(againstCanonicalManifestBytes: manifestBytes)
        )
    }

    func testReceiptValidationRejectsEveryManifestRelationMismatch() throws {
        let manifestBytes = try ArchiveCanonicalJSON.encode(makeManifest())
        let manifestSHA256 = ArchiveV2Hash.sha256(manifestBytes)
        let mismatches: [(String, ArchiveServerReceipt, ArchiveV2ValidationError)] = [
            (
                "machineID",
                try makeReceipt(
                    machineID: "223e4567-e89b-12d3-a456-426614174000",
                    manifestSHA256: manifestSHA256
                ),
                .receiptManifestMismatch(field: "machineID")
            ),
            (
                "sessionID",
                try makeReceipt(
                    sessionID: "session-2",
                    manifestSHA256: manifestSHA256
                ),
                .receiptManifestMismatch(field: "sessionID")
            ),
            (
                "captureID",
                try makeReceipt(
                    captureID: String(repeating: "e", count: 64),
                    manifestSHA256: manifestSHA256
                ),
                .receiptManifestMismatch(field: "captureID")
            ),
            (
                "manifestSHA256",
                try makeReceipt(manifestSHA256: String(repeating: "e", count: 64)),
                .receiptManifestMismatch(field: "manifestSHA256")
            ),
            (
                "wholeSourceSHA256",
                try makeReceipt(
                    manifestSHA256: manifestSHA256,
                    wholeSourceSHA256: String(repeating: "e", count: 64)
                ),
                .receiptManifestMismatch(field: "wholeSourceSHA256")
            ),
            (
                "objectCount",
                try makeReceipt(manifestSHA256: manifestSHA256, objectCount: 2),
                .receiptManifestMismatch(field: "objectCount")
            ),
            (
                "rawByteCount",
                try makeReceipt(manifestSHA256: manifestSHA256, rawByteCount: 6),
                .receiptManifestMismatch(field: "rawByteCount")
            ),
        ]

        for (field, receipt, expectedError) in mismatches {
            XCTAssertThrowsError(
                try receipt.validate(againstCanonicalManifestBytes: manifestBytes),
                "Expected mismatch for \(field)"
            ) { error in
                XCTAssertEqual(error as? ArchiveV2ValidationError, expectedError)
            }
        }
    }

    func testReceiptValidationRejectsUnboundManifest() throws {
        let manifestBytes = try ArchiveCanonicalJSON.encode(
            makeManifest(sessionID: nil)
        )
        let receipt = try makeReceipt(manifestSHA256: ArchiveV2Hash.sha256(manifestBytes))

        XCTAssertThrowsError(
            try receipt.validate(againstCanonicalManifestBytes: manifestBytes)
        ) { error in
            XCTAssertEqual(
                error as? ArchiveV2ValidationError,
                .receiptRequiresBoundManifest
            )
        }
    }

    func testReceiptValidationRejectsNonCanonicalManifestBytes() throws {
        let canonical = try ArchiveCanonicalJSON.encode(makeManifest())
        let receipt = try makeReceipt(manifestSHA256: ArchiveV2Hash.sha256(canonical))
        var nonCanonical = Data(" ".utf8)
        nonCanonical.append(canonical)

        XCTAssertThrowsError(
            try receipt.validate(againstCanonicalManifestBytes: nonCanonical)
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCanonicalJSONError,
                .nonCanonicalEncoding
            )
        }
    }

    func testReceiptRequiresBoundSessionID() throws {
        XCTAssertThrowsError(
            try ArchiveServerReceipt(
                schemaVersion: 1,
                serverID: "hq",
                machineID: machineID,
                sessionID: "",
                captureID: captureDigest,
                manifestSHA256: manifestDigest,
                wholeSourceSHA256: sourceDigest,
                objectCount: 1,
                rawByteCount: 5,
                storedAt: "2026-07-11T00:01:00.000Z"
            )
        )

        let receiptWithoutSession = Data("{\"captureID\":\"\(captureDigest)\",\"machineID\":\"\(machineID)\",\"manifestSHA256\":\"\(manifestDigest)\",\"objectCount\":1,\"rawByteCount\":5,\"schemaVersion\":1,\"serverID\":\"hq\",\"storedAt\":\"2026-07-11T00:01:00.000Z\",\"wholeSourceSHA256\":\"\(sourceDigest)\"}".utf8)
        XCTAssertThrowsError(
            try ArchiveCanonicalJSON.decode(ArchiveServerReceipt.self, from: receiptWithoutSession)
        )

        XCTAssertThrowsError(
            try makeReceipt(schemaVersion: 2)
        )
        XCTAssertThrowsError(
            try makeReceipt(serverID: "")
        )

        let receipt = try makeReceipt()
        let encoded = try ArchiveCanonicalJSON.encode(receipt)
        XCTAssertEqual(
            try ArchiveCanonicalJSON.decode(ArchiveServerReceipt.self, from: encoded),
            receipt
        )
    }

    func testReceiptRequiresCanonicalFractionalSecondUTCTimestamp() throws {
        let nonCanonicalValues = [
            "2026-07-11T00:01:00Z",
            "2026-07-11T00:01:00.000+00:00",
            "2026-07-11T00:01:00.00Z",
            "2026-07-11T00:01:00.0000Z",
            "2026-07-11t00:01:00.000z",
            "2026-07-11T00:01:00.000Z ",
        ]

        for storedAt in nonCanonicalValues {
            XCTAssertThrowsError(
                try ArchiveServerReceipt(
                    serverID: "hq",
                    machineID: machineID,
                    sessionID: "session-1",
                    captureID: captureDigest,
                    manifestSHA256: manifestDigest,
                    wholeSourceSHA256: sourceDigest,
                    objectCount: 1,
                    rawByteCount: 5,
                    storedAt: storedAt
                ),
                "Expected non-canonical timestamp rejection for \(storedAt)"
            ) { error in
                XCTAssertEqual(
                    error as? ArchiveV2ValidationError,
                    .invalidValue(field: "storedAt")
                )
            }
        }

        XCTAssertNoThrow(
            try ArchiveServerReceipt(
                serverID: "hq",
                machineID: machineID,
                sessionID: "session-1",
                captureID: captureDigest,
                manifestSHA256: manifestDigest,
                wholeSourceSHA256: sourceDigest,
                objectCount: 1,
                rawByteCount: 5,
                storedAt: "2026-07-11T00:01:00.000Z"
            )
        )
    }

    private func makeReceipt(
        schemaVersion: Int = 1,
        serverID: String = "hq",
        machineID: String? = nil,
        sessionID: String = "session-1",
        captureID: String? = nil,
        manifestSHA256: String? = nil,
        wholeSourceSHA256: String? = nil,
        objectCount: Int = 1,
        rawByteCount: Int64 = 5
    ) throws -> ArchiveServerReceipt {
        let resolvedManifestSHA256 = try manifestSHA256 ?? ArchiveV2Hash.sha256(
            ArchiveCanonicalJSON.encode(makeManifest())
        )
        return try ArchiveServerReceipt(
            schemaVersion: schemaVersion,
            serverID: serverID,
            machineID: machineID ?? self.machineID,
            sessionID: sessionID,
            captureID: captureID ?? captureDigest,
            manifestSHA256: resolvedManifestSHA256,
            wholeSourceSHA256: wholeSourceSHA256 ?? sourceDigest,
            objectCount: objectCount,
            rawByteCount: rawByteCount,
            storedAt: "2026-07-11T00:01:00.000Z"
        )
    }

    private func makeManifest(
        chunks: [ArchiveChunkReference]? = nil,
        rawByteCount: Int64 = 5,
        sessionID: String? = "session-1"
    ) throws -> ArchiveSourceManifest {
        let generation = try ArchiveSourceGeneration(
            device: 1,
            inode: 2,
            size: rawByteCount,
            mtimeNs: 5,
            ctimeNs: 6,
            mode: 33_188
        )
        let resolvedChunks = try chunks ?? [
            ArchiveChunkReference(
                ordinal: 0,
                rawSHA256: chunkDigest,
                rawByteCount: 5
            ),
        ]
        let replayLayout = try ArchiveReplayLayout(
            strategy: .singleFile,
            relativePaths: ["sessions/session.jsonl"]
        )
        return try ArchiveSourceManifest(
            schemaVersion: 1,
            captureID: captureDigest,
            machineID: machineID,
            source: "codex",
            locator: "/tmp/source.jsonl",
            sessionID: sessionID,
            capturedAt: "2026-07-11T00:00:00.000Z",
            generation: generation,
            wholeSourceSHA256: sourceDigest,
            rawByteCount: rawByteCount,
            chunkSize: 8 * 1024 * 1024,
            chunks: resolvedChunks,
            replayLayout: replayLayout
        )
    }
}
