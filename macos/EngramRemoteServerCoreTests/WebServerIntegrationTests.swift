import CryptoKit
import Darwin
import Foundation
@testable import EngramRemoteServerCore
import XCTest

/// These requests traverse App.run's actual HTTP listener, not a Router fixture.
/// Cookies are forwarded explicitly: this is not a browser/HTTPS cookie-store test.
final class WebServerIntegrationTests: XCTestCase {
    private static let viewer = "a4-test-viewer"
    private static let origin = "http://127.0.0.1:8787"
    private static let authority = "127.0.0.1:8787"
    private static let generation = String(repeating: "a", count: 64)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-a4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private var socketPath: String { directory.appendingPathComponent("service.sock").path }
    private var messagesPath: String { "/web/api/sessions/session-a/messages?generation=\(Self.generation)" }

    private func config(webEnabled: Bool = true, archiveEnabled: Bool = false) throws -> EngramRemoteServerConfig {
        try EngramRemoteServerConfig(
            host: "127.0.0.1", port: 0, storeRoot: directory.appendingPathComponent("legacy"),
            bearerToken: "a4-v1-token", atRestKey: SymmetricKey(data: Data(repeating: 1, count: 32)),
            archiveV2: archiveEnabled ? EngramRemoteArchiveConfig(
                serverID: "hq", root: directory.appendingPathComponent("archive"),
                bearerToken: "a4-archive-token", atRestKey: SymmetricKey(data: Data(repeating: 2, count: 32))
            ) : nil,
            mcp: archiveEnabled ? EngramRemoteMCPConfig(bearerToken: "a4-mcp-token") : nil,
            web: webEnabled ? Self.webConfiguration() : nil,
            webServiceSocketPath: webEnabled ? socketPath : nil
        )
    }

    private static func webConfiguration(credentials: [String] = []) throws -> EngramRemoteWebConfig {
        try .forLoopbackHTTPTesting(origin: origin, viewerCredential: viewer, serverBearerCredentials: credentials)
    }

    private var baseEnvironment: [String: String] {
        ["ENGRAM_REMOTE_TOKEN": "a4-v1-token",
         "ENGRAM_REMOTE_AT_REST_KEY": Data(repeating: 1, count: 32).base64EncodedString(),
         "ENGRAM_REMOTE_STORE": directory.appendingPathComponent("environment-store").path]
    }

    private var webEnvironment: [String: String] {
        baseEnvironment.merging([
            "ENGRAM_REMOTE_WEB_ENABLED": "1", "ENGRAM_REMOTE_WEB_ORIGIN": "https://viewer.example:9443",
            "ENGRAM_REMOTE_WEB_VIEWER_CREDENTIAL": Self.viewer, "ENGRAM_REMOTE_WEB_SERVICE_SOCKET": socketPath,
        ]) { _, value in value }
    }

    func testWebConfigurationDefaultsOffAndExplicitValuesRoundTrip() throws {
        let off = try config(webEnabled: false)
        XCTAssertNil(off.web)
        XCTAssertNil(off.webServiceSocketPath)
        let on = try config()
        XCTAssertEqual(on.web?.origin, Self.origin)
        XCTAssertEqual(on.webServiceSocketPath, socketPath)
    }

    func testEnvironmentOffIgnoresWebValuesAndDoesNotGuessSocketPath() throws {
        for flag in [nil, "0"] as [String?] {
            var environment = baseEnvironment
            environment["ENGRAM_REMOTE_WEB_ENABLED"] = flag
            environment["ENGRAM_REMOTE_WEB_ORIGIN"] = "invalid"
            environment["ENGRAM_REMOTE_WEB_VIEWER_CREDENTIAL"] = "a4-v1-token"
            environment["ENGRAM_REMOTE_WEB_SERVICE_SOCKET"] = "/"
            let value = try EngramRemoteServerConfig.fromEnvironment(environment)
            XCTAssertNil(value.web)
            XCTAssertNil(value.webServiceSocketPath)
        }
    }

    func testEnvironmentEnabledLoadsWebAndExactExplicitSocketPath() throws {
        let value = try EngramRemoteServerConfig.fromEnvironment(webEnvironment)
        XCTAssertEqual(value.web?.origin, "https://viewer.example:9443")
        XCTAssertEqual(value.web?.authority, "viewer.example:9443")
        XCTAssertEqual(value.webServiceSocketPath, socketPath)
    }

    func testEnvironmentEnabledRequiresSocketInsteadOfProductionHomeFallback() throws {
        for path in [nil, ""] as [String?] {
            var environment = webEnvironment
            environment["ENGRAM_REMOTE_WEB_SERVICE_SOCKET"] = path
            XCTAssertThrowsError(try EngramRemoteServerConfig.fromEnvironment(environment)) {
                guard case EngramRemoteServerConfig.ConfigError.missingWebServiceSocketPath = $0 else {
                    return XCTFail("Expected missing explicit Web socket, got \($0)")
                }
            }
        }
    }

    func testEnvironmentRejectsRelativeRootNULAndOverlongSocketPaths() throws {
        for path in Self.invalidSocketPaths {
            var environment = webEnvironment
            environment["ENGRAM_REMOTE_WEB_SERVICE_SOCKET"] = path
            XCTAssertThrowsError(try EngramRemoteServerConfig.fromEnvironment(environment)) {
                guard case EngramRemoteServerConfig.ConfigError.invalidWebServiceSocketPath = $0 else {
                    return XCTFail("Expected rejected Web socket shape, got \($0)")
                }
            }
        }
    }

    func testEnvironmentSocketLengthUsesUTF8BytesAndAcceptsTheNativeBoundary() throws {
        for path in ["/" + String(repeating: "a", count: 102), "/" + String(repeating: "中", count: 34)] {
            XCTAssertEqual(path.utf8.count, 103)
            var environment = webEnvironment
            environment["ENGRAM_REMOTE_WEB_SERVICE_SOCKET"] = path
            XCTAssertEqual(try EngramRemoteServerConfig.fromEnvironment(environment).webServiceSocketPath, path)
        }
    }

