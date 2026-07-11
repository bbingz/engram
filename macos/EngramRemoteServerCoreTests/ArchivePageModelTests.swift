import Foundation
@testable import EngramRemoteServerCore
import XCTest

final class ArchivePageModelTests: XCTestCase {
    private let machineA = "11111111-1111-1111-1111-111111111111"
    private let machineB = "22222222-2222-2222-2222-222222222222"
    private let manifestA = String(repeating: "a", count: 64)
    private let manifestB = String(repeating: "b", count: 64)
    private let receiptA = String(repeating: "c", count: 64)
    private let receiptB = String(repeating: "d", count: 64)

    func testMachinePageRequiresStrictLexicalOrderAndBoundedAdvancingShape() throws {
        let page = try ArchiveMachinePage(
            machineIDs: [machineA, machineB],
            nextCursor: "cursor_2"
        )
        XCTAssertEqual(
            try ArchiveCanonicalJSON.decode(
                ArchiveMachinePage.self,
                from: ArchiveCanonicalJSON.encode(page)
            ),
            page
        )

        XCTAssertThrowsError(
            try ArchiveMachinePage(machineIDs: [machineB, machineA], nextCursor: nil)
        )
        XCTAssertThrowsError(
            try ArchiveMachinePage(machineIDs: [machineA, machineA], nextCursor: nil)
        )
        XCTAssertThrowsError(
            try ArchiveMachinePage(machineIDs: [], nextCursor: "not-terminal")
        )
        XCTAssertThrowsError(
            try ArchiveMachinePage(
                machineIDs: [machineA],
                nextCursor: String(repeating: "x", count: ArchiveV2ProtocolLimits.maxCursorBytes + 1)
            )
        )
        XCTAssertThrowsError(
            try ArchiveMachinePage(
                machineIDs: ["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"],
                nextCursor: nil
            )
        )
        XCTAssertNoThrow(
            try ArchiveMachinePage(
                machineIDs: ["AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"],
                nextCursor: nil
            )
        )
    }

    func testReceiptPageValidatesSummariesOrderDuplicatesAndBounds() throws {
        let first = try ArchiveReceiptSummary(
            manifestSHA256: manifestA,
            receiptSHA256: receiptA
        )
        let second = try ArchiveReceiptSummary(
            manifestSHA256: manifestB,
            receiptSHA256: receiptB
        )
        let page = try ArchiveReceiptPage(receipts: [first, second], nextCursor: nil)

        XCTAssertEqual(
            try ArchiveCanonicalJSON.decode(
                ArchiveReceiptPage.self,
                from: ArchiveCanonicalJSON.encode(page)
            ),
            page
        )
        XCTAssertThrowsError(try ArchiveReceiptPage(receipts: [second, first], nextCursor: nil))
        XCTAssertThrowsError(try ArchiveReceiptPage(receipts: [first, first], nextCursor: nil))
        XCTAssertThrowsError(try ArchiveReceiptPage(receipts: [], nextCursor: "not-terminal"))
        XCTAssertThrowsError(
            try ArchiveReceiptPage(
                receipts: Array(repeating: first, count: ArchiveV2ProtocolLimits.maxPageItems + 1),
                nextCursor: nil
            )
        )
    }

    func testSharedPageLimitAndCursorValidationAreStrict() throws {
        XCTAssertEqual(
            try ArchiveV2ProtocolLimits.validatedPageLimit(nil),
            ArchiveV2ProtocolLimits.defaultPageLimit
        )
        XCTAssertEqual(try ArchiveV2ProtocolLimits.validatedPageLimit("1"), 1)
        XCTAssertEqual(
            try ArchiveV2ProtocolLimits.validatedPageLimit(
                String(ArchiveV2ProtocolLimits.maxPageItems)
            ),
            ArchiveV2ProtocolLimits.maxPageItems
        )
        XCTAssertThrowsError(try ArchiveV2ProtocolLimits.validatedPageLimit("0"))
        XCTAssertThrowsError(
            try ArchiveV2ProtocolLimits.validatedPageLimit(
                String(ArchiveV2ProtocolLimits.maxPageItems + 1)
            )
        )
        XCTAssertThrowsError(try ArchiveV2ProtocolLimits.validatedPageLimit("01"))
        XCTAssertThrowsError(try ArchiveV2ProtocolLimits.validatedPageLimit("not-a-number"))
        XCTAssertNoThrow(try ArchiveV2ProtocolLimits.validateCursor(nil))
        XCTAssertNoThrow(try ArchiveV2ProtocolLimits.validateCursor("AZaz09_-"))
        XCTAssertThrowsError(try ArchiveV2ProtocolLimits.validateCursor(""))
        XCTAssertThrowsError(try ArchiveV2ProtocolLimits.validateCursor("has spaces"))
    }
}
