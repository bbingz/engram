import AppKit
import SwiftUI
import XCTest
@testable import Engram

/// Mount the actual detail view, keep its SwiftUI identity while switching
/// sessions, and finish non-cooperative work in an explicitly chosen order.
@MainActor
final class TranscriptSessionSwitchTests: XCTestCase {
    func testOldPageCompletionCannotClearNewSessionsPagingState_repro() async throws {
        for action in [SessionDetailView.TranscriptTestAction.page, .all, .copy] {
            for fail in [false, true] {
                try await assertOldPageCompletion(action: action, fail: fail, returnToFirstSession: false)
            }
        }
        try await assertOldPageCompletion(action: .page, fail: false, returnToFirstSession: true)
    }

    private func assertOldPageCompletion(
        action: SessionDetailView.TranscriptTestAction, fail: Bool, returnToFirstSession: Bool
    ) async throws {
        let fixture = Fixture()
        fixture.label = "action=\(action) fail=\(fail) return=\(returnToFirstSession)"
        defer { fixture.close() }
        try await fixture.waitForRequest("A", offset: 0)
        fixture.finish("A", offset: 0, text: "A initial", count: 500)
        try await fixture.waitForState { $0.sessionID == "A" && !$0.loading && $0.indexed == ["A initial"] }
        fixture.send?(action)
        try await fixture.waitForRequest("A", offset: 500)

        fixture.model.session = Self.session("B")
        try await fixture.waitForRequest("B", offset: 0)
        fixture.finish("B", offset: 0, text: "B initial", count: 500)
        try await fixture.waitForState { $0.sessionID == "B" && !$0.loading && $0.indexed == ["B initial"] }
        let current = returnToFirstSession ? "A" : "B"
        if returnToFirstSession {
            fixture.model.session = Self.session("A")
            try await fixture.waitForRequest("A", offset: 0)
            fixture.finish("A", offset: 0, text: "A current", count: 500)
            try await fixture.waitForState { $0.sessionID == "A" && !$0.loading && $0.indexed == ["A current"] }
        }
        let initial = returnToFirstSession ? "A current" : "B initial"
        fixture.send?(.page)
        try await fixture.waitForRequest(current, offset: 500, count: returnToFirstSession ? 2 : 1)
        try await fixture.waitForState("current page busy before old completion") { $0.paging }

        // The old cancelled task can resume its defer while the current page is
        // waiting, including A -> B -> A. A session ID alone is insufficient.
        fixture.finish("A", offset: 500, text: "A stale page", count: 1, fail: fail)
        try await fixture.settle()
        let state = try XCTUnwrap(fixture.state)
        XCTAssertEqual(state.sessionID, current)
        XCTAssertEqual(state.messages, [initial])
        XCTAssertEqual(state.indexed, [initial])
        XCTAssertFalse(state.failed)
        XCTAssertTrue(fixture.copies.isEmpty, "Cancelled copy work must not write a stale transcript")
        XCTAssertTrue(state.paging, "Old-page cleanup must not unlock a new session's in-flight page")
        let requests = fixture.requestCount
        fixture.send?(.page)
        try await fixture.settle()
        XCTAssertEqual(fixture.requestCount, requests, "A duplicate click must not start or cancel the current page")
        guard fixture.requestCount == requests else { return }
        fixture.finish(current, offset: 500, text: "current next", count: 1)
        try await fixture.waitForState("current page committed") { !$0.paging && $0.indexed == [initial, "current next"] }
    }