    func testEnvironmentActuallyInvokesFrozenWebConfigurationValidation() throws {
        for (key, value) in [
            ("ENGRAM_REMOTE_WEB_ENABLED", "true"),
            ("ENGRAM_REMOTE_WEB_ORIGIN", "http://127.0.0.1:8787"),
            ("ENGRAM_REMOTE_WEB_ORIGIN", "https://viewer.example/"),
            ("ENGRAM_REMOTE_WEB_VIEWER_CREDENTIAL", ""),
        ] {
            var environment = webEnvironment
            environment[key] = value
            XCTAssertThrowsError(try EngramRemoteServerConfig.fromEnvironment(environment))
        }
    }

    func testEnvironmentChecksEveryProvidedBearerIncludingDisabledArchiveAndMCP() throws {
        for key in ["ENGRAM_REMOTE_TOKEN", "ENGRAM_REMOTE_ARCHIVE_TOKEN", "ENGRAM_REMOTE_MCP_TOKEN"] {
            var environment = webEnvironment
            environment[key] = Self.viewer
            environment["ENGRAM_REMOTE_ARCHIVE_ENABLED"] = "0"
            environment["ENGRAM_REMOTE_MCP_ENABLED"] = "0"
            XCTAssertThrowsError(try EngramRemoteServerConfig.fromEnvironment(environment)) {
                XCTAssertEqual($0 as? EngramRemoteWebConfig.ConfigError, .credentialMustBeDistinct)
            }
        }
    }

    func testAppRejectsOmittedLegacyBearerBeforeBlobStoreCreation() throws {
        try assertAppCredentialRejected(target: .legacy, mutateAfterWebCreation: false)
    }

    func testAppRejectsOmittedArchiveBearerBeforeBlobStoreCreation() throws {
        try assertAppCredentialRejected(target: .archive, mutateAfterWebCreation: false)
    }

    func testAppRejectsOmittedMCPBearerBeforeBlobStoreCreation() throws {
        try assertAppCredentialRejected(target: .mcp, mutateAfterWebCreation: false)
    }

    func testAppRechecksLegacyBearerMutatedAfterWebConfigurationCreation() throws {
        try assertAppCredentialRejected(target: .legacy, mutateAfterWebCreation: true)
    }

    func testAppRechecksArchiveBearerMutatedAfterWebConfigurationCreation() throws {
        try assertAppCredentialRejected(target: .archive, mutateAfterWebCreation: true)
    }

    func testAppRechecksMCPBearerMutatedAfterWebConfigurationCreation() throws {
        try assertAppCredentialRejected(target: .mcp, mutateAfterWebCreation: true)
    }

