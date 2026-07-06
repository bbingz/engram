// macos/EngramTests/ProjectsMigrationTests.swift
//
// WP11: migration-history view + batch-move + alias add/remove model wiring.
// Drives the concrete EngramServiceClient through a local recording transport
// (the existing RecordingServiceTransport is file-private to
// EngramServiceClientTests.swift and not visible here, so we re-declare our own).

import XCTest
@testable import Engram

final class ProjectsMigrationTests: XCTestCase {
    // MARK: - (a) history request + full-entry decode

    func testHistoryRequestEncodesNoStateFilterAndDecodesFullEntry() async throws {
        let transport = LocalRecordingTransport { request in
            XCTAssertEqual(request.command, "projectMigrations")
            let payload = try Self.decode(request.payload, as: EngramServiceProjectMigrationsRequest.self)
            XCTAssertNil(payload.state)
            XCTAssertEqual(payload.limit, 100)
            return .success(
                requestId: request.requestId,
                result: #"{"migrations":[{"id":"mig-1","oldPath":"/old","newPath":"/new","oldBasename":"old","newBasename":"new","state":"failed","startedAt":"2026-04-23T01:05:00Z","finishedAt":null,"archived":true,"auditNote":"left residual refs","actor":"app"}]}"#.data(using: .utf8)!
            )
        }
        let client = EngramServiceClient(transport: transport)

        let response = try await client.projectMigrations(
            EngramServiceProjectMigrationsRequest(state: nil, limit: 100)
        )

        let entry = try XCTUnwrap(response.migrations.first)
        XCTAssertEqual(entry.state, "failed")
        XCTAssertTrue(entry.archived)
        XCTAssertEqual(entry.auditNote, "left residual refs")
    }

    // MARK: - (b) batch PREVIEW body carries dry_run, COMMIT body does not

    func testBatchPreviewBodyEnablesDryRunAndCommitBodyDoesNot() throws {
        let preview = BatchMoveBody.make(
            operations: [(src: "/a", dst: "/b")],
            dryRun: true
        )
        let commit = BatchMoveBody.make(
            operations: [(src: "/a", dst: "/b")],
            dryRun: false
        )

        let previewDefaults = try Self.defaults(in: preview)
        XCTAssertEqual(previewDefaults["dry_run"] as? Bool, true)

        let commitDefaults = try Self.defaults(in: commit)
        XCTAssertNil(commitDefaults["dry_run"])
    }

    func testBatchRequestUsesEmittedBodyForDryRunNotRequestField() async throws {
        let transport = LocalRecordingTransport { request in
            XCTAssertEqual(request.command, "projectMoveBatch")
            let payload = try Self.decode(request.payload, as: EngramServiceProjectMoveBatchRequest.self)
            // The dry-run signal must live in the JSON body, never the request field.
            XCTAssertFalse(payload.dryRun)
            let defaults = try Self.defaults(in: payload.yaml)
            XCTAssertEqual(defaults["dry_run"] as? Bool, true)
            return .success(
                requestId: request.requestId,
                result: #"{"completed":[],"failed":[],"skipped":[]}"#.data(using: .utf8)!
            )
        }
        let client = EngramServiceClient(transport: transport)

        _ = try await client.projectMoveBatch(
            EngramServiceProjectMoveBatchRequest(
                yaml: BatchMoveBody.make(operations: [(src: "/a", dst: "/b")], dryRun: true),
                dryRun: false,
                force: false,
                actor: "app"
            )
        )
    }

    // MARK: - (c) batch response snake_case decode

    func testBatchResponseDecodesSnakeCaseCounts() async throws {
        let transport = LocalRecordingTransport { request in
            .success(
                requestId: request.requestId,
                result: #"{"completed":[{"migration_id":"m1","state":"committed","src":"/a","dst":"/b","files_patched":3,"occurrences":5,"sessions_updated":2}],"failed":[{"src":"/c","dst":"/d","archive":false,"error":"boom"}],"skipped":[]}"#.data(using: .utf8)!
            )
        }
        let client = EngramServiceClient(transport: transport)

        let result = try await client.projectMoveBatch(
            EngramServiceProjectMoveBatchRequest(yaml: "{}", dryRun: false, force: false, actor: "app")
        )
        let outcome = parseBatchMoveOutcome(result)

        XCTAssertEqual(outcome.completed, 1)
        XCTAssertEqual(outcome.failed, 1)
        XCTAssertEqual(outcome.skipped, 0)
        XCTAssertEqual(outcome.failures.first?.src, "/c")
        XCTAssertEqual(outcome.failures.first?.error, "boom")
    }

    // MARK: - (d) alias add AND remove both encode new_project (non-nil)