    func testCurrentPageAllAndCopyCompleteAndReleaseBusyState() async throws {
        for action in [SessionDetailView.TranscriptTestAction.page, .all, .copy] {
            let fixture = Fixture()
            defer { fixture.close() }
            try await fixture.waitForRequest("A", offset: 0)
            fixture.finish("A", offset: 0, text: "current initial", count: 500)
            try await fixture.waitForState { !$0.loading && $0.indexed == ["current initial"] }
            fixture.send?(action)
            try await fixture.waitForRequest("A", offset: 500)
            fixture.finish("A", offset: 500, text: "current next", count: 1)
            try await fixture.waitForState { !$0.paging && !$0.hasMore && $0.indexed == ["current initial", "current next"] }
            if case .copy = action {
                XCTAssertEqual(fixture.copies.count, 1)
                XCTAssertTrue(fixture.copies.first?.contains("current initial") == true)
                XCTAssertTrue(fixture.copies.first?.contains("current next") == true)
            } else { XCTAssertTrue(fixture.copies.isEmpty) }
        }
    }

    func testImmediateDuplicatePagingActionsStartOnlyOneRequest_repro() async throws {
        for action in [SessionDetailView.TranscriptTestAction.page, .all, .copy] {
            let fixture = Fixture()
            defer { fixture.close() }
            try await fixture.waitForRequest("A", offset: 0)
            fixture.finish("A", offset: 0, text: "A initial", count: 500)
            try await fixture.waitForState { !$0.loading && $0.indexed == ["A initial"] }
            fixture.send?(action)
            fixture.send?(action)
            try await fixture.waitForRequest("A", offset: 500)
            try await fixture.settle()
            XCTAssertEqual(fixture.requestCount, 2, "Mark paging busy before scheduling its task")
        }
    }

    func testCancelledIndexBuildCannotReplaceNewSession() async throws {
        let fixture = Fixture(holdFirstIndex: true)
        defer { fixture.close() }
        try await fixture.waitForRequest("A", offset: 0)
        fixture.finish("A", offset: 0, text: "A old", count: 1)
        try await fixture.waitForIndex()
        fixture.model.session = Self.session("B")
        try await fixture.waitForRequest("B", offset: 0)
        fixture.finish("B", offset: 0, text: "B current", count: 1)
        try await fixture.waitForState { $0.sessionID == "B" && !$0.loading && $0.indexed == ["B current"] }
        fixture.finishIndex()
        try await fixture.settle()
        XCTAssertEqual(fixture.state?.messages, ["B current"])
        XCTAssertEqual(fixture.state?.indexed, ["B current"])
    }

    func testOldInitialSuccessAndFailureCannotReplaceNewTranscript() async throws {
        for fail in [false, true] {
            let fixture = Fixture()
            defer { fixture.close() }
            try await fixture.waitForRequest("A", offset: 0)
            fixture.model.session = Self.session("B")
            try await fixture.waitForRequest("B", offset: 0)
            fixture.finish("B", offset: 0, text: "B current", count: 1)
            try await fixture.waitForState { $0.sessionID == "B" && !$0.loading && $0.indexed == ["B current"] }
            fixture.finish("A", offset: 0, text: "A stale", count: 1, fail: fail)
            try await fixture.settle()
            let state = try XCTUnwrap(fixture.state)
            XCTAssertEqual(state.messages, ["B current"])
            XCTAssertEqual(state.indexed, ["B current"])
            XCTAssertFalse(state.failed)
            XCTAssertFalse(state.hasMore)
        }
    }

    fileprivate static func session(_ id: String) -> Session {
        Session(id: id, source: "codex", startTime: "2026-10-23T00:00:00Z", endTime: nil,
            cwd: "/tmp/engram-transcript-switch", project: nil, model: nil,
            messageCount: 1_000, userMessageCount: 500, assistantMessageCount: 500,
            systemMessageCount: 0, summary: nil, filePath: "/tmp/fixture-unused.jsonl",
            sourceLocator: nil, sizeBytes: 0, indexedAt: "2026-10-23T00:00:00Z",
            agentRole: nil, hiddenAt: nil, customName: id, tier: nil, toolMessageCount: 0,
            generatedTitle: nil, parentSessionId: nil, suggestedParentId: nil, linkSource: nil)
    }

    @MainActor private final class Model: ObservableObject {
        @Published var session = TranscriptSessionSwitchTests.session("A")
    }