    func testAppRechecksMissingAndMutatedSocketBeforeCreatingStoresOrReader() throws {
        for path in [nil, ""] + Self.invalidSocketPaths.map(Optional.some) {
            var value = try config(archiveEnabled: true)
            value.webServiceSocketPath = path
            let calls = A4Recorder<String>()
            XCTAssertThrowsError(try EngramRemoteServerApp(config: value, webReadClientFactory: { path in
                calls.append(path)
                throw A4Failure("Reader factory must not be reached")
            }))
            XCTAssertTrue(calls.values.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: value.storeRoot.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(value.archiveV2).root.path))
        }
    }

    func testAppCreatesInjectedReaderOnceWithExactConfiguredSocket() throws {
        let value = try config()
        let calls = A4Recorder<String>()
        _ = try EngramRemoteServerApp(config: value, webReadClientFactory: { path in
            calls.append(path)
            return { _ in throw EngramServiceWebReadClientError.unavailable }
        })
        XCTAssertEqual(calls.values, [socketPath])
    }

    func testDefaultOffReturns404WithZeroFactoryCallsAndZeroRealSocketAccepts() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        var value = try config(webEnabled: false)
        value.webServiceSocketPath = socketPath
        let calls = A4Recorder<String>()
        try await withServer(value, factory: { path in
            calls.append(path)
            throw A4Failure("OFF must not construct a reader")
        }) { server in
            for (method, path) in [("GET", "/web"), ("GET", "/web/api/overview"),
                                   ("GET", self.messagesPath), ("POST", "/web/api/auth"), ("DELETE", "/web/api/auth")] {
                let response = try await server.request(method, path, headers: Self.originHeaders)
                XCTAssertEqual(response.status, 404)
            }
        }
        XCTAssertTrue(calls.values.isEmpty)
        assertNoIPC(fixture)
    }

    func testUnknownWebPathsWithWrongHostGetDecorated403BeforeRouting() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        try await withServer(config()) { server in
            for path in ["/web", "/web/missing", "/web/api", "/web/api/not-a-route"] {
                let response = try await server.request("GET", path, authority: "evil.example")
                XCTAssertEqual(response.status, 403, path)
                Self.assertSecurityHeaders(response)
            }
        }
        assertNoIPC(fixture)
    }

    func testUnknownWebPathsWithCorrectHostGetDecorated404() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        try await withServer(config()) { server in
            for path in ["/web", "/web/missing", "/web/api", "/web/api/not-a-route"] {
                let response = try await server.request("GET", path)
                XCTAssertEqual(response.status, 404, path)
                Self.assertSecurityHeaders(response)
            }
        }
        assertNoIPC(fixture)
    }

    func testActualHTTPAuthorityIsExactAndForwardedHeadersCannotRepairIt() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        try await withServer(config()) { server in
            for authority in ["127.0.0.1", "127.0.0.1:80", "127.0.0.1.:8787", "localhost:8787", "evil.example:8787"] {
                let response = try await server.request("POST", "/web/api/auth", authority: authority,
                    headers: Self.loginHeaders + [("X-Forwarded-Host", Self.authority), ("Forwarded", "host=\(Self.authority);proto=http")],
                    body: Self.loginBody)
                XCTAssertEqual(response.status, 403, authority)
                Self.assertSecurityHeaders(response)
            }
        }
        assertNoIPC(fixture)
    }

    func testUnauthenticatedCookiesAndServerBearerCannotCauseIPC() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        try await withServer(config()) { server in
            for extra in [[], [("Authorization", "Bearer a4-v1-token")], [("Cookie", "engram_web_test=bad")],
                          [("Cookie", "engram_web_test=\(String(repeating: "A", count: 43))")]] as [[(String, String)]] {
                let response = try await server.request("GET", self.messagesPath, headers: Self.originHeaders + extra)
                XCTAssertEqual(response.status, 401)
                Self.assertSecurityHeaders(response)
            }
        }
        assertNoIPC(fixture)
    }

    func testAmbiguousValidSessionCookiesAreRejectedBeforeIPCOverHTTP() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        try await withServer(config()) { server in
            let cookie = try await Self.login(server)
            for headers in [[("Cookie", cookie), ("Cookie", cookie)], [("Cookie", cookie + "; " + cookie)],
                            [("Cookie", cookie + ", " + cookie)]] {
                let response = try await server.request("GET", self.messagesPath, headers: Self.originHeaders + headers)
                XCTAssertEqual(response.status, 401)
                Self.assertSecurityHeaders(response)
            }
        }
        assertNoIPC(fixture)
    }

    func testPresentInvalidOriginNeverFallsBackToFetchMetadataOverHTTP() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        try await withServer(config()) { server in
            let cookie = try await Self.login(server)
            for origins in [["null"], ["http://evil.example"], [Self.origin + "/"], ["http://127.0.0.1"], [Self.origin, Self.origin]] {
                let response = try await server.request("GET", self.messagesPath,
                    headers: Self.metadataHeaders + [("Cookie", cookie)] + origins.map { ("Origin", $0) })
                XCTAssertEqual(response.status, 403)
                Self.assertSecurityHeaders(response)
            }
        }
        assertNoIPC(fixture)
    }

    func testAbsentOriginRequiresCompleteSingleExactFetchMetadataBeforeIPC() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        try await withServer(config()) { server in
            let cookie = try await Self.login(server)
            for missing in ["X-Engram-Web", "Sec-Fetch-Site", "Sec-Fetch-Mode", "Sec-Fetch-Dest"] {
                let response = try await server.request("GET", self.messagesPath,
                    headers: Self.metadataHeaders.filter { $0.0 != missing } + [("Cookie", cookie)])
                XCTAssertEqual(response.status, 403, missing)
            }
            for (name, value) in [("Sec-Fetch-Site", "same-site"), ("Sec-Fetch-Mode", "no-cors"), ("Sec-Fetch-Dest", "document")] {
                let headers = Self.metadataHeaders.map { $0.0 == name ? (name, value) : $0 }
                A4AssertHTTPStatus(try await server.request("GET", self.messagesPath, headers: headers + [("Cookie", cookie)]), 403)
            }
            A4AssertHTTPStatus(try await server.request("GET", self.messagesPath,
                headers: Self.metadataHeaders + [("X-Engram-Web", "1"), ("Cookie", cookie)]), 403)
        }
        assertNoIPC(fixture)
    }

    func testMatchingOriginAndBothAllowedFetchModesReachOnlyTypedMessagesIPC() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        try await withServer(config()) { server in
            let cookie = try await Self.login(server)
            let sameOrigin = Self.metadataHeaders.map { $0.0 == "Sec-Fetch-Mode" ? ($0.0, "same-origin") : $0 }
            for headers in [Self.originHeaders, Self.metadataHeaders, sameOrigin] {
                let response = try await server.request("GET", self.messagesPath, headers: headers + [("Cookie", cookie)])
                XCTAssertEqual(response.status, 200)
                Self.assertSecurityHeaders(response)
            }
        }
        XCTAssertEqual(fixture.acceptCount, 3)
        XCTAssertEqual(fixture.requests.count, 3)
        for request in fixture.requests {
            XCTAssertEqual(request.command, "webMessages")
            XCTAssertEqual(request.kind, "request")
            XCTAssertNil(request.capabilityToken)
            XCTAssertFalse(request.requestId.isEmpty)
        }
        XCTAssertEqual(Set(fixture.requests.map(\.requestId)).count, 3)
    }

    func testHEADOPTIONSAndAllWriteMethodsAreRejectedBeforeIPC() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        try await withServer(config()) { server in
            let cookie = try await Self.login(server)
            for method in ["HEAD", "OPTIONS", "POST", "PUT", "PATCH", "DELETE"] {
                let response = try await server.request(method, self.messagesPath,
                    headers: Self.originHeaders + [("Cookie", cookie)])
                XCTAssertEqual(response.status, 405, method)
                Self.assertSecurityHeaders(response)
            }
        }
        assertNoIPC(fixture)
    }

    func testLoginAndLogoutRequireOriginEvenWithValidMetadata() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        try await withServer(config()) { server in
            for method in ["POST", "DELETE"] {
                let response = try await server.request(method, "/web/api/auth",
                    headers: Self.metadataHeaders + [("Content-Type", "application/json")],
                    body: method == "POST" ? Self.loginBody : Data("{}".utf8))
                XCTAssertEqual(response.status, 403)
                Self.assertSecurityHeaders(response)
            }
        }
        assertNoIPC(fixture)
    }

    func testLoginReadLogoutShareOneAuthorityAcrossSeparateTCPConnections() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        try await withServer(config()) { server in
            let cookie = try await Self.login(server)
            let read = try await server.request("GET", self.messagesPath, headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(read.status, 200)
            let logout = try await server.request("DELETE", "/web/api/auth",
                headers: Self.loginHeaders + [("Cookie", cookie)], body: Data("{}".utf8))
            XCTAssertEqual(logout.status, 204)
            XCTAssertTrue(logout.header("set-cookie")?.contains("Max-Age=0") == true)
            Self.assertSecurityHeaders(logout)
            let after = try await server.request("GET", self.messagesPath, headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(after.status, 401)
            Self.assertSecurityHeaders(after)
        }
        XCTAssertEqual(fixture.acceptCount, 1)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testSeparateRespondersFromTheSameAppShareOneSessionAuthority() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let app = try EngramRemoteServerApp(config: config())
        let first = try await A4HTTPServer(app: app)
        do {
            let second = try await A4HTTPServer(app: app)
            do {
                let cookie = try await Self.login(first)
                A4AssertHTTPStatus(try await second.request("GET", messagesPath, headers: Self.originHeaders + [("Cookie", cookie)]), 200)
                A4AssertHTTPStatus(try await second.request("DELETE", "/web/api/auth",
                    headers: Self.loginHeaders + [("Cookie", cookie)], body: Data("{}".utf8)), 204)
                A4AssertHTTPStatus(try await first.request("GET", messagesPath, headers: Self.originHeaders + [("Cookie", cookie)]), 401)
            } catch {
                do { try await second.stop() } catch { XCTFail("Second responder cleanup failed: \(error)") }
                throw error
            }
            try await second.stop()
        } catch {
            do { try await first.stop() } catch { XCTFail("First responder cleanup failed: \(error)") }
            throw error
        }
        try await first.stop()
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testUnimplementedOverviewListAndDetailRemain404WithNoIPC() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        try await withServer(config()) { server in
            let cookie = try await Self.login(server)
            for path in ["/web/api/overview", "/web/api/sessions", "/web/api/sessions/session-a"] {
                let response = try await server.request("GET", path, headers: Self.originHeaders + [("Cookie", cookie)])
                XCTAssertEqual(response.status, 404)
                Self.assertSecurityHeaders(response)
            }
        }
        assertNoIPC(fixture)
    }

    func testDecodedUnicodeIdentityOpaqueCursorAndCanonicalRolesReachTypedDTOUnchanged() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let sessionID = "session-中文-e\u{301}"
        let cursor = "opaque+/= &中文"
        let path = "/web/api/sessions/\(Self.queryEncode(sessionID))/messages?generation=\(Self.generation)&roles=user,assistant&cursor=\(Self.queryEncode(cursor))&maxFragments=3"
        try await withServer(config()) { server in
            let cookie = try await Self.login(server)
            let response = try await server.request("GET", path, headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(response.status, 200)
        }
        let envelope = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(fixture.requests.count, 1)
        let request = try JSONDecoder().decode(EngramServiceWebMessagesRequest.self, from: XCTUnwrap(envelope.payload))
        XCTAssertEqual(Data(request.sessionId.utf8), Data(sessionID.utf8))
        XCTAssertEqual(request.generation, Self.generation)
        XCTAssertEqual(request.roles, [.assistant, .user])
        XCTAssertEqual(request.cursor, cursor)
        XCTAssertEqual(request.maxFragments, 3)
        XCTAssertEqual(envelope.command, "webMessages")
        XCTAssertNil(envelope.capabilityToken)
    }

    func testLiteralPlusInOpaqueCursorIsNotFormDecodedToSpace() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        try await withServer(config()) { server in
            let cookie = try await Self.login(server)
            A4AssertHTTPStatus(try await server.request("GET", self.messagesPath + "&cursor=opaque+value",
                headers: Self.originHeaders + [("Cookie", cookie)]), 200)
        }
        let request = try Self.decode(try XCTUnwrap(fixture.requests.first))
        XCTAssertEqual(request.cursor, "opaque+value")
    }

    func testStrictQueryRejectsMissingDuplicateUnknownAndMalformedParametersWithoutIPC() async throws {
        try await assertRejectedQueries([
            "", "roles=user", "generation=\(Self.generation)&generation=\(Self.generation)",
            "generation=\(Self.generation)&%67eneration=\(Self.generation)",
            "generation=\(Self.generation)&roles=user&roles=assistant",
            "generation=\(Self.generation)&cursor=a&cursor=b",
            "generation=\(Self.generation)&maxFragments=1&maxFragments=2",
            "generation=\(Self.generation)&command=status", "generation=\(Self.generation)&capabilityToken=secret",
            "generation=\(Self.generation)&unknown=1", "generation=\(Self.generation)&cursor=%ZZ",
            "generation=\(Self.generation)&cursor=%FF", "generation=\(Self.generation)&cursor=%00",
            "generation=\(Self.generation)&cursor", "generation=\(Self.generation)&&roles=user",
        ])
    }

    func testStrictQueryRejectsInvalidGenerationWithoutIPC() async throws {
        try await assertRejectedQueries(["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                                        String(repeating: "A", count: 64), String(repeating: "g", count: 64)]
            .map { "generation=\($0)" })
    }

    func testStrictQueryRejectsInvalidRoleSetsWithoutIPC() async throws {
        try await assertRejectedQueries(["", "user,user", "User", "admin", "user,", ",user", "user,%20assistant", "user,assistant,tool,system,user"]
            .map { "generation=\(Self.generation)&roles=\($0)" })
    }

    func testStrictQueryRejectsEmptyAndUTF8OverlongCursorWithoutIPC() async throws {
        try await assertRejectedQueries(["", String(repeating: "a", count: 1025), String(repeating: "中", count: 342)]
            .map { "generation=\(Self.generation)&cursor=\(Self.queryEncode($0))" })
    }

    func testStrictQueryRejectsNoncanonicalAndOutOfRangeFragmentLimitsWithoutIPC() async throws {
        try await assertRejectedQueries(["", "0", "-1", "101", "1.0", "1e2", "+1", "01", "%201", String(repeating: "9", count: 500)]
            .map { "generation=\(Self.generation)&maxFragments=\($0)" })
    }

    func testTypedQueryDefaultsAndInclusiveFragmentLimitBounds() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        try await withServer(config()) { server in
            let cookie = try await Self.login(server)
            for suffix in ["", "&maxFragments=1", "&maxFragments=100"] {
                A4AssertHTTPStatus(try await server.request("GET", self.messagesPath + suffix,
                    headers: Self.originHeaders + [("Cookie", cookie)]), 200)
            }
        }
        let requests = try fixture.requests.map(Self.decode)
        XCTAssertEqual(requests.map(\.maxFragments), [50, 1, 100])
        XCTAssertTrue(requests.allSatisfy { $0.cursor == nil })
        XCTAssertTrue(requests.allSatisfy { $0.roles == [.assistant, .system, .tool, .user] })
    }

    func testIllegalAndOverlongSessionPathsAreRejectedWithoutIPC() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        try await withServer(config()) { server in
            let cookie = try await Self.login(server)
            for id in ["%00", "%2F", "%5C", "%2E%2E", "%0A"] {
                let response = try await server.request("GET", "/web/api/sessions/\(id)/messages?generation=\(Self.generation)",
                    headers: Self.originHeaders + [("Cookie", cookie)])
                XCTAssertEqual(response.status, 404)
                Self.assertSecurityHeaders(response)
            }
            let oversized = "/web/api/sessions/\(String(repeating: "x", count: 4097))/messages?generation=\(Self.generation)"
            A4AssertHTTPStatus(try await server.request("GET", oversized, headers: Self.originHeaders + [("Cookie", cookie)]), 400)
        }
        assertNoIPC(fixture)
    }

    func testCompleteUnicodeFragmentDTOIsEncodedFaithfullyWithoutReassembly() async throws {
        let fixture = try fixture { request in
            let page = try Self.page(Self.decode(request), split: true)
            return try Self.success(page, id: request.requestId)
        }
        defer { fixture.stop() }
        try await withServer(config()) { server in
            let cookie = try await Self.login(server)
            let response = try await server.request("GET", self.messagesPath, headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(response.status, 200)
            XCTAssertTrue(response.header("content-type")?.hasPrefix("application/json") == true)
            Self.assertSecurityHeaders(response)
            let actual = try JSONDecoder().decode(EngramServiceWebMessagesResponse.self, from: response.body)
            let expected = try Self.page(EngramServiceWebMessagesRequest(sessionId: "session-a", generation: Self.generation), split: true)
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(actual.fragments.map { Data($0.payloadFragment.utf8) }, expected.fragments.map { Data($0.payloadFragment.utf8) })
            XCTAssertEqual(actual.fragments.count, 2)
            XCTAssertEqual(actual.fragments[1].utf8Offset, actual.fragments[0].payloadFragment.utf8.count)
            XCTAssertGreaterThan(actual.fragments[0].payloadFragment.utf8.count, actual.fragments[0].payloadFragment.count)
            XCTAssertTrue(actual.isComplete)
            XCTAssertLessThanOrEqual(response.body.count, EngramServiceWebReadLimits.maximumPageEnvelopeBytes)
        }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testPartialPagePreservesOpaqueNextCursorAndEveryCompletenessMarker() async throws {
        let fixture = try fixture { request in
            try Self.success(Self.page(Self.decode(request), partial: true), id: request.requestId)
        }
        defer { fixture.stop() }
        try await withServer(config()) { server in
            let cookie = try await Self.login(server)
            let response = try await server.request("GET", self.messagesPath, headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(response.status, 200)
            let actual = try JSONDecoder().decode(EngramServiceWebMessagesResponse.self, from: response.body)
            let expected = try Self.page(EngramServiceWebMessagesRequest(sessionId: "session-a", generation: Self.generation), partial: true)
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(actual.nextCursor, "next+/=opaque")
            XCTAssertFalse(actual.totalKnownComplete)
            XCTAssertEqual(actual.truncatedAt, 7)
            XCTAssertEqual(actual.parseFailure, "truncatedJSONL")
            XCTAssertFalse(actual.isComplete)
        }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testUnsupportedOlderServiceIs503NotEmptySuccess() async throws {
        try await assertServiceFailure(name: "UnsupportedCommand", status: 503)
    }

    func testUnavailableSnapshotProviderFailureIs503NotPlaceholderSuccess() async throws {
        try await assertServiceFailure(name: "ServiceUnavailable", status: 503)
    }

    func testStaleCursorIs409AndDoesNotLeakServiceDiagnostics() async throws {
        try await assertServiceFailure(name: "StaleCursor", status: 409)
    }

    func testMalformedServiceResponseIs502AndDoesNotLeakPayload() async throws {
        let fixture = try fixture { _ in Data("not-json a4-private-service-detail".utf8) }
        defer { fixture.stop() }
        try await assertReadFailure(fixture: fixture, status: 502)
    }

    func testConfiguredButAbsentSocketIs503WithoutHomeDiscoveryOrPlaceholderSuccess() async throws {
        try await withServer(config()) { server in
            let cookie = try await Self.login(server)
            let response = try await server.request("GET", self.messagesPath, headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(response.status, 503)
            Self.assertSafeFailure(response)
        }
    }

    func testUnexpectedInjectedReaderErrorIsSafe503() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        let calls = A4Recorder<String>()
        try await withServer(config(), factory: { _ in
            { request in calls.append(request.sessionId); throw A4Failure("a4-private-service-detail") }
        }) { server in
            let cookie = try await Self.login(server)
            let response = try await server.request("GET", self.messagesPath, headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(response.status, 503)
            Self.assertSafeFailure(response)
        }
        XCTAssertEqual(calls.values, ["session-a"])
        assertNoIPC(fixture)
    }

    func testEncodedResponseByteCeilingRejectsEscapingAmplification() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        try await withServer(config(), factory: { _ in
            { request in
                let fragment = try EngramServiceWebMessageFragment(messageOrdinal: 0, role: .assistant,
                    payloadSHA256: String(repeating: "b", count: 64), utf8Offset: 0,
                    payloadFragment: String(repeating: "\n", count: 140_000), isLastFragment: true)
                return try EngramServiceWebMessagesResponse(sessionId: request.sessionId, generation: request.generation,
                    roles: request.roles, fragments: [fragment], nextCursor: nil,
                    totalKnownComplete: true, truncatedAt: nil, parseFailure: nil)
            }
        }) { server in
            let cookie = try await Self.login(server)
            let response = try await server.request("GET", self.messagesPath, headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(response.status, 502)
            XCTAssertLessThanOrEqual(response.body.count, EngramServiceWebReadLimits.maximumPageEnvelopeBytes)
            Self.assertSafeFailure(response)
        }
        assertNoIPC(fixture)
    }

    func testLegacyV1ArchiveAndMCPRoutesRetainActualHTTPBehaviorWhenWebEnabled() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        try await withServer(config(archiveEnabled: true)) { server in
            let health = try await server.request("GET", "/v1/health", authority: "legacy.example")
            XCTAssertEqual(health.status, 200)
            XCTAssertEqual(String(decoding: health.body, as: UTF8.self), "ok\n")
            XCTAssertNil(health.header("content-security-policy"))
            let catalog = try await server.request("GET", "/v1/catalog", authority: "legacy.example",
                headers: [("Authorization", "Bearer a4-v1-token"), ("Origin", "https://legacy.example")])
            XCTAssertEqual(catalog.status, 200)
            XCTAssertNil(catalog.header("content-security-policy"))
            let catalogJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: catalog.body) as? [String: Any])
            XCTAssertEqual(catalogJSON["schemaVersion"] as? Int, 1)
            XCTAssertEqual((catalogJSON["manifests"] as? [Any])?.count, 0)
            A4AssertHTTPStatus(try await server.request("GET", "/v1/catalog"), 401)
            let archive = try await server.request("GET", "/v2/archive/machines", authority: "archive.example",
                headers: [("Authorization", "Bearer a4-archive-token"), ("Origin", "https://archive.example")])
            XCTAssertEqual(archive.status, 200)
            XCTAssertNil(archive.header("content-security-policy"))
            A4AssertHTTPStatus(try await server.request("GET", "/v2/archive/machines"), 401)
            let body = Data(#"{"jsonrpc":"2.0","id":"a4-initialize","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"a4-http-test","version":"1"}}}"#.utf8)
            let headers = [("Authorization", "Bearer a4-mcp-token"), ("Content-Type", "application/json")]
            let mcp = try await server.request("POST", "/mcp", authority: "mcp.example", headers: headers, body: body)
            XCTAssertEqual(mcp.status, 200)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: mcp.body) as? [String: Any])
            XCTAssertEqual(json["id"] as? String, "a4-initialize")
            XCTAssertNotNil(json["result"])
            XCTAssertNil(mcp.header("content-security-policy"))
            A4AssertHTTPStatus(try await server.request("POST", "/mcp", headers: headers + [("Origin", Self.origin)], body: body), 403)
            A4AssertHTTPStatus(try await server.request("POST", "/mcp", headers: [("Content-Type", "application/json")], body: body), 401)
        }
        assertNoIPC(fixture)
    }

    private static var invalidSocketPaths: [String] {
        ["relative.sock", "/", "//", "/./", "/tmp/..", "/tmp/\u{0}service.sock",
         "/" + String(repeating: "a", count: 103), "/" + String(repeating: "中", count: 35)]
    }

    private enum BearerTarget { case legacy, archive, mcp }

    private func assertAppCredentialRejected(target: BearerTarget, mutateAfterWebCreation: Bool) throws {
        var value = try config(archiveEnabled: true)
        if mutateAfterWebCreation {
            value.web = try Self.webConfiguration(credentials: [value.bearerToken, value.archiveV2!.bearerToken, value.mcp!.bearerToken])
        }
        switch target {
        case .legacy: value.bearerToken = Self.viewer
        case .archive:
            let archive = try XCTUnwrap(value.archiveV2)
            value.archiveV2 = EngramRemoteArchiveConfig(serverID: archive.serverID, root: archive.root,
                bearerToken: Self.viewer, atRestKey: archive.atRestKey)
        case .mcp: value.mcp = EngramRemoteMCPConfig(bearerToken: Self.viewer)
        }
        if !mutateAfterWebCreation {
            // The standalone WebConfig constructor cannot discover omitted server credentials.
            value.web = try Self.webConfiguration(credentials: [])
        }
        let calls = A4Recorder<String>()
        XCTAssertThrowsError(try EngramRemoteServerApp(config: value, webReadClientFactory: { path in
            calls.append(path)
            throw A4Failure("Reader must not be created for credential collision")
        })) {
            XCTAssertEqual($0 as? EngramRemoteWebConfig.ConfigError, .credentialMustBeDistinct)
        }
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: value.storeRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(value.archiveV2).root.path))
    }

    private func withServer(
        _ configuration: EngramRemoteServerConfig,
        factory: WebReadRoutes.ClientFactory? = nil,
        operation: (A4HTTPServer) async throws -> Void
    ) async throws {
        let app: EngramRemoteServerApp
        if let factory { app = try EngramRemoteServerApp(config: configuration, webReadClientFactory: factory) }
        else { app = try EngramRemoteServerApp(config: configuration) }
        let server = try await A4HTTPServer(app: app)
        do {
            try await operation(server)
        } catch {
            do { try await server.stop() } catch { XCTFail("Server cleanup failed: \(error)") }
            throw error
        }
        try await server.stop()
    }

    private func fixture(response: @escaping @Sendable (EngramServiceRequestEnvelope) throws -> Data = { request in
        try WebServerIntegrationTests.success(WebServerIntegrationTests.page(WebServerIntegrationTests.decode(request)), id: request.requestId)
    }) throws -> A4SocketFixture {
        try A4SocketFixture(path: socketPath, response: response)
    }

    private func assertNoIPC(_ fixture: A4SocketFixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.acceptCount, 0, "Unauthorized requests must not even open the service socket", file: file, line: line)
        XCTAssertTrue(fixture.requests.isEmpty, file: file, line: line)
    }

    private func assertRejectedQueries(_ queries: [String]) async throws {
        let fixture = try fixture()
        defer { fixture.stop() }
        try await withServer(config()) { server in
            let cookie = try await Self.login(server)
            for query in queries {
                let path = "/web/api/sessions/session-a/messages" + (query.isEmpty ? "" : "?" + query)
                let response = try await server.request("GET", path, headers: Self.originHeaders + [("Cookie", cookie)])
                XCTAssertEqual(response.status, 400, "Rejected query must not reach IPC: \(query.prefix(100))")
                Self.assertSecurityHeaders(response)
            }
        }
        assertNoIPC(fixture)
    }

    private func assertServiceFailure(name: String, status: Int) async throws {
        let fixture = try fixture { request in
            try JSONEncoder().encode(EngramServiceResponseEnvelope.failure(requestId: request.requestId,
                error: EngramServiceErrorEnvelope(name: name, message: "a4-private-service-detail /private/service.db",
                    retryPolicy: "never", details: ["secret": .string(Self.viewer)])))
        }
        defer { fixture.stop() }
        try await assertReadFailure(fixture: fixture, status: status)
    }

    private func assertReadFailure(fixture: A4SocketFixture, status: Int) async throws {
        try await withServer(config()) { server in
            let cookie = try await Self.login(server)
            let response = try await server.request("GET", self.messagesPath, headers: Self.originHeaders + [("Cookie", cookie)])
            XCTAssertEqual(response.status, status)
            Self.assertSafeFailure(response)
        }
        XCTAssertEqual(fixture.acceptCount, 1)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    private static var originHeaders: [(String, String)] { [("X-Engram-Web", "1"), ("Origin", origin)] }
    private static var metadataHeaders: [(String, String)] {
        [("X-Engram-Web", "1"), ("Sec-Fetch-Site", "same-origin"), ("Sec-Fetch-Mode", "cors"), ("Sec-Fetch-Dest", "empty")]
    }
    private static var loginHeaders: [(String, String)] { originHeaders + [("Content-Type", "application/json")] }
    private static var loginBody: Data { Data("{\"credential\":\"\(viewer)\"}".utf8) }

    private static func login(_ server: A4HTTPServer) async throws -> String {
        let response = try await server.request("POST", "/web/api/auth", headers: loginHeaders, body: loginBody)
        XCTAssertEqual(response.status, 204)
        assertSecurityHeaders(response)
        let cookie = try XCTUnwrap(response.header("set-cookie"))
        XCTAssertTrue(cookie.contains("HttpOnly"))
        XCTAssertTrue(cookie.contains("SameSite=Strict"))
        XCTAssertTrue(cookie.contains("Path=/"))
        XCTAssertFalse(cookie.contains(viewer))
        XCTAssertTrue(response.body.isEmpty)
        return try XCTUnwrap(cookie.split(separator: ";").first.map(String.init))
    }

    private static func assertSecurityHeaders(_ response: A4HTTPResponse, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response.header("cache-control"), "no-store", file: file, line: line)
        XCTAssertEqual(response.header("x-content-type-options"), "nosniff", file: file, line: line)
        let csp = response.header("content-security-policy") ?? ""
        for directive in ["default-src 'none'", "script-src 'self'", "style-src 'self'", "connect-src 'self'", "base-uri 'none'", "frame-ancestors 'none'"] {
            XCTAssertTrue(csp.contains(directive), directive, file: file, line: line)
        }
        for name in ["access-control-allow-origin", "access-control-allow-credentials", "access-control-allow-methods",
                     "access-control-allow-headers", "access-control-expose-headers", "access-control-max-age"] {
            XCTAssertNil(response.header(name), file: file, line: line)
        }
    }

    private static func assertSafeFailure(_ response: A4HTTPResponse) {
        assertSecurityHeaders(response)
        let text = String(decoding: response.body, as: UTF8.self)
        for secret in [viewer, "a4-private-service-detail", "/private/service.db", "a4-v1-token"] {
            XCTAssertFalse(text.contains(secret))
        }
        XCTAssertNotEqual(response.status, 200)
    }

    private static func queryEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
    }

    private static func decode(_ envelope: EngramServiceRequestEnvelope) throws -> EngramServiceWebMessagesRequest {
        try JSONDecoder().decode(EngramServiceWebMessagesRequest.self, from: XCTUnwrap(envelope.payload))
    }

    private static func success(_ page: EngramServiceWebMessagesResponse, id: String) throws -> Data {
        try JSONEncoder().encode(EngramServiceResponseEnvelope.success(requestId: id, result: JSONEncoder().encode(page)))
    }

    private static func page(_ request: EngramServiceWebMessagesRequest, split: Bool = false, partial: Bool = false) throws -> EngramServiceWebMessagesResponse {
        let role = try XCTUnwrap(request.roles.first)
        let payload = "{\"role\":\"\(role.rawValue)\",\"content\":\"你好 👩🏽‍💻 e\u{301} <script>unsafe()</script>\\nend\",\"toolCalls\":[{\"name\":\"工具\",\"input\":\"参数\",\"output\":\"结果\"}]}"
        let digest = Data(SHA256.hash(data: Data(payload.utf8))).map { String(format: "%02x", $0) }.joined()
        let cut = payload.index(after: try XCTUnwrap(payload.firstIndex(of: "你")))
        let parts = split ? [String(payload[..<cut]), String(payload[cut...])] : [payload]
        var offset = 0
        let fragments = try parts.enumerated().map { index, text in
            defer { offset += text.utf8.count }
            return try EngramServiceWebMessageFragment(messageOrdinal: 0, role: role, payloadSHA256: digest,
                utf8Offset: offset, payloadFragment: text, isLastFragment: index == parts.count - 1)
        }
        return try EngramServiceWebMessagesResponse(sessionId: request.sessionId, generation: request.generation,
            roles: request.roles, fragments: fragments, nextCursor: partial ? "next+/=opaque" : nil,
            totalKnownComplete: !partial, truncatedAt: partial ? 7 : nil, parseFailure: partial ? "truncatedJSONL" : nil)
    }
}