    func testAliasAddAndRemoveBothEncodeNewProject() async throws {
        let recorded = ActorBox()
        let transport = LocalRecordingTransport { request in
            XCTAssertEqual(request.command, "manageProjectAlias")
            let payload = try Self.decode(request.payload, as: EngramServiceProjectAliasRequest.self)
            await recorded.append(payload)
            return .success(
                requestId: request.requestId,
                result: #"{"ok":true,"action":"\#(payload.action)","alias":"/old","canonical":"engram","actor":"app"}"#.data(using: .utf8)!
            )
        }
        let client = EngramServiceClient(transport: transport)

        let addResult = try await client.manageProjectAlias(
            EngramServiceProjectAliasRequest(action: "add", oldProject: "/old", newProject: "engram", actor: "app")
        )
        let removeResult = try await client.manageProjectAlias(
            EngramServiceProjectAliasRequest(action: "remove", oldProject: "/old", newProject: "engram", actor: "app")
        )

        let payloads = await recorded.values
        XCTAssertEqual(payloads.count, 2)
        for payload in payloads {
            XCTAssertEqual(payload.oldProject, "/old")
            // Regression guard: remove must ALSO carry new_project (service guard).
            XCTAssertEqual(payload.newProject, "engram")
            XCTAssertEqual(payload.actor, "app")
        }
        XCTAssertEqual(payloads.map(\.action), ["add", "remove"])

        XCTAssertEqual(aliasConfirmation(addResult), "Alias added: /old → engram")
        XCTAssertEqual(aliasConfirmation(removeResult), "Alias removed: /old")
    }

    // MARK: - (e) source grep: no `engram project` CLI references

    func testProjectSheetsContainNoEngramProjectCli() throws {
        let files = [
            "macos/Engram/Views/Projects/RenameSheet.swift",
            "macos/Engram/Views/Projects/ArchiveSheet.swift",
            "macos/Engram/Views/Projects/UndoSheet.swift",
            "macos/Engram/Views/Projects/AliasSheet.swift",
            "macos/Engram/Views/Projects/BatchMoveSheet.swift",
            "macos/Engram/Views/Projects/MigrationHistoryView.swift",
        ]
        for relativePath in files {
            let source = try Self.source(relativePath)
            XCTAssertFalse(
                source.contains("engram project"),
                "\(relativePath) must not reference the non-shipping `engram project` CLI"
            )
        }
    }

    func testBulkUndoHistoryControlsLiveBehindAdvancedProjectsAffordance() throws {
        let projectsView = try Self.source("macos/Engram/Views/Pages/ProjectsView.swift")

        XCTAssertTrue(
            projectsView.contains("@State private var showAdvancedMigrationTools"),
            "ProjectsView should keep bulk project migration controls collapsed behind an explicit Advanced affordance"
        )
        XCTAssertTrue(
            projectsView.contains("Button {\n                showAdvancedMigrationTools.toggle()"),
            "Project migration batch/undo/history controls should not be visible in the default Projects toolbar"
        )
        XCTAssertTrue(
            projectsView.contains("if showAdvancedMigrationTools {"),
            "Project migration batch/undo/history controls should render only after opening Advanced"
        )
        XCTAssertTrue(
            projectsView.contains("Label(\"Advanced\", systemImage: \"slider.horizontal.3\")"),
            "The collapsed project migration affordance should be labelled Advanced"
        )

        let advancedStart = try XCTUnwrap(projectsView.range(of: "private var advancedMigrationTools: some View"))
        let defaultProjectsSurface = String(projectsView[..<advancedStart.lowerBound])
        let advancedSurface = String(projectsView[advancedStart.lowerBound...])
        for identifier in [
            "projects_batchMoveButton",
            "projects_selectToggle",
            "projects_historyButton",
            "projects_undoButton",
        ] {
            XCTAssertFalse(
                defaultProjectsSurface.contains(identifier),
                "\(identifier) should not live on the default Projects surface"
            )
            XCTAssertTrue(
                advancedSurface.contains(identifier),
                "\(identifier) should stay available behind Advanced"
            )
        }

        XCTAssertTrue(
            defaultProjectsSurface.contains("renameTarget = group.project"),
            "Single-project rename/move entry points should remain on each project row"
        )
        XCTAssertTrue(
            defaultProjectsSurface.contains("archiveTarget = group.project"),
            "Single-project archive/move entry points should remain on each project row"
        )

        let registry = try Self.source("macos/EngramMCP/Core/MCPToolRegistry.swift")
        for toolName in [
            "project_timeline",
            "project_list_migrations",
            "project_review",
            "project_move",
            "project_archive",
            "project_undo",
            "project_move_batch",
            "project_recover",
        ] {
            XCTAssertTrue(
                registry.contains("name: \"\(toolName)\""),
                "Demoting Projects UI must not remove MCP tool \(toolName)"
            )
        }
    }

    // MARK: - Helpers

    private static func decode<T: Decodable>(_ data: Data?, as type: T.Type) throws -> T {
        let data = try XCTUnwrap(data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func defaults(in json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return root["defaults"] as? [String: Any] ?? [:]
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

private actor ActorBox {
    private(set) var values: [EngramServiceProjectAliasRequest] = []
    func append(_ value: EngramServiceProjectAliasRequest) { values.append(value) }
}

private actor LocalRecordingTransport: EngramServiceTransport {
    private let handler: @Sendable (EngramServiceRequestEnvelope) async throws -> EngramServiceResponseEnvelope
    private(set) var requests: [EngramServiceRequestEnvelope] = []

    init(
        handler: @escaping @Sendable (EngramServiceRequestEnvelope) async throws -> EngramServiceResponseEnvelope
    ) {
        self.handler = handler
    }

    func send(_ request: EngramServiceRequestEnvelope, timeout: TimeInterval?) async throws -> EngramServiceResponseEnvelope {
        requests.append(request)
        return try await handler(request)
    }

    nonisolated func events() -> AsyncThrowingStream<EngramServiceEvent, Error> {
        AsyncThrowingStream { _ in }
    }

    nonisolated func close() {}
}