    private struct Host: View {
        @ObservedObject var model: Model
        let hooks: SessionDetailView.TranscriptTestHooks
        let database: DatabaseManager
        var body: some View {
            SessionDetailView(session: model.session, transcriptTestHooks: hooks)
                .environment(database)
                .environment(\.engramServiceClient, MockEngramServiceClient())
        }
    }

    @MainActor private final class Fixture {
        typealias Window = (messages: [ChatMessage], producedCount: Int, truncated: Bool, parseFailed: Bool)
        let model = Model()
        private var readState: (() -> SessionDetailView.TranscriptTestState)?
        private var actionSessionID: String?
        var state: SessionDetailView.TranscriptTestState? { readState?() }
        var send: ((SessionDetailView.TranscriptTestAction) -> Void)?
        var requestCount = 0
        var label = ""
        var requests: [String] = []
        var copies: [String] = []
        private var pending: [String: [CheckedContinuation<Window, Error>]] = [:]
        private var window: NSWindow?

        private var pendingIndex: CheckedContinuation<Void, Never>?

        init(holdFirstIndex: Bool = false) {
            var holdIndex = holdFirstIndex
            let hooks = SessionDetailView.TranscriptTestHooks(parse: { [weak self] id, offset, _ in
                guard let self else { throw CancellationError() }
                return try await withCheckedThrowingContinuation { continuation in
                    self.requestCount += 1
                    self.requests.append("\(id):\(offset)")
                    self.pending["\(id):\(offset)", default: []].append(continuation)
                }
            }, attach: { [weak self] sessionID, readState, send in
                self?.actionSessionID = sessionID
                self?.readState = readState
                self?.send = send
            }, beforeIndexedApply: { [weak self] in
                guard holdIndex, let self else { return }
                holdIndex = false
                await withCheckedContinuation { self.pendingIndex = $0 }
            }, copy: { [weak self] in self?.copies.append($0) })
            let database = DatabaseManager(path: "/tmp/engram-switch-\(UUID().uuidString)/absent.sqlite")
            let hosting = NSHostingView(rootView: Host(model: model, hooks: hooks, database: database))
            let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 900, height: 700),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            self.window = window
        }

        func close() {
            window?.contentView = nil
            window?.close()
            window = nil
            let remaining = pending.values.flatMap { $0 }
            pending.removeAll()
            for continuation in remaining { continuation.resume(throwing: CancellationError()) }
            finishIndex()
            send = nil
            readState = nil
        }

        func finish(_ id: String, offset: Int, text: String, count: Int, fail: Bool = false) {
            let key = "\(id):\(offset)"
            guard var items = pending[key], !items.isEmpty else {
                XCTFail("No pending parser request for \(key)"); return
            }
            let continuation = items.removeFirst()
            pending[key] = items
            if fail { continuation.resume(throwing: CocoaError(.fileReadCorruptFile)) }
            else {
                continuation.resume(returning: ([ChatMessage(role: "user", content: text, systemCategory: .none)],
                    count, false, false))
            }
        }

        func waitForRequest(_ id: String, offset: Int, count: Int = 1) async throws {
            try await wait("request \(id):\(offset) count \(count)") { (self.pending["\(id):\(offset)"]?.count ?? 0) >= count }
        }

        func waitForIndex() async throws {
            try await wait { self.pendingIndex != nil }
        }

        func finishIndex() {
            let continuation = pendingIndex
            pendingIndex = nil
            continuation?.resume()
        }

        func waitForState(_ detail: String = "state", _ predicate: (SessionDetailView.TranscriptTestState) -> Bool) async throws {
            try await wait(detail) {
                guard let state = self.state, state.sessionID == self.actionSessionID else { return false }
                return predicate(state)
            }
        }

        private func wait(_ detail: String = "state", _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard condition() else {
                XCTFail("Mounted transcript \(label) waiting for \(detail), requests \(requests), state \(String(describing: state))")
                throw CocoaError(.coderInvalidValue)
            }
        }

        func settle() async throws {
            try await Task.sleep(for: .milliseconds(150))
        }
    }
}