private struct A4Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func A4AssertHTTPStatus(_ response: A4HTTPResponse, _ expected: Int, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(response.status, expected, file: file, line: line)
}

private final class A4Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: Value) { lock.lock(); storage.append(value); lock.unlock() }
}

private final class A4ServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var boundPort: Int?
    private var completion: Result<Void, Error>?
    func bound(_ port: Int) { lock.lock(); boundPort = port; lock.unlock() }
    func finished(_ result: Result<Void, Error>) { lock.lock(); completion = result; lock.unlock() }
    private func snapshot() -> (Int?, Result<Void, Error>?) {
        lock.lock(); defer { lock.unlock() }; return (boundPort, completion)
    }
    func awaitPort() async throws -> Int {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let (port, completion) = snapshot()
            if let completion { try completion.get(); throw A4Failure("HTTP server stopped before binding") }
            if let port { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw A4Failure("HTTP server did not bind within five seconds")
    }
    func awaitCompletion() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if let completion = snapshot().1 {
                do { try completion.get() } catch is CancellationError { return }
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw A4Failure("HTTP server did not stop within three seconds")
    }
}

private final class A4HTTPServer: @unchecked Sendable {
    let port: Int
    private let state: A4ServerState
    private let task: Task<Void, Never>

    init(app: EngramRemoteServerApp) async throws {
        let state = A4ServerState()
        let task = Task {
            do { try await app.run(onBound: { state.bound($0) }); state.finished(.success(())) }
            catch { state.finished(.failure(error)) }
        }
        do { port = try await state.awaitPort() }
        catch {
            task.cancel()
            do { try await Task.detached { try await state.awaitCompletion() }.value }
            catch { XCTFail("Failed startup cleanup: \(error)") }
            throw error
        }
        self.state = state
        self.task = task
    }

