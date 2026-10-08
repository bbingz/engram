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

    func testOptionalEditorCredentialIsDistinctAndStoredOnlyAsDigest() throws {
        let viewerOnly = try XCTUnwrap(EngramRemoteWebConfig.fromEnvironment(enabled, serverBearerCredentials: bearers))
        XCTAssertNil(viewerOnly.editorCredentialDigest)
        var environment = enabled
        environment["ENGRAM_REMOTE_WEB_EDITOR_CREDENTIAL"] = "fixture-editor-secret"
        let config = try XCTUnwrap(EngramRemoteWebConfig.fromEnvironment(environment, serverBearerCredentials: bearers))
        XCTAssertEqual(config.editorCredentialDigest, Data(SHA256.hash(data: Data("fixture-editor-secret".utf8))))
        XCTAssertFalse(String(reflecting: config).contains("fixture-editor-secret"))
        for invalid in ["", " \n", viewer] + bearers {
            environment["ENGRAM_REMOTE_WEB_EDITOR_CREDENTIAL"] = invalid
            XCTAssertThrowsError(try EngramRemoteWebConfig.fromEnvironment(environment, serverBearerCredentials: bearers))
        }
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

    private var identityEnabled: [String: String] {
        [
            "ENGRAM_REMOTE_WEB_ENABLED": "1",
            "ENGRAM_REMOTE_WEB_ORIGIN": "https://viewer.example",
            "ENGRAM_REMOTE_WEB_AUTH": "tailscale-serve",
            "ENGRAM_REMOTE_WEB_VIEWERS": "reader@example.com,second@example.com",
            "ENGRAM_REMOTE_WEB_EDITORS": "editor@example.com",
        ]
    }

    func testAuthModeDefaultsToCredentialAndRejectsUnknownValues() throws {
        let implicit = try XCTUnwrap(EngramRemoteWebConfig.fromEnvironment(enabled, serverBearerCredentials: bearers))
        var explicit = enabled
        explicit["ENGRAM_REMOTE_WEB_AUTH"] = "credential"
        let named = try XCTUnwrap(EngramRemoteWebConfig.fromEnvironment(explicit, serverBearerCredentials: bearers))
        XCTAssertEqual(implicit.mode, named.mode)
        XCTAssertFalse(implicit.usesTailscaleServeIdentity)
        for value in ["", "Tailscale-Serve", "tailscale", "credential ", "both"] {
            var environment = enabled
            environment["ENGRAM_REMOTE_WEB_AUTH"] = value
            XCTAssertThrowsError(try EngramRemoteWebConfig.fromEnvironment(environment, serverBearerCredentials: bearers), value) {
                XCTAssertEqual($0 as? EngramRemoteWebConfig.ConfigError, .invalidAuthMode)
            }
        }
    }

    func testTailscaleServeModeParsesExactAllowlistsAndKeepsNoCredentialDigest() throws {
        let config = try XCTUnwrap(EngramRemoteWebConfig.fromEnvironment(identityEnabled, serverBearerCredentials: bearers))
        XCTAssertTrue(config.usesTailscaleServeIdentity)
        XCTAssertEqual(config.mode, .tailscaleServe(viewers: ["reader@example.com", "second@example.com"], editors: ["editor@example.com"]))
        XCTAssertNil(config.credentialDigest)
        XCTAssertNil(config.editorCredentialDigest)
        XCTAssertEqual(config.cookieName, "__Host-engram_web")
        XCTAssertTrue(config.isSecure)
        var viewersOnly = identityEnabled
        viewersOnly["ENGRAM_REMOTE_WEB_EDITORS"] = nil
        let noEditors = try XCTUnwrap(EngramRemoteWebConfig.fromEnvironment(viewersOnly, serverBearerCredentials: bearers))
        XCTAssertEqual(noEditors.mode, .tailscaleServe(viewers: ["reader@example.com", "second@example.com"], editors: []))
    }

    func testTailscaleServeModeForbidsSharedCredentialsAndRequiresViewers() throws {
        for key in ["ENGRAM_REMOTE_WEB_VIEWER_CREDENTIAL", "ENGRAM_REMOTE_WEB_EDITOR_CREDENTIAL"] {
            for value in ["", "fixture-secret"] {
                var environment = identityEnabled
                environment[key] = value
                XCTAssertThrowsError(try EngramRemoteWebConfig.fromEnvironment(environment, serverBearerCredentials: bearers)) {
                    XCTAssertEqual($0 as? EngramRemoteWebConfig.ConfigError, .credentialNotAllowedWithIdentity)
                }
            }
        }
        for missing in [true, false] {
            var environment = identityEnabled
            environment["ENGRAM_REMOTE_WEB_VIEWERS"] = missing ? nil : ""
            XCTAssertThrowsError(try EngramRemoteWebConfig.fromEnvironment(environment, serverBearerCredentials: bearers)) {
                XCTAssertEqual($0 as? EngramRemoteWebConfig.ConfigError, .missingIdentityViewers)
            }
        }
        var plainHTTP = identityEnabled
        plainHTTP["ENGRAM_REMOTE_WEB_ORIGIN"] = "http://127.0.0.1:8787"
        XCTAssertThrowsError(try EngramRemoteWebConfig.fromEnvironment(plainHTTP, serverBearerCredentials: bearers)) {
            XCTAssertEqual($0 as? EngramRemoteWebConfig.ConfigError, .invalidOrigin)
        }
    }

    func testIdentityAllowlistEntriesMustBeExactPrintableLoginsWithoutDuplicates() throws {
        for list in [",", "a@example.com,", ",a@example.com", "a@example.com,,b@example.com", " a@example.com", "a@example.com ",
                     "a b@example.com", "a@example.com\n", "a@example.com,a@example.com", "\"a\"@example.com", "a\\b@example.com",
                     "é@example.com", String(repeating: "a", count: 255)] {
            for key in ["ENGRAM_REMOTE_WEB_VIEWERS", "ENGRAM_REMOTE_WEB_EDITORS"] {
                var environment = identityEnabled
                environment[key] = list
                XCTAssertThrowsError(try EngramRemoteWebConfig.fromEnvironment(environment, serverBearerCredentials: bearers), "\(key)=\(list)") {
                    XCTAssertEqual($0 as? EngramRemoteWebConfig.ConfigError, .invalidIdentityLogin)
                }
            }
        }
        var environment = identityEnabled
        environment["ENGRAM_REMOTE_WEB_VIEWERS"] = String(repeating: "a", count: 254)
        XCTAssertNotNil(try EngramRemoteWebConfig.fromEnvironment(environment, serverBearerCredentials: bearers))
        XCTAssertTrue(EngramRemoteWebConfig.isWellFormedLogin("zzbhlx@gmail.com"))
        XCTAssertFalse(EngramRemoteWebConfig.isWellFormedLogin(""))
    }

    func testConfigurationErrorsNeverIncludeSubmittedCredentialsOrOrigin() {
        for error in [EngramRemoteWebConfig.ConfigError.invalidEnabled, .missingOrigin, .invalidOrigin, .missingCredential, .credentialMustBeDistinct,
                      .invalidAuthMode, .credentialNotAllowedWithIdentity, .missingIdentityViewers, .invalidIdentityLogin, .identityRequiresLoopbackBind] {
            XCTAssertFalse(error.description.contains(viewer))
            for bearer in bearers { XCTAssertFalse(error.description.contains(bearer)) }
            XCTAssertFalse(error.description.contains("viewer.example"))
        }
    }
}
