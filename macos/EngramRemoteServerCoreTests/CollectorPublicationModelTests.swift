import Foundation
@testable import EngramRemoteServerCore
import XCTest

enum CollectorPublicationFixtures {
    static let machineID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    static let sourceInstanceID = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    static let collectorEpoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
    static let journalID = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
    static let otherJournalID = "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE"
    static let manifestSHA256 = String(repeating: "a", count: 64)
    static let publicationSHA256 = "e39d4c295640a695248b877725afaeae3836d813de7b47ab0f3f1bf6dad1866a"
    static let storedAt = "2026-09-05T00:00:00.000Z"
    static let publicationJSON = #"{"collectorEpoch":"CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC","machineID":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","manifestSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","representation":"exact-source-v1","schemaVersion":1,"sequence":7,"sourceInstanceID":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"}"#
    static let zeroCursor = "eyJhZnRlckFycml2YWxPcmRpbmFsIjowLCJqb3VybmFsSUQiOiJERERERERERC1ERERELTREREQtOERERC1EREREREREREREREQiLCJzY2hlbWFWZXJzaW9uIjoxfQ"

    static func publication(sequence: Int64 = 7) throws -> CollectorPublicationEnvelope {
        try CollectorPublicationEnvelope(
            machineID: machineID,
            sourceInstanceID: sourceInstanceID,
            collectorEpoch: collectorEpoch,
            sequence: sequence,
            manifestSHA256: manifestSHA256
        )
    }

    static func ack(
        publication: CollectorPublicationEnvelope,
        serverID: String = "hq",
        journalID: String = CollectorPublicationFixtures.journalID,
        arrivalOrdinal: Int64 = 1
    ) throws -> CollectorPublicationACK {
        try CollectorPublicationACK(
            serverID: serverID,
            journalID: journalID,
            arrivalOrdinal: arrivalOrdinal,
            publicationSHA256: publication.sha256(),
            manifestSHA256: publication.manifestSHA256,
            storedAt: storedAt
        )
    }

    static func record(
        sequence: Int64 = 7,
        arrivalOrdinal: Int64 = 1,
        serverID: String = "hq",
        journalID: String = CollectorPublicationFixtures.journalID
    ) throws -> CollectorPublicationAcceptanceRecord {
        let publication = try publication(sequence: sequence)
        return try CollectorPublicationAcceptanceRecord(
            publication: publication,
            ack: ack(publication: publication, serverID: serverID, journalID: journalID, arrivalOrdinal: arrivalOrdinal)
        )
    }

    static func cursor(_ ordinal: Int64, journalID: String = CollectorPublicationFixtures.journalID) throws -> String {
        try CollectorPublicationCursor(journalID: journalID, afterArrivalOrdinal: ordinal).encoded()
    }
}

final class CollectorPublicationModelTests: XCTestCase {
    private typealias F = CollectorPublicationFixtures

    func testPublicationCanonicalGoldenBytesAndDigest() throws {
        let publication = try F.publication()
        let bytes = try ArchiveCanonicalJSON.encode(publication)
        XCTAssertEqual(bytes, Data(F.publicationJSON.utf8))
        XCTAssertEqual(bytes.count, 316)
        XCTAssertEqual(try publication.sha256(), F.publicationSHA256)
        XCTAssertEqual(try ArchiveCanonicalJSON.decode(CollectorPublicationEnvelope.self, from: bytes), publication)
        XCTAssertLessThan(bytes.count, CollectorPublicationProtocolLimits.maxPublicationBytes)
    }

