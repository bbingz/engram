import CryptoKit
import Foundation
@testable import EngramRemoteServerCore
import XCTest

final class WebConfigTests: XCTestCase {
    private let viewer = "test-only-viewer-credential"
    private let bearers = ["test-v1-bearer", "test-archive-bearer", "test-mcp-bearer"]

    private var enabled: [String: String] {
        [
            "ENGRAM_REMOTE_WEB_ENABLED": "1",
            "ENGRAM_REMOTE_WEB_ORIGIN": "https://viewer.example",
            "ENGRAM_REMOTE_WEB_VIEWER_CREDENTIAL": viewer,
        ]
    }

    func testDisabledByDefaultAndExplicitZeroIgnoresUnusedSettings() throws {
        XCTAssertNil(try EngramRemoteWebConfig.fromEnvironment([:], serverBearerCredentials: bearers))
        var environment = enabled
        environment["ENGRAM_REMOTE_WEB_ENABLED"] = "0"
        environment["ENGRAM_REMOTE_WEB_ORIGIN"] = "not-an-origin"
        XCTAssertNil(try EngramRemoteWebConfig.fromEnvironment(environment, serverBearerCredentials: bearers))
    }

    func testEnabledFlagAcceptsOnlyLiteralZeroOrOne() {
        for value in ["", "true", "false", "2", "01", " 1", "1\n", "yes"] {
            var environment = enabled
            environment["ENGRAM_REMOTE_WEB_ENABLED"] = value
            XCTAssertThrowsError(try EngramRemoteWebConfig.fromEnvironment(environment, serverBearerCredentials: bearers)) {
                XCTAssertEqual($0 as? EngramRemoteWebConfig.ConfigError, .invalidEnabled)
            }
        }
    }

    func testEnabledConfigurationKeepsExplicitOriginAndOnlyCredentialDigest() throws {
        let config = try XCTUnwrap(EngramRemoteWebConfig.fromEnvironment(enabled, serverBearerCredentials: bearers))
        XCTAssertEqual(config.origin, "https://viewer.example")
        XCTAssertEqual(config.authority, "viewer.example")
        XCTAssertTrue(config.isSecure)
        XCTAssertEqual(config.cookieName, "__Host-engram_web")
        XCTAssertEqual(config.credentialDigest, Data(SHA256.hash(data: Data(viewer.utf8))))
        XCTAssertFalse(String(reflecting: config).contains(viewer))
    }

    func testMissingOriginAndCredentialFailClosed() {
        for key in ["ENGRAM_REMOTE_WEB_ORIGIN", "ENGRAM_REMOTE_WEB_VIEWER_CREDENTIAL"] {
            for missing in [true, false] {
                var environment = enabled
                environment[key] = missing ? nil : ""
                XCTAssertThrowsError(try EngramRemoteWebConfig.fromEnvironment(environment, serverBearerCredentials: bearers))
            }
        }
        XCTAssertThrowsError(try EngramRemoteWebConfig(origin: "https://viewer.example", viewerCredential: " \n", serverBearerCredentials: bearers))
    }

    func testProductionAcceptsCanonicalHTTPSWithExactOptionalPort() throws {
        for (origin, authority) in [
            ("https://viewer.example", "viewer.example"),
            ("https://viewer.example:9443", "viewer.example:9443"),
            ("https://[::1]:9443", "[::1]:9443"),
        ] {
            let config = try EngramRemoteWebConfig(origin: origin, viewerCredential: viewer, serverBearerCredentials: bearers)
            XCTAssertEqual(config.origin, origin)
            XCTAssertEqual(config.authority, authority)
        }
    }

    func testProductionRejectsNonOriginAndNonCanonicalURLForms() {
        let rejected = [
            "http://viewer.example", "http://127.0.0.1:8787", "https://", "viewer.example", "//viewer.example",
            "https://viewer.example/", "https://viewer.example/path", "https://viewer.example?x=1",
            "https://viewer.example#fragment", "https://user:pass@viewer.example", "https://user@viewer.example",
            "https://*.example", "https://viewer.example.evil/", "https://viewer.example:0", "https://viewer.example:65536",
            "https://viewer.example:", "https://viewer.example:443", "https://viewer.example:09443", "HTTPS://viewer.example", "https://VIEWER.example",
            "https://viewer.example.", "https://%76iewer.example", " https://viewer.example", "https://viewer.example\n",
            "https://viewer.example,https://evil.example", "https://viewer.example\\evil", "null",
        ]
        for origin in rejected {
            XCTAssertThrowsError(try EngramRemoteWebConfig(origin: origin, viewerCredential: viewer, serverBearerCredentials: bearers), origin)
        }
    }

    func testViewerCredentialMustDifferFromEveryProvidedBearer() {
        for bearer in bearers {
            XCTAssertThrowsError(try EngramRemoteWebConfig(origin: "https://viewer.example", viewerCredential: bearer, serverBearerCredentials: bearers)) {
                XCTAssertEqual($0 as? EngramRemoteWebConfig.ConfigError, .credentialMustBeDistinct)
            }
        }
    }

    func testLoopbackHTTPIsAnInternalTestFactoryNotAnEnvironmentSwitch() throws {
        for origin in ["http://127.0.0.1:8787", "http://[::1]:8787"] {
            let config = try EngramRemoteWebConfig.forLoopbackHTTPTesting(origin: origin, viewerCredential: viewer, serverBearerCredentials: bearers)
            XCTAssertEqual(config.origin, origin)
            XCTAssertFalse(config.isSecure)
            XCTAssertEqual(config.cookieName, "engram_web_test")
        }
        for origin in ["http://localhost:8787", "http://viewer.example", "http://0.0.0.0:8787", "http://127.0.0.1.evil:8787", "http://127.0.0.1:8787/path"] {
            XCTAssertThrowsError(try EngramRemoteWebConfig.forLoopbackHTTPTesting(origin: origin, viewerCredential: viewer, serverBearerCredentials: bearers))
        }
        var environment = enabled
        environment["ENGRAM_REMOTE_WEB_ORIGIN"] = "http://127.0.0.1:8787"
        environment["ENGRAM_REMOTE_WEB_ALLOW_HTTP"] = "1"
        environment["ENGRAM_REMOTE_WEB_TEST_MODE"] = "1"
        XCTAssertThrowsError(try EngramRemoteWebConfig.fromEnvironment(environment, serverBearerCredentials: bearers))
    }

    func testConfigurationErrorsNeverIncludeSubmittedCredentialsOrOrigin() {
        for error in [EngramRemoteWebConfig.ConfigError.invalidEnabled, .missingOrigin, .invalidOrigin, .missingCredential, .credentialMustBeDistinct] {
            XCTAssertFalse(error.description.contains(viewer))
            for bearer in bearers { XCTAssertFalse(error.description.contains(bearer)) }
            XCTAssertFalse(error.description.contains("viewer.example"))
        }
    }
}