    func stop() async throws {
        task.cancel()
        // Cleanup must still wait for termination if the calling test was cancelled.
        let state = state
        try await Task.detached { try await state.awaitCompletion() }.value
    }

    func request(
        _ method: String, _ path: String, authority: String = "127.0.0.1:8787",
        headers: [(String, String)] = [], body: Data = Data()
    ) async throws -> A4HTTPResponse {
        // Every call opens a separate TCP connection, while keeping App/session state shared.
        let port = port
        return try await Task.detached {
            try A4HTTPResponse.exchange(port: port, method: method, path: path, authority: authority, headers: headers, body: body)
        }.value
    }
}

private struct A4HTTPResponse: Sendable {
    let status: Int
    let headers: [String: [String]]
    let body: Data
    func header(_ name: String) -> String? { headers[name.lowercased()]?.first }

    static func exchange(port: Int, method: String, path: String, authority: String, headers: [(String, String)], body: Data) throws -> Self {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw A4Failure("Cannot create HTTP test socket") }
        defer { close(fd) }
        try EngramServiceSocketIO.disableSigPipe(fd)
        try EngramServiceSocketIO.setSocketTimeout(fd, seconds: 3)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { throw A4Failure("Invalid loopback") }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw A4Failure("HTTP connect failed: \(errno)") }
        var request = "\(method) \(path) HTTP/1.1\r\nHost: \(authority)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        for (name, value) in headers { request += "\(name): \(value)\r\n" }
        request += "\r\n"
        var bytes = Data(request.utf8)
        bytes.append(body)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard ContinuousClock.now < deadline else { throw A4Failure("HTTP exchange exceeded its total deadline") }
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw A4Failure("HTTP write failed") }
                offset += count
            }
        }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            guard ContinuousClock.now < deadline else { throw A4Failure("HTTP exchange exceeded its total deadline") }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw A4Failure("HTTP response read timed out or failed: \(errno)") }
            if count == 0 { break }
            received.append(contentsOf: buffer.prefix(count))
            guard received.count <= 1024 * 1024 else { throw A4Failure("HTTP fixture response exceeded one MiB") }
        }
        guard let boundary = received.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: received[..<boundary.lowerBound], encoding: .utf8) else { throw A4Failure("Malformed HTTP response headers") }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first, let status = Int(first.split(separator: " ").dropFirst().first ?? "") else {
            throw A4Failure("Missing HTTP response status")
        }
        var fields: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw A4Failure("Malformed HTTP response field") }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[name, default: []].append(value)
        }
        let rawBody = Data(received[boundary.upperBound...])
        let decoded: Data
        if method == "HEAD" { decoded = rawBody }
        else if fields["transfer-encoding"]?.first?.lowercased() == "chunked" { decoded = try decodeChunks(rawBody) }
        else {
            if let length = fields["content-length"]?.first.flatMap(Int.init), length != rawBody.count {
                throw A4Failure("Truncated HTTP response body")
            }
            decoded = rawBody
        }
        return Self(status: status, headers: fields, body: decoded)
    }

    private static func decodeChunks(_ data: Data) throws -> Data {
        var index = data.startIndex
        var result = Data()
        let terminator = Data("\r\n".utf8)
        while index < data.endIndex {
            guard let line = data.range(of: terminator, in: index..<data.endIndex),
                  let text = String(data: data[index..<line.lowerBound], encoding: .utf8),
                  let size = Int(text.split(separator: ";").first ?? "", radix: 16), size >= 0 else {
                throw A4Failure("Malformed HTTP chunk length")
            }
            index = line.upperBound
            if size == 0 { return result }
            guard size <= data.endIndex - index - 2 else { throw A4Failure("Truncated HTTP chunk") }
            let end = index + size
            guard data[end..<(end + 2)] == terminator else { throw A4Failure("Malformed HTTP chunk terminator") }
            result.append(data[index..<end])
            index = end + 2
        }
        throw A4Failure("Missing terminal HTTP chunk")
    }
}