    func testAcceptanceRecordGoldenAndACKAreDistinctFromLegacyReceipt() throws {
        let record = try F.record()
        let bytes = try ArchiveCanonicalJSON.encode(record)
        XCTAssertEqual(bytes.count, 671)
        XCTAssertEqual(ArchiveV2Hash.sha256(bytes), "c02bae57685b614cff80cdff049cc1af7aa1848db486881663ecb1ccf94e0d64")
        XCTAssertEqual(try ArchiveCanonicalJSON.encode(record.ack).count, 314)
        XCTAssertEqual(try ArchiveCanonicalJSON.decode(CollectorPublicationAcceptanceRecord.self, from: bytes), record)
        XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveServerReceipt.self, from: ArchiveCanonicalJSON.encode(record.ack)))
        XCTAssertLessThan(bytes.count, CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes)
    }

    func testUUIDsRejectNonCanonicalCaseAndMalformedValuesInEveryInitializerAndDecoder() throws {
        for field in ["machineID", "sourceInstanceID", "collectorEpoch"] {
            for value in [F.machineID.lowercased(), "not-a-uuid", "", " " + F.machineID] {
                try assertDecodeRejects(CollectorPublicationEnvelope.self, original: F.publication(), field: field, value: value)
            }
        }
        XCTAssertThrowsError(try CollectorPublicationEnvelope(machineID: F.machineID.lowercased(), sourceInstanceID: F.sourceInstanceID, collectorEpoch: F.collectorEpoch, sequence: 1, manifestSHA256: F.manifestSHA256))
        XCTAssertThrowsError(try CollectorPublicationCursor(journalID: F.journalID.lowercased(), afterArrivalOrdinal: 0))
        try assertDecodeRejects(CollectorPublicationACK.self, original: F.record().ack, field: "journalID", value: F.journalID.lowercased())
    }

    func testVersionRepresentationDigestAndInt64Bounds() throws {
        let publication = try F.publication()
        for value in [0, 2, -1] {
            try assertDecodeRejects(CollectorPublicationEnvelope.self, original: publication, field: "schemaVersion", value: value)
        }
        for value in ["", "exact-source-v2", "EXACT-SOURCE-V1"] {
            try assertDecodeRejects(CollectorPublicationEnvelope.self, original: publication, field: "representation", value: value)
        }
        for value in ["a", String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            try assertDecodeRejects(CollectorPublicationEnvelope.self, original: publication, field: "manifestSHA256", value: value)
        }
        for value in [Int64(0), -1, .min] { XCTAssertThrowsError(try F.publication(sequence: value)) }
        XCTAssertEqual(try roundTrip(F.publication(sequence: .max)).sequence, .max)
        for literal in ["0", "-1", "9223372036854775808", "7.5", "7.0", "7e0", "\"7\"", "true", "null"] {
            let bytes = Data(F.publicationJSON.replacingOccurrences(of: "\"sequence\":7", with: "\"sequence\":" + literal).utf8)
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(CollectorPublicationEnvelope.self, from: bytes), literal)
        }
    }

    func testCanonicalDecoderRejectsUnknownFieldsDuplicateKeysWhitespaceAndMissingFields() throws {
        let extra = F.publicationJSON.dropLast() + ",\"unknown\":true}"
        let duplicate = F.publicationJSON.replacingOccurrences(of: "\"sequence\":7", with: "\"sequence\":7,\"sequence\":7")
        let missing = F.publicationJSON.replacingOccurrences(of: "\"schemaVersion\":1,", with: "")
        for value in [String(extra), duplicate, missing, " " + F.publicationJSON, F.publicationJSON + "\n"] {
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(CollectorPublicationEnvelope.self, from: Data(value.utf8)))
        }
    }

    func testACKValidatesSafeServerTimestampDigestsAndOrdinal() throws {
        let ack = try F.record().ack
        for value in ["", ".", "..", "a/b", "a b", String(repeating: "x", count: 129), "é"] {
            try assertDecodeRejects(CollectorPublicationACK.self, original: ack, field: "serverID", value: value)
            XCTAssertThrowsError(try CollectorPublicationCapabilities(serverID: value))
        }
        for value in ["hq", "m1", "future_server-2.example", String(repeating: "x", count: 128)] {
            XCTAssertNoThrow(try F.ack(publication: F.publication(), serverID: value))
        }
        for value in ["", "2026-09-05T00:00:00Z", "2026-09-05T00:00:00.000+00:00", "2026-02-30T00:00:00.000Z", "2026-09-05T24:00:00.000Z", "2026-09-05T00:00:00.0000Z"] {
            try assertDecodeRejects(CollectorPublicationACK.self, original: ack, field: "storedAt", value: value)
        }
        for field in ["publicationSHA256", "manifestSHA256"] {
            try assertDecodeRejects(CollectorPublicationACK.self, original: ack, field: field, value: "invalid")
        }
        for value in [Int64(0), -1, .min] {
            XCTAssertThrowsError(try F.ack(publication: F.publication(), arrivalOrdinal: value))
        }
        XCTAssertEqual(try roundTrip(F.ack(publication: F.publication(), arrivalOrdinal: .max)).arrivalOrdinal, .max)
        try assertDecodeRejects(CollectorPublicationACK.self, original: ack, field: "schemaVersion", value: 2)
    }

    func testACKAndAcceptanceRecordRejectMismatchedProof() throws {
        let publication = try F.publication()
        let ack = try F.ack(publication: publication)
        XCTAssertNoThrow(try ack.validate(against: publication, expectedServerID: "hq"))
        XCTAssertThrowsError(try ack.validate(against: publication, expectedServerID: "m1"))
        XCTAssertThrowsError(try ack.validate(against: F.publication(sequence: 8), expectedServerID: "hq"))
        let wrongManifest = try CollectorPublicationACK(serverID: "hq", journalID: F.journalID, arrivalOrdinal: 1, publicationSHA256: F.publicationSHA256, manifestSHA256: String(repeating: "b", count: 64), storedAt: F.storedAt)
        XCTAssertThrowsError(try wrongManifest.validate(against: publication, expectedServerID: "hq"))
        XCTAssertThrowsError(try CollectorPublicationAcceptanceRecord(publication: publication, ack: wrongManifest))
        let record = try F.record()
        try assertDecodeRejects(CollectorPublicationAcceptanceRecord.self, original: record, field: "schemaVersion", value: 2)
        try assertDecodeRejects(CollectorPublicationAcceptanceRecord.self, original: record, field: "publication", value: object(F.publication(sequence: 8)))
    }

    func testACKTimestampRejectsExtendedYearDespiteISOFormatterRoundTrip_repro() throws {
        let extendedYear = "10000-09-05T00:00:00.000Z"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let date = try XCTUnwrap(formatter.date(from: extendedYear))
        XCTAssertEqual(formatter.string(from: date), extendedYear)
        XCTAssertEqual(extendedYear.utf8.count, 25)
        try assertDecodeRejects(CollectorPublicationACK.self, original: F.record().ack, field: "storedAt", value: extendedYear)
    }

    func testCursorGoldenInt64EOFAndStrictCanonicalEncoding() throws {
        XCTAssertEqual(try F.cursor(0), F.zeroCursor)
        XCTAssertEqual(try CollectorPublicationCursor.decode(F.zeroCursor).afterArrivalOrdinal, 0)
        XCTAssertEqual(try CollectorPublicationCursor.decode(F.cursor(.max)).afterArrivalOrdinal, .max)
        XCTAssertThrowsError(try CollectorPublicationCursor(journalID: F.journalID, afterArrivalOrdinal: -1))
        XCTAssertThrowsError(try CollectorPublicationCursor(schemaVersion: 2, journalID: F.journalID, afterArrivalOrdinal: 0))
        for value in ["", F.zeroCursor + "=", F.zeroCursor + "==", " " + F.zeroCursor, "a/b+c", String(repeating: "a", count: 257)] {
            XCTAssertThrowsError(try CollectorPublicationCursor.decode(value), value)
        }
        let cursor = try CollectorPublicationCursor(journalID: F.journalID, afterArrivalOrdinal: 0)
        let noncanonical = Data((String(decoding: try ArchiveCanonicalJSON.encode(cursor), as: UTF8.self) + "\n").utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertThrowsError(try CollectorPublicationCursor.decode(noncanonical))
    }

    func testPagesRetainEOFAndAcceptArrivalOrderIndependentOfCollectorSequence() throws {
        let records = try [F.record(sequence: 9, arrivalOrdinal: 1), F.record(sequence: 2, arrivalOrdinal: 2)]
        let page = try CollectorPublicationPage(items: records, afterCursor: F.cursor(2), hasMore: false)
        XCTAssertEqual(try roundTrip(page), page)
        XCTAssertNoThrow(try page.validate(after: nil, expectedServerID: "hq"))
        let cursor = try CollectorPublicationCursor.decode(page.afterCursor)
        let eof = try CollectorPublicationPage(items: [], afterCursor: page.afterCursor, hasMore: false)
        XCTAssertNoThrow(try eof.validate(after: cursor, expectedServerID: "hq"))
        let next = try CollectorPublicationPage(items: [F.record(sequence: 1, arrivalOrdinal: 3)], afterCursor: F.cursor(3), hasMore: false)
        XCTAssertNoThrow(try next.validate(after: cursor, expectedServerID: "hq"))
        XCTAssertNoThrow(try CollectorPublicationPage(items: [], afterCursor: F.zeroCursor, hasMore: false).validate(after: nil, expectedServerID: "hq"))
    }

    func testPageInitializerRejectsNonAdvancingMixedDuplicateAndOversizedShapes() throws {
        let a = try F.record(sequence: 7, arrivalOrdinal: 1)
        let b = try F.record(sequence: 8, arrivalOrdinal: 2)
        for items in [[b, a], [a, a], [a, try F.record(sequence: 7, arrivalOrdinal: 2)], [a, try F.record(sequence: 8, arrivalOrdinal: 2, serverID: "m1")], [a, try F.record(sequence: 8, arrivalOrdinal: 2, journalID: F.otherJournalID)]] {
            XCTAssertThrowsError(try CollectorPublicationPage(items: items, afterCursor: F.cursor(2), hasMore: false))
        }
        XCTAssertThrowsError(try CollectorPublicationPage(items: [], afterCursor: F.zeroCursor, hasMore: true))
        XCTAssertThrowsError(try CollectorPublicationPage(items: [a], afterCursor: F.cursor(2), hasMore: false))
        XCTAssertThrowsError(try CollectorPublicationPage(items: [a], afterCursor: F.cursor(1, journalID: F.otherJournalID), hasMore: false))
        XCTAssertThrowsError(try CollectorPublicationPage(items: [], afterCursor: "invalid", hasMore: false))
        let tooMany = try (1...101).map { try F.record(sequence: Int64($0), arrivalOrdinal: Int64($0)) }
        XCTAssertThrowsError(try CollectorPublicationPage(items: tooMany, afterCursor: F.cursor(101), hasMore: false))
        let maximum = try CollectorPublicationPage(items: Array(tooMany.prefix(100)), afterCursor: F.cursor(100), hasMore: true)
        XCTAssertLessThanOrEqual(try ArchiveCanonicalJSON.encode(maximum).count, CollectorPublicationProtocolLimits.maxPageBytes)
        try assertDecodeRejects(CollectorPublicationPage.self, original: maximum, field: "hasMore", value: "yes")
        try assertDecodeRejects(CollectorPublicationPage.self, original: maximum, field: "schemaVersion", value: 2)
    }

    func testPageResponseValidationRejectsWrongReplicaJournalAndSkippedEOFPosition() throws {
        let page = try CollectorPublicationPage(items: [F.record()], afterCursor: F.cursor(1), hasMore: false)
        XCTAssertThrowsError(try page.validate(after: nil, expectedServerID: "m1"))
        XCTAssertThrowsError(try page.validate(after: CollectorPublicationCursor.decode(F.cursor(1)), expectedServerID: "hq"))
        XCTAssertThrowsError(try page.validate(after: CollectorPublicationCursor(journalID: F.otherJournalID, afterArrivalOrdinal: 0), expectedServerID: "hq"))
        let eof = try CollectorPublicationPage(items: [], afterCursor: F.cursor(2), hasMore: false)
        XCTAssertThrowsError(try eof.validate(after: CollectorPublicationCursor.decode(F.cursor(1)), expectedServerID: "hq"))
        XCTAssertThrowsError(try eof.validate(after: nil, expectedServerID: "hq"))
    }

    func testCapabilitiesAndLimitsAreFrozenAndStrictlyDecoded() throws {
        let capabilities = try CollectorPublicationCapabilities(serverID: "hq")
        XCTAssertEqual(try roundTrip(capabilities), capabilities)
        XCTAssertEqual(capabilities.publicationSchemaVersions, [1])
        XCTAssertEqual(capabilities.representations, ["exact-source-v1"])
        XCTAssertEqual(capabilities.maxPublicationBytes, 2048)
        XCTAssertEqual(capabilities.maxAcceptanceRecordBytes, 4096)
        XCTAssertEqual(capabilities.maxPageBytes, 262144)
        XCTAssertEqual(capabilities.defaultPageLimit, 50)
        XCTAssertEqual(capabilities.maxPageItems, 100)
        XCTAssertEqual(capabilities.maxCursorBytes, 256)
        for field in ["schemaVersion", "maxPublicationBytes", "maxAcceptanceRecordBytes", "maxPageBytes", "defaultPageLimit", "maxPageItems", "maxCursorBytes"] {
            try assertDecodeRejects(CollectorPublicationCapabilities.self, original: capabilities, field: field, value: -1)
        }
        try assertDecodeRejects(CollectorPublicationCapabilities.self, original: capabilities, field: "publicationSchemaVersions", value: [1, 2])
        try assertDecodeRejects(CollectorPublicationCapabilities.self, original: capabilities, field: "representations", value: ["unknown"])
        try assertDecodeRejects(CollectorPublicationCapabilities.self, original: capabilities, field: "serverID", value: "unsafe/path")
        XCTAssertEqual(try CollectorPublicationProtocolLimits.validatedPageLimit(nil), 50)
        XCTAssertEqual(try CollectorPublicationProtocolLimits.validatedPageLimit("1"), 1)
        XCTAssertEqual(try CollectorPublicationProtocolLimits.validatedPageLimit("100"), 100)
        for value in ["0", "101", "-1", "01", "+1", "1.0", "", " 1", "999999999999999999999999"] {
            XCTAssertThrowsError(try CollectorPublicationProtocolLimits.validatedPageLimit(value))
        }
        XCTAssertEqual(CollectorPublicationErrorCode.sequenceConflict.rawValue, "sequence_conflict")
        XCTAssertEqual(CollectorPublicationErrorCode.storageUnavailable.rawValue, "storage_unavailable")
    }

    func testExistingSchemaOneManifestBytesRemainUnextendedAndLowercaseMachineRemainsReadable() throws {
        let emptyDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let manifest = try ArchiveSourceManifest(captureID: F.manifestSHA256, machineID: F.machineID.lowercased(), source: "codex", locator: "/fixture.jsonl", sessionID: nil, capturedAt: F.storedAt, generation: ArchiveSourceGeneration(device: 1, inode: 2, size: 0, mtimeNs: 3, ctimeNs: 4, mode: 33152), wholeSourceSHA256: emptyDigest, rawByteCount: 0, chunks: [], replayLayout: ArchiveReplayLayout(strategy: .singleFile, relativePaths: ["fixture.jsonl"]))
        let bytes = try ArchiveCanonicalJSON.encode(manifest)
        let json = #"{"captureID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","capturedAt":"2026-09-05T00:00:00.000Z","chunkSize":8388608,"chunks":[],"generation":{"ctimeNs":4,"device":1,"inode":2,"mode":33152,"mtimeNs":3,"size":0},"locator":"/fixture.jsonl","machineID":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","rawByteCount":0,"replayLayout":{"relativePaths":["fixture.jsonl"],"strategy":"singleFile"},"schemaVersion":1,"source":"codex","wholeSourceSHA256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}"#
        XCTAssertEqual(bytes, Data(json.utf8))
        XCTAssertEqual(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes), manifest)
        try assertDecodeRejects(ArchiveSourceManifest.self, original: manifest, field: "sequence", value: 1)
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try ArchiveCanonicalJSON.decode(T.self, from: ArchiveCanonicalJSON.encode(value))
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ArchiveCanonicalJSON.encode(value)) as? [String: Any])
    }

    private func assertDecodeRejects<T: Codable>(
        _ type: T.Type,
        original: T,
        field: String,
        value: Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var json = try object(original)
        json[field] = value
        let bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(type, from: bytes), field, file: file, line: line)
    }
}