private final class A4SocketFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private let path: String
    private var listener: Int32
    private var peer: Int32?
    private var stopped = false
    private var accepts = 0
    private var frames: [EngramServiceRequestEnvelope] = []
    private var failures: [String] = []
    var acceptCount: Int { lock.lock(); defer { lock.unlock() }; return accepts }
    var requests: [EngramServiceRequestEnvelope] { lock.lock(); defer { lock.unlock() }; return frames }

    init(path: String, response: @escaping @Sendable (EngramServiceRequestEnvelope) throws -> Data) throws {
        self.path = path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw A4Failure("Cannot create service fixture socket") }
        do {
            try EngramServiceSocketIO.withSockAddr(path: path) {
                guard Darwin.bind(listener, $0, $1) == 0 else { throw A4Failure("Cannot bind service fixture") }
            }
            guard chmod(path, 0o600) == 0, listen(listener, 8) == 0,
                  fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else { throw A4Failure("Cannot prepare private service fixture") }
        } catch { close(listener); throw error }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer {
                lock.lock()
                if let peer { close(peer); self.peer = nil }
                close(listener)
                listener = -1
                lock.unlock()
                group.leave()
            }
            while true {
                lock.lock(); let shouldStop = stopped; lock.unlock()
                if shouldStop { return }
                var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 50)
                if ready < 0 && errno == EINTR { continue }
                if ready <= 0 { continue }
                let fd = accept(listener, nil, nil)
                if fd < 0 { continue }
                lock.lock()
                accepts += 1
                peer = fd
                let stopping = stopped
                lock.unlock()
                if stopping { return }
                do {
                    let flags = fcntl(fd, F_GETFL)
                    guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw A4Failure("Cannot configure accepted service socket") }
                    try EngramServiceSocketIO.disableSigPipe(fd)
                    try EngramServiceSocketIO.setSocketTimeout(fd, seconds: 1)
                    let bytes = try EngramServiceSocketIO.readFrame(from: fd, requestTimeout: 1)
                    let request = try JSONDecoder().decode(EngramServiceRequestEnvelope.self, from: bytes)
                    lock.lock(); frames.append(request); lock.unlock()
                    try EngramServiceSocketIO.writeFrame(response(request), to: fd, requestTimeout: 1)
                } catch {
                    lock.lock(); failures.append(String(describing: error)); lock.unlock()
                }
                lock.lock(); close(fd); peer = nil; lock.unlock()
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        if let peer { _ = shutdown(peer, SHUT_RDWR) }
        if listener >= 0 { _ = shutdown(listener, SHUT_RDWR) }
        lock.unlock()
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success, "Service fixture must stop within two seconds")
        lock.lock(); let errors = failures; lock.unlock()
        XCTAssertTrue(errors.isEmpty, "Service fixture failed: \(errors)")
        do { try FileManager.default.removeItem(atPath: path) }
        catch { XCTFail("Cannot remove task-owned service fixture: \(error)") }
    }
}
