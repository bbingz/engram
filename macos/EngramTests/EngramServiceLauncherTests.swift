import Darwin
import XCTest
@testable import Engram
@testable import class EngramServiceCore.UnixSocketServiceServer

final class EngramServiceLauncherTests: XCTestCase {
    func testAppOpensDatabaseOffMainActor_repro() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(
            contentsOf: repoRoot.appendingPathComponent("macos/Engram/App.swift"),
            encoding: .utf8
        )
        let openCall = try XCTUnwrap(app.range(of: "try db.open()"))
        let prefix = app[..<openCall.lowerBound]
        let localContext = prefix.suffix(400)

        XCTAssertTrue(
            localContext.contains("Task.detached"),
            "database pool creation must not wait for SQLite's busy timeout on the main actor"
        )
    }

    func testAppAdoptsServingSocketAndMonitorsWriterBusyStartup_repro() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(
            contentsOf: repoRoot.appendingPathComponent("macos/Engram/App.swift"),
            encoding: .utf8
        )
        let launcher = try String(
            contentsOf: repoRoot.appendingPathComponent("macos/Engram/Core/EngramServiceLauncher.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(app.contains("startOrAdopt"))
        XCTAssertTrue(launcher.contains("if let status = try? await statusProbe()"))
        XCTAssertTrue(launcher.contains("engramServiceWriterBusyMessage(error) != nil"))
        XCTAssertTrue(launcher.contains("startHealthMonitor("))
    }

    @MainActor
    func testAdoptedServiceIsTrackedAsRunning_repro() async {
        let launcher = EngramServiceLauncher(
            healthIntervalNanoseconds: 60_000_000_000,
            maximumRestartAttempts: 0,
            startupGraceNanoseconds: 0
        )
        let config = EngramServiceLaunchConfiguration(
            executablePath: "/tmp/unused-adopted-helper",
            socketPath: "/tmp/engram-adopted.sock",
            databasePath: "/tmp/engram-adopted.sqlite",
            foreground: false
        )

        await launcher.startOrAdopt(
            configuration: config,
            statusProbe: { .running(total: 1, todayParents: 0) },
            onStatus: { _ in }
        )

        XCTAssertTrue(launcher.isRunning, "a serving socket adopted at app launch must remain observable")
        launcher.stopIfOwned()
    }

    func testServiceShutdownRemainsAuthenticatedAndLauncherRetainsEvents_repro() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let launcher = try String(
            contentsOf: repoRoot.appendingPathComponent("macos/Engram/Core/EngramServiceLauncher.swift"),
            encoding: .utf8
        )
        let capability = try String(
            contentsOf: repoRoot.appendingPathComponent("macos/Shared/Service/ServiceCapabilityToken.swift"),
            encoding: .utf8
        )
        let handler = try String(
            contentsOf: repoRoot.appendingPathComponent("macos/EngramService/Core/EngramServiceCommandHandler.swift"),
            encoding: .utf8
        )
        let server = try String(
            contentsOf: repoRoot.appendingPathComponent("macos/EngramService/IPC/UnixSocketServiceServer.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(capability.contains(#""shutdown""#))
        XCTAssertTrue(handler.contains(#"case "shutdown":"#))
        XCTAssertTrue(server.contains("onShutdown"))
        XCTAssertTrue(launcher.contains("adoptedConfiguration"))
        XCTAssertTrue(launcher.contains("onEvent: onEvent"))
    }

    func testProductionEnvironmentStartsServiceHelperWithoutNodeDaemonArguments() {
        let environment = AppEnvironment.production

        XCTAssertFalse(environment.autoStartDaemon)
        XCTAssertTrue(environment.autoStartService)
        XCTAssertEqual(
            environment.serviceSocketPath,
            UnixSocketEngramServiceTransport.defaultSocketPath()
        )

        let configuration = environment.serviceLaunchConfiguration(bundle: .main)
        let arguments = EngramServiceLauncher.arguments(for: configuration)

        XCTAssertTrue(configuration.executablePath.hasSuffix("EngramService"))
        XCTAssertEqual(configuration.socketPath, environment.serviceSocketPath)
        XCTAssertEqual(configuration.databasePath, environment.dbPath)
        XCTAssertFalse(configuration.foreground)
        XCTAssertFalse(arguments.contains { argument in
            argument.contains("node")
                || argument.contains("daemon.js")
                || argument.contains("EngramMCP")
                || argument.contains("MCPServer")
        })
    }

    func testDataDirEnvironmentKeepsIsolatedServiceStartupWithoutNodeDaemon() {
        let environment = AppEnvironment.fromCommandLine(
            arguments: ["Engram", "--data-dir", "/tmp/engram-data"],
            environment: [:]
        )

        XCTAssertEqual(environment.dbPath, "/tmp/engram-data/index.sqlite")
        XCTAssertFalse(environment.autoStartDaemon)
        XCTAssertTrue(environment.autoStartService)
        XCTAssertEqual(environment.serviceSocketPath, "/tmp/engram-data/run/engram-service.sock")
    }

    func testDataDirUsesNormalizedIsolatedServiceSocket_repro() {
        let home = URL(fileURLWithPath: "/tmp/engram-data-home", isDirectory: true)
        let absolute = AppEnvironment.fromCommandLine(
            arguments: ["Engram", "--data-dir", "/tmp/engram-data/../isolated"],
            environment: ["HOME": home.path]
        )
        XCTAssertEqual(absolute.dbPath, "/tmp/isolated/index.sqlite")
        XCTAssertEqual(absolute.serviceSocketPath, "/tmp/isolated/run/engram-service.sock")
        XCTAssertTrue(absolute.autoStartService)

        let expanded = AppEnvironment.fromCommandLine(
            arguments: ["Engram", "--data-dir", "~/.engram-preview"],
            environment: ["HOME": home.path]
        )
        XCTAssertEqual(expanded.dbPath, home.appendingPathComponent(".engram-preview/index.sqlite").path)
        XCTAssertEqual(
            expanded.serviceSocketPath,
            home.appendingPathComponent(".engram-preview/run/engram-service.sock").path
        )

        let relative = AppEnvironment.fromCommandLine(
            arguments: ["Engram", "--data-dir", "relative-data"],
            environment: ["HOME": home.path]
        )
        XCTAssertFalse(relative.autoStartService, "relative data directories must fail closed")
    }

    func testMissingDataDirValueFailsClosed_repro() {
        let environment = AppEnvironment.fromCommandLine(
            arguments: ["Engram", "--data-dir"],
            environment: [:]
        )

        XCTAssertEqual(environment.dbPath, "")
        XCTAssertEqual(environment.serviceSocketPath, "")
        XCTAssertFalse(environment.autoStartDaemon)
        XCTAssertFalse(environment.autoStartService)
        XCTAssertFalse(environment.networkEnabled)
    }

    @MainActor
    func testStartCreatesPrivateDataDirRuntimeDirectory_repro() throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-data-dir-start-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        let launcher = EngramServiceLauncher()
        let configuration = EngramServiceLaunchConfiguration(
            executablePath: "/usr/bin/true",
            socketPath: dataDirectory.appendingPathComponent("run/engram-service.sock").path,
            databasePath: dataDirectory.appendingPathComponent("index.sqlite").path,
            foreground: false
        )

        try launcher.start(configuration: configuration)
        launcher.stopIfOwned()

        var info = stat()
        let runtimeDirectory = dataDirectory.appendingPathComponent("run").path
        XCTAssertEqual(lstat(runtimeDirectory, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
    }

    func testTestEnvironmentDoesNotStartAnyOwnedRuntimeProcess() {
        let environment = AppEnvironment.test(fixturePath: "/tmp/test.sqlite")

        XCTAssertFalse(environment.autoStartDaemon)
        XCTAssertFalse(environment.autoStartService)
    }

    func testUITestEnvironmentParsesMockAndForcedOnboarding_repro() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-ui-env-\(UUID().uuidString)", isDirectory: true)
        let environment = AppEnvironment.fromCommandLine(
            arguments: [
                "Engram", "--test-mode", "--fixture-db", root.appendingPathComponent("index.sqlite").path,
                "--mock-daemon", "--show-onboarding",
            ],
            environment: [:]
        )

        XCTAssertTrue(environment.mockDaemon)
        XCTAssertTrue(environment.showOnboarding)
        XCTAssertFalse(environment.autoStartService)
    }

    func testSettingsIOUsesHermeticResolutionOrderInXCTest_repro() {
        let explicit = URL(fileURLWithPath: "/tmp/engram-explicit-settings.json")
        XCTAssertEqual(
            resolveEngramSettingsURL(environment: ["ENGRAM_SETTINGS_PATH": explicit.path]),
            explicit
        )

        let fixedHome = "/tmp/engram-fixed-home-\(UUID().uuidString)"
        XCTAssertEqual(
            resolveEngramSettingsURL(environment: ["CFFIXED_USER_HOME": fixedHome]),
            URL(fileURLWithPath: fixedHome).appendingPathComponent(".engram/settings.json")
        )

        let resolved = resolveEngramSettingsURL(environment: [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "XCTestConfigurationFilePath": "/tmp/EngramTests.xctestconfiguration",
        ])
        XCTAssertTrue(resolved.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertFalse(
            resolved.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/.engram/")
        )
    }

    func testAppPreferenceAndSettingsViewsUseInjectedState_repro() throws {
        let app = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Engram/App.swift"),
            encoding: .utf8
        )
        let menu = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Engram/MenuBarController.swift"),
            encoding: .utf8
        )
        let about = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Engram/Views/Settings/AboutSettingsSection.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(app.contains("UserDefaults.standard"))
        XCTAssertFalse(menu.contains("UserDefaults.standard"))
        XCTAssertTrue(menu.contains("guard !isTestMode else { return }"))
        XCTAssertTrue(about.contains("db.path"))
        XCTAssertFalse(about.contains(".appendingPathComponent(\".engram/index.sqlite\")"))
    }

    @MainActor
    func testUITestAppStorageUsesIsolatedDefaultsSuite_repro() throws {
        let hostSuite = "com.engram.tests.host.\(UUID().uuidString)"
        let isolatedSuite = "com.engram.tests.ui.\(UUID().uuidString)"
        let hostDefaults = try XCTUnwrap(UserDefaults(suiteName: hostSuite))
        defer {
            hostDefaults.removePersistentDomain(forName: hostSuite)
            UserDefaults(suiteName: isolatedSuite)?.removePersistentDomain(forName: isolatedSuite)
        }
        hostDefaults.set("host", forKey: "sessions.sourceFilter")

        let uiDefaults = AppDelegate.makeAppStorage(
            isTestMode: true,
            environment: ["ENGRAM_UI_TEST_DEFAULTS_SUITE": isolatedSuite],
            standard: hostDefaults
        )
        uiDefaults.set("Codex", forKey: "sessions.sourceFilter")

        XCTAssertEqual(uiDefaults.string(forKey: "sessions.sourceFilter"), "Codex")
        XCTAssertEqual(hostDefaults.string(forKey: "sessions.sourceFilter"), "host")
    }

    @MainActor
    func testMockDaemonEnvironmentBuildsMockServiceClient_repro() {
        let environment = AppEnvironment.fromCommandLine(
            arguments: ["Engram", "--test-mode", "--fixture-db", "/tmp/unused", "--mock-daemon"],
            environment: [:]
        )

        XCTAssertTrue(AppDelegate.makeServiceClient(for: environment) is MockEngramServiceClient)
    }

    @MainActor
    func testMockDaemonLivePollIsDeterministicallyUnavailable_repro() async {
        let environment = AppEnvironment.fromCommandLine(
            arguments: ["Engram", "--test-mode", "--fixture-db", "/tmp/unused", "--mock-daemon"],
            environment: [:]
        )
        let client = AppDelegate.makeServiceClient(for: environment)

        do {
            _ = try await client.liveSessions()
            XCTFail("the UI-test mock must complete the unavailable-state poll deterministically")
        } catch {
            XCTAssertEqual(
                error as? EngramServiceError,
                .serviceUnavailable(message: "UI test mock live sessions unavailable")
            )
        }
    }

    @MainActor
    func testMockDaemonMemoryReadsFailInsteadOfMasqueradingAsEmpty_repro() async {
        let environment = AppEnvironment.fromCommandLine(
            arguments: ["Engram", "--test-mode", "--fixture-db", "/tmp/unused", "--mock-daemon"],
            environment: [:]
        )
        let client = AppDelegate.makeServiceClient(for: environment)

        do {
            _ = try await client.memoryFiles()
            XCTFail("the UI-test mock must not present a service failure as empty memory files")
        } catch {
            XCTAssertEqual(
                error as? EngramServiceError,
                .serviceUnavailable(message: "UI test mock memory files unavailable")
            )
        }

        do {
            _ = try await client.insights()
            XCTFail("the UI-test mock must not present a service failure as empty insights")
        } catch {
            XCTAssertEqual(
                error as? EngramServiceError,
                .serviceUnavailable(message: "UI test mock insights unavailable")
            )
        }
    }

    func testBuildArgumentsContainServiceSocketAndDatabasePathOnly() {
        let config = EngramServiceLaunchConfiguration(
            executablePath: "/tmp/EngramService",
            socketPath: "/tmp/engram.sock",
            databasePath: "/tmp/index.sqlite",
            foreground: true
        )

        let arguments = EngramServiceLauncher.arguments(for: config)

        XCTAssertEqual(arguments, [
            "--service-socket", "/tmp/engram.sock",
            "--database-path", "/tmp/index.sqlite",
            "--foreground"
        ])
        XCTAssertFalse(arguments.contains { $0.contains("node") || $0.contains("daemon.js") })
    }

    func testLaunchEnvironmentBridgesKeychainSecretsThroughRuntimeFileOnly_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-service-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chmod(root.path, 0o700)
        defer { try? FileManager.default.removeItem(at: root) }
        let secretsPath = root.appendingPathComponent("ai-secrets.json").path

        let environment = EngramServiceLauncher.environment(
            baseEnvironment: [
                "PATH": "/usr/bin",
                "ENGRAM_KEYCHAIN_aiApiKey": "inherited-summary-secret",
                "ENGRAM_KEYCHAIN_titleApiKey": "inherited-title-secret",
                "ENGRAM_KEYCHAIN_embeddingApiKey": "inherited-embedding-secret"
            ],
            runtimeAISecretsPath: secretsPath,
            keychainReader: { account in
                switch account {
                case "aiApiKey": return "summary-secret"
                case "titleApiKey": return "title-secret"
                case "embeddingApiKey": return "embedding-secret"
                default: return nil
                }
            }
        )

        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertNil(environment["ENGRAM_KEYCHAIN_aiApiKey"])
        XCTAssertNil(environment["ENGRAM_KEYCHAIN_titleApiKey"])
        XCTAssertNil(environment["ENGRAM_KEYCHAIN_embeddingApiKey"])
        XCTAssertFalse(environment.values.contains("inherited-summary-secret"))
        XCTAssertFalse(environment.values.contains("inherited-title-secret"))
        XCTAssertFalse(environment.values.contains("summary-secret"))
        XCTAssertFalse(environment.values.contains("title-secret"))
        XCTAssertFalse(environment.values.contains("embedding-secret"))
        XCTAssertEqual(environment["ENGRAM_RUNTIME_AI_SECRETS_PATH"], secretsPath)

        let data = try Data(contentsOf: URL(fileURLWithPath: secretsPath))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object["aiApiKey"], "summary-secret")
        XCTAssertEqual(object["titleApiKey"], "title-secret")
        XCTAssertEqual(object["embeddingApiKey"], "embedding-secret")
        let attrs = try FileManager.default.attributesOfItem(atPath: secretsPath)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
    }

    func testLaunchEnvironmentOmitsRuntimeSecretsPathWhenWriteFails_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-service-secrets-failure-\(UUID().uuidString)", isDirectory: true)
        try Data("not-a-directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let secretsPath = root.appendingPathComponent("ai-secrets.json").path

        let environment = EngramServiceLauncher.environment(
            baseEnvironment: ["ENGRAM_RUNTIME_AI_SECRETS_PATH": "/tmp/inherited-secret-path"],
            runtimeAISecretsPath: secretsPath,
            keychainReader: { _ in "secret" }
        )

        XCTAssertNil(environment["ENGRAM_RUNTIME_AI_SECRETS_PATH"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: secretsPath))
    }

    func testRuntimeSecretsWriteDoesNotScanOrRemoveSocketSiblings_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-secret-siblings-\(UUID().uuidString)", isDirectory: true)
        let run = root.appendingPathComponent("caller/.engram/run", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        chmod(run.path, 0o700)
        defer { try? FileManager.default.removeItem(at: root) }

        let referent = root.appendingPathComponent("caller-owned")
        try Data("keep".utf8).write(to: referent)
        let unknown = run.appendingPathComponent("unknown-link")
        let serviceLock = run.appendingPathComponent("engram-service.lock")
        try FileManager.default.createSymbolicLink(at: unknown, withDestinationURL: referent)
        try FileManager.default.createSymbolicLink(at: serviceLock, withDestinationURL: referent)

        XCTAssertTrue(
            EngramServiceLauncher.writeRuntimeAISecrets(
                toPath: run.appendingPathComponent("ai-secrets.json").path,
                keychainReader: { $0 == "aiApiKey" ? "secret" : nil }
            )
        )
        for sibling in [unknown, serviceLock] {
            var info = stat()
            XCTAssertEqual(lstat(sibling.path, &info), 0)
            XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
        }
    }

    func testRuntimeSecretsRefreshTreatsOwnedEmptyBridgeRemovalAsSuccess_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-secret-empty-refresh-\(UUID().uuidString)", isDirectory: true)
        let run = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        chmod(root.path, 0o700)
        chmod(run.path, 0o700)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = run.appendingPathComponent("isolated.sock").path
        let secretsPath = EngramServiceLauncher.runtimeAISecretsPath(forSocketPath: socketPath)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: secretsPath))

        XCTAssertTrue(
            EngramServiceLauncher.refreshRuntimeAISecrets(
                toPath: secretsPath,
                keychainReader: { _ in nil }
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: secretsPath))

        let absentBridge = root
            .appendingPathComponent("not-created/run/isolated.sock.ai-secrets.json")
            .path
        XCTAssertTrue(
            EngramServiceLauncher.refreshRuntimeAISecrets(
                toPath: absentBridge,
                keychainReader: { _ in nil }
            ),
            "clearing the last key is already refreshed when no runtime bridge or parent exists"
        )
    }

    @MainActor
    func testCustomDotEngramRunSocketDoesNotClaimDedicatedRuntime_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-custom-run-\(UUID().uuidString)", isDirectory: true)
        let run = root.appendingPathComponent("caller/.engram/run", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        chmod(run.path, 0o700)
        defer { try? FileManager.default.removeItem(at: root) }
        let referent = root.appendingPathComponent("caller-owned")
        try Data("keep".utf8).write(to: referent)
        let planted = run.appendingPathComponent("unknown-link")
        try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: referent)

        let launcher = EngramServiceLauncher()
        try launcher.start(configuration: EngramServiceLaunchConfiguration(
            executablePath: "/usr/bin/true",
            socketPath: run.appendingPathComponent("custom.sock").path,
            databasePath: root.appendingPathComponent("index.sqlite").path,
            foreground: false
        ))
        launcher.stopIfOwned()

        var info = stat()
        XCTAssertEqual(lstat(planted.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
    }

    func testRuntimeSecretsCleanupDoesNotClaimForeignEngramRunDirectory_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-foreign-runtime-\(UUID().uuidString)", isDirectory: true)
        let foreignRun = root.appendingPathComponent("caller/.engram/run", isDirectory: true)
        try FileManager.default.createDirectory(at: foreignRun, withIntermediateDirectories: true)
        chmod(foreignRun.path, 0o700)
        defer { try? FileManager.default.removeItem(at: root) }
        let foreignSecrets = foreignRun.appendingPathComponent("ai-secrets.json")
        let sentinel = Data("caller-owned".utf8)
        try sentinel.write(to: foreignSecrets)

        _ = EngramServiceLauncher.environment(
            baseEnvironment: [:],
            runtimeAISecretsPath: foreignSecrets.path,
            keychainReader: { _ in nil }
        )

        XCTAssertEqual(try Data(contentsOf: foreignSecrets), sentinel)
    }

    @MainActor
    func testCustomSocketSecretsAreNamespacedAndPreserveGenericSibling_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-custom-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chmod(root.path, 0o700)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("custom.sock").path
        let genericSibling = root.appendingPathComponent("ai-secrets.json")
        try Data("caller-owned".utf8).write(to: genericSibling)

        let secretsPath = EngramServiceLauncher.runtimeAISecretsPath(forSocketPath: socketPath)
        XCTAssertEqual(secretsPath, socketPath + ".ai-secrets.json")
        try Data("stale-owned-secret".utf8).write(to: URL(fileURLWithPath: secretsPath))
        _ = EngramServiceLauncher.environment(
            baseEnvironment: [:],
            runtimeAISecretsPath: secretsPath,
            keychainReader: { _ in nil }
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: secretsPath))
        EngramServiceLauncher().scrubRuntimeAISecrets(forSocketPath: socketPath)

        XCTAssertEqual(try Data(contentsOf: genericSibling), Data("caller-owned".utf8))
    }

    func testSecureRegularFileRejectsIntermediateEngramSymlink_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-intermediate-link-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let outsideRun = root.appendingPathComponent("outside/run", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRun, withIntermediateDirectories: true)
        chmod(home.path, 0o700)
        chmod(outsideRun.deletingLastPathComponent().path, 0o700)
        chmod(outsideRun.path, 0o700)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".engram"),
            withDestinationURL: outsideRun.deletingLastPathComponent()
        )
        let target = home.appendingPathComponent(".engram/run/secret")

        XCTAssertThrowsError(try SecureRegularFile.writeAtomically(Data("secret".utf8), toPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideRun.appendingPathComponent("secret").path))
    }

    func testRuntimeAISecretsRefusesCustomParentSymlinkWithoutTouchingTarget_repro() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-secrets-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chmod(root.path, 0o700)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try Data("sentinel".utf8).write(to: outside)
        let secretsPath = root.appendingPathComponent("ai-secrets.json")
        try FileManager.default.createSymbolicLink(atPath: secretsPath.path, withDestinationPath: outside.path)

        XCTAssertFalse(
            EngramServiceLauncher.writeRuntimeAISecrets(
                toPath: secretsPath.path,
                keychainReader: { _ in "secret" }
            )
        )
        XCTAssertEqual(try Data(contentsOf: outside), Data("sentinel".utf8))
        var info = stat()
        XCTAssertEqual(lstat(secretsPath.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
    }

    func testRuntimeAISecretsRejectsSymlinkParentAndPreservesUnrelatedLeftovers_repro() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-secrets-parent-\(UUID().uuidString)", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let linkedParent = root.appendingPathComponent("linked-run", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: linkedParent.path, withDestinationPath: outside.path)
        XCTAssertFalse(
            EngramServiceLauncher.writeRuntimeAISecrets(
                toPath: linkedParent.appendingPathComponent("ai-secrets.json").path,
                keychainReader: { _ in "secret" }
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("ai-secrets.json").path))

        let runDirectory = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let planted = runDirectory.appendingPathComponent("planted")
        try FileManager.default.createSymbolicLink(atPath: planted.path, withDestinationPath: outside.path)
        XCTAssertTrue(
            EngramServiceLauncher.writeRuntimeAISecrets(
                toPath: runDirectory.appendingPathComponent("ai-secrets.json").path,
                keychainReader: { _ in "secret" }
            )
        )
        var plantedInfo = stat()
        XCTAssertEqual(lstat(planted.path, &plantedInfo), 0)
        XCTAssertEqual(plantedInfo.st_mode & S_IFMT, S_IFLNK)
    }

    func testRuntimeAISecretsUsesDirfdPinnedAtomicWriter_repro() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Engram/Core/EngramServiceLauncher.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "static func writeRuntimeAISecrets")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "static func refreshRuntimeAISecrets", range: start..<source.endIndex)?.lowerBound)
        let body = source[start..<end]

        XCTAssertTrue(body.contains("SecureRegularFile.writeAtomically"))
        XCTAssertFalse(body.contains("lstat(path"))
        XCTAssertFalse(body.contains("open(path"))
    }

    /// SEC-H2: ai-secrets.json must be removed on service stop so a leftover
    /// plaintext Keychain bridge is not left in ~/.engram/run/.
    func testRemoveRuntimeAISecretsDeletesBridgeFile_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-secrets-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chmod(root.path, 0o700)
        defer { try? FileManager.default.removeItem(at: root) }
        let secretsPath = root.appendingPathComponent("ai-secrets.json").path

        XCTAssertTrue(
            EngramServiceLauncher.writeRuntimeAISecrets(
                toPath: secretsPath,
                keychainReader: { account in
                    account == "aiApiKey" ? "cleanup-secret" : nil
                }
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: secretsPath))

        EngramServiceLauncher.removeRuntimeAISecrets(atPath: secretsPath)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: secretsPath),
            "SEC-H2: removeRuntimeAISecrets must delete the plaintext bridge file"
        )
    }

    func testRemoveRuntimeAISecretsNeverRecursivelyDeletesDirectory_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-secrets-directory-\(UUID().uuidString)", isDirectory: true)
        let secretsDirectory = root.appendingPathComponent("ai-secrets.json", isDirectory: true)
        try FileManager.default.createDirectory(at: secretsDirectory, withIntermediateDirectories: true)
        let marker = secretsDirectory.appendingPathComponent("marker")
        try Data("keep".utf8).write(to: marker)
        defer { try? FileManager.default.removeItem(at: root) }

        EngramServiceLauncher.removeRuntimeAISecrets(atPath: secretsDirectory.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRemoveRuntimeAISecretsUnlinksHardlinkWithoutOverwritingPeer_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-secrets-hardlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chmod(root.path, 0o700)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = root.appendingPathComponent("peer")
        let secrets = root.appendingPathComponent("ai-secrets.json")
        let original = Data("shared-secret".utf8)
        try original.write(to: peer)
        try FileManager.default.linkItem(at: peer, to: secrets)

        EngramServiceLauncher.removeRuntimeAISecrets(atPath: secrets.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: secrets.path))
        XCTAssertEqual(try Data(contentsOf: peer), original)
    }

    func testWriteRuntimeAISecretsRecoversFromHardlinkedLeftover_repro() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-secrets-write-hardlink-\(UUID().uuidString)", isDirectory: true)
        let runtime = home.appendingPathComponent(".engram/run", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        chmod(home.appendingPathComponent(".engram").path, 0o700)
        chmod(runtime.path, 0o700)
        defer { try? FileManager.default.removeItem(at: home) }
        let peer = home.appendingPathComponent("peer")
        // A non-default service owns its socket-namespaced sidecar. A bare
        // `ai-secrets.json` outside the real default runtime must stay foreign.
        let secrets = runtime.appendingPathComponent("engram-service.sock.ai-secrets.json")
        let original = Data("shared-secret".utf8)
        try original.write(to: peer)
        XCTAssertEqual(link(peer.path, secrets.path), 0)

        XCTAssertTrue(
            EngramServiceLauncher.writeRuntimeAISecrets(
                toPath: secrets.path,
                keychainReader: { $0 == "aiApiKey" ? "fresh-secret" : nil }
            )
        )
        XCTAssertEqual(try Data(contentsOf: peer), original)
        XCTAssertNotEqual(try Data(contentsOf: secrets), original)
        var info = stat()
        XCTAssertEqual(lstat(secrets.path, &info), 0)
        XCTAssertEqual(info.st_nlink, 1)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    /// SEC-H2: stopIfOwned / stopProcessOnly must clean the runtime secrets path
    /// derived from the socket (same path writeRuntimeAISecrets uses).
    @MainActor
    func testStopIfOwnedRemovesRuntimeAISecretsBesideSocket_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-stop-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chmod(root.path, 0o700)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("engram-service.sock").path
        let secretsPath = EngramServiceLauncher.runtimeAISecretsPath(forSocketPath: socketPath)
        XCTAssertTrue(
            EngramServiceLauncher.writeRuntimeAISecrets(
                toPath: secretsPath,
                keychainReader: { $0 == "embeddingApiKey" ? "embed-secret" : nil }
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: secretsPath))

        let launcher = EngramServiceLauncher(
            healthIntervalNanoseconds: 50_000_000,
            maximumRestartAttempts: 0,
            startupGraceNanoseconds: 0
        )
        // No process started — stop path must still scrub secrets for the socket.
        launcher.scrubRuntimeAISecrets(forSocketPath: socketPath)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: secretsPath),
            "SEC-H2: stop/scrub must remove ai-secrets.json next to the service socket"
        )
    }

    @MainActor
    func testStartScrubsRuntimeSecretsWhenProcessRunThrows_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-start-failure-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secretsPath = root.appendingPathComponent("ai-secrets.json").path
        try Data("secret".utf8).write(to: URL(fileURLWithPath: secretsPath))
        let process = Process()
        process.executableURL = root.appendingPathComponent("missing-helper")
        let launcher = EngramServiceLauncher()

        XCTAssertThrowsError(try launcher.runProcess(process, runtimeAISecretsPath: secretsPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secretsPath))
    }

    func testServiceOutputLineBufferWaitsForCompleteJSONLines() throws {
        let buffer = ServiceOutputLineBuffer()

        XCTAssertEqual(buffer.append(Data(#"{"event":"indexed","#.utf8)), [])

        let firstChunk = Data((#""total":2,"todayParents":1}"# + "\n{\"event\":\"warning\"").utf8)
        let first = buffer.append(firstChunk)
        XCTAssertEqual(first.count, 1)
        let indexed = try JSONDecoder().decode(EngramServiceEvent.self, from: Data(first[0].utf8))
        XCTAssertEqual(indexed.event, "indexed")
        XCTAssertEqual(indexed.total, 2)
        XCTAssertEqual(indexed.todayParents, 1)

        let second = buffer.append(Data((#","message":"slow"}"# + "\n").utf8))
        XCTAssertEqual(second.count, 1)
        let warning = try JSONDecoder().decode(EngramServiceEvent.self, from: Data(second[0].utf8))
        XCTAssertEqual(warning.event, "warning")
        XCTAssertEqual(warning.message, "slow")
    }

    func testServiceStdoutDecoderFlushesWhenNewlineArrivesSeparately() {
        let buffer = ServiceOutputLineBuffer()
        let json = #"{"event":"indexed","total":4,"todayParents":2}"#

        XCTAssertEqual(
            EngramServiceLauncher.decodeServiceStdoutEvents(from: Data(json.utf8), lineBuffer: buffer),
            []
        )

        let events = EngramServiceLauncher.decodeServiceStdoutEvents(
            from: Data("\n".utf8),
            lineBuffer: buffer
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "indexed")
        XCTAssertEqual(events[0].total, 4)
        XCTAssertEqual(events[0].todayParents, 2)
    }

    func testDefaultConfigurationUsesEngramRunSocketAndServiceHelperName() {
        let home = URL(fileURLWithPath: "/tmp/engram-home", isDirectory: true)
        let config = EngramServiceLaunchConfiguration.default(
            homeDirectory: home,
            databasePath: "/tmp/custom.sqlite",
            bundle: .main
        )

        XCTAssertTrue(config.executablePath.hasSuffix("EngramService"))
        XCTAssertEqual(config.socketPath, "/tmp/engram-home/.engram/run/engram-service.sock")
        XCTAssertEqual(config.databasePath, "/tmp/custom.sqlite")
    }

    @MainActor
    func testHealthMonitorRestartsThenMarksDegradedAfterBudget() async throws {
        let executable = try makeSleeperExecutable()
        let launcher = EngramServiceLauncher(
            healthIntervalNanoseconds: 5_000_000,
            maximumRestartAttempts: 1,
            startupGraceNanoseconds: 0
        )
        let config = EngramServiceLaunchConfiguration(
            executablePath: executable.path,
            socketPath: "/tmp/engram-health.sock",
            databasePath: "/tmp/engram-health.sqlite",
            foreground: false
        )
        let recorder = ServiceStatusRecorder()

        launcher.startHealthMonitor(
            configuration: config,
            statusProbe: {
                throw EngramServiceError.serviceUnavailable(message: "probe failed")
            },
            onStatus: { status in
                recorder.append(status)
            }
        )

        try await Task.sleep(nanoseconds: 80_000_000)
        launcher.stopIfOwned()

        XCTAssertTrue(recorder.statuses.contains(.starting))
        XCTAssertTrue(recorder.statuses.contains { status in
            if case .degraded(let message) = status {
                return message.contains("after 1 restart attempts")
            }
            return false
        })
    }

    @MainActor
    func testHealthMonitorKeepsProbingAndRecoversAfterBudgetExhausted() async throws {
        // R5-59: after the restart budget is spent the monitor must NOT stop
        // permanently — it keeps probing (with backoff) so the service can
        // recover without an app relaunch. Probe fails enough times to exhaust
        // the budget, then starts succeeding; we expect a running status after
        // the degraded one.
        let launcher = EngramServiceLauncher(
            healthIntervalNanoseconds: 5_000_000,
            maximumRestartAttempts: 1,
            startupGraceNanoseconds: 0
        )
        let config = EngramServiceLaunchConfiguration(
            executablePath: "/tmp/engram-recover-helper",
            socketPath: "/tmp/engram-recover.sock",
            databasePath: "/tmp/engram-recover.sqlite",
            foreground: false
        )
        let recorder = ServiceStatusRecorder()
        let gate = ProbeFailureGate(failuresBeforeRecovery: 3)

        launcher.startHealthMonitor(
            configuration: config,
            statusProbe: {
                if await gate.shouldFail() {
                    throw EngramServiceError.serviceUnavailable(message: "probe failed")
                }
                return .running(total: 7, todayParents: 1)
            },
            onStatus: { status in
                recorder.append(status)
            }
        )

        let sawDegraded = await recorder.waitUntil(timeoutNanoseconds: 2_000_000_000) { statuses in
            statuses.contains { status in
                if case .degraded = status { return true }
                return false
            }
        }
        let recovered = await recorder.waitUntil(timeoutNanoseconds: 2_000_000_000) { statuses in
            statuses.contains { status in
                if case .running = status { return true }
                return false
            }
        }
        launcher.stopIfOwned()

        XCTAssertTrue(sawDegraded, "expected a degraded status after budget exhaustion")
        XCTAssertTrue(recovered, "monitor must recover to running after the service comes back")
    }

    @MainActor
    func testHealthMonitorDoesNotRestartDuringStartupGrace() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-startup-grace-\(UUID().uuidString)")
        let executable = try makeCountingSleeperExecutable(marker: marker)
        let launcher = EngramServiceLauncher(
            healthIntervalNanoseconds: 5_000_000,
            maximumRestartAttempts: 1,
            startupGraceNanoseconds: 250_000_000
        )
        let config = EngramServiceLaunchConfiguration(
            executablePath: executable.path,
            socketPath: "/tmp/engram-startup-grace.sock",
            databasePath: "/tmp/engram-startup-grace.sqlite",
            foreground: false
        )
        let recorder = ServiceStatusRecorder()

        try launcher.start(configuration: config)
        let markerWritten = await waitForFile(at: marker, timeoutNanoseconds: 500_000_000)
        XCTAssertTrue(markerWritten, "test helper should record its initial launch before health probing starts")
        launcher.startHealthMonitor(
            configuration: config,
            statusProbe: {
                throw EngramServiceError.serviceUnavailable(message: "socket not ready")
            },
            onStatus: { status in
                recorder.append(status)
            }
        )

        let sawStarting = await recorder.waitUntil(timeoutNanoseconds: 120_000_000) { statuses in
            statuses.contains(.starting)
        }
        launcher.stopIfOwned()

        let launches = (try? String(contentsOf: marker, encoding: .utf8))?
            .split(separator: "\n")
            .count ?? 0
        XCTAssertTrue(sawStarting, "startup probe failures should keep reporting starting during grace")
        XCTAssertEqual(launches, 1, "startup probe failures must not restart a legitimately slow service")
        XCTAssertFalse(recorder.statuses.contains { status in
            if case .degraded = status { return true }
            return false
        })
    }

    @MainActor
    func testExitedHelperSurfacesFailureDuringGraceAndKeepsRespawning_repro() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-exited-helper-\(UUID().uuidString)")
        let executable = try makeCountingExitExecutable(marker: marker)
        let launcher = EngramServiceLauncher(
            healthIntervalNanoseconds: 5_000_000,
            maximumRestartAttempts: 0,
            startupGraceNanoseconds: 1_000_000_000
        )
        let config = EngramServiceLaunchConfiguration(
            executablePath: executable.path,
            socketPath: "/tmp/engram-exited-helper.sock",
            databasePath: "/tmp/engram-exited-helper.sqlite",
            foreground: false
        )
        let recorder = ServiceStatusRecorder()

        try launcher.start(configuration: config)
        launcher.startHealthMonitor(
            configuration: config,
            statusProbe: {
                throw EngramServiceError.serviceUnavailable(message: "socket not ready")
            },
            onStatus: { status in recorder.append(status) }
        )

        let sawFailure = await recorder.waitUntil(timeoutNanoseconds: 800_000_000) { statuses in
            statuses.contains { status in
                if case .error = status { return true }
                if case .degraded = status { return true }
                return false
            }
        }
        let respawned = await waitForMarkerLineCount(marker, count: 2, timeoutNanoseconds: 500_000_000)
        launcher.stopIfOwned()

        XCTAssertTrue(sawFailure, "a helper that exited must not remain Starting for the full grace period")
        XCTAssertTrue(respawned, "a dead helper must keep receiving spawn attempts after the restart budget")
    }

    @MainActor
    func testLauncherDrainsServiceOutputPipes() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-service-output-\(UUID().uuidString)")
        let executable = try makeNoisyExecutable(marker: marker)
        let launcher = EngramServiceLauncher()
        let config = EngramServiceLaunchConfiguration(
            executablePath: executable.path,
            socketPath: "/tmp/engram-output.sock",
            databasePath: "/tmp/engram-output.sqlite",
            foreground: false
        )

        try launcher.start(configuration: config)
        // Pipe-fill + drain can take longer under xctest load when every stdout
        // chunk is logged via os_log; allow enough wall time before declaring failure.
        let deadline = Date().addingTimeInterval(12)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let markerExists = FileManager.default.fileExists(atPath: marker.path)
        launcher.stopIfOwned()

        XCTAssertTrue(markerExists, "Noisy helper must finish when stdout/stderr are drained")
    }

    func testPipeDrainTestCannotSkipMissingMarker_repro() throws {
        let source = try String(contentsOfFile: #filePath, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func testLauncherDrainsServiceOutputPipes")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "func testPipeDrainTestCannotSkipMissingMarker_repro", range: start..<source.endIndex)?.lowerBound)
        let testBody = source[start..<end]
        XCTAssertTrue(testBody.contains("XCTAssertTrue(markerExists"))
        XCTAssertFalse(testBody.contains("XCTSkip"))
    }

    @MainActor
    func testStopIfOwnedDoesNotBlockMainRunLoopWhileChildStillRunning() async throws {
        // Regression: stopIfOwned() used to poll the child's exit with
        // Thread.sleep on the main actor, blocking the run loop for up to the
        // full 2s timeout. The bounded wait now suspends instead of blocking,
        // so the call must return promptly even while the child is alive.
        let executable = try makeSleeperExecutable()
        let launcher = EngramServiceLauncher()
        let config = EngramServiceLaunchConfiguration(
            executablePath: executable.path,
            socketPath: "/tmp/engram-stop.sock",
            databasePath: "/tmp/engram-stop.sqlite",
            foreground: false
        )

        try launcher.start(configuration: config)
        XCTAssertTrue(launcher.isRunning)

        let start = Date()
        launcher.stopIfOwned()
        let elapsed = Date().timeIntervalSince(start)

        // Must be near-instant, well under the 2s exit-wait budget.
        XCTAssertLessThan(elapsed, 0.5)
        // The launcher retains a helper that is still shutting down so no
        // replacement can be mistaken as safe to spawn during that window.
        XCTAssertTrue(launcher.isRunning)
    }

    @MainActor
    func testRestartReArmsHealthMonitorAndReportsRunning() async throws {
        let executable = try makeSleeperExecutable()
        let launcher = EngramServiceLauncher(
            healthIntervalNanoseconds: 5_000_000,
            maximumRestartAttempts: 1,
            startupGraceNanoseconds: 0
        )
        let config = EngramServiceLaunchConfiguration(
            executablePath: executable.path,
            socketPath: "/tmp/engram-restart.sock",
            databasePath: "/tmp/engram-restart.sqlite",
            foreground: false
        )
        let recorder = ServiceStatusRecorder()

        try launcher.start(configuration: config)
        await launcher.restart(
            configuration: config,
            statusProbe: { .running(total: 3, todayParents: 0) },
            onStatus: { status in recorder.append(status) },
            onEvent: nil
        )

        let recovered = await recorder.waitUntil(timeoutNanoseconds: 1_000_000_000) { statuses in
            statuses.contains(.running(total: 3, todayParents: 0))
        }
        launcher.stopIfOwned()

        XCTAssertTrue(recorder.statuses.contains(.starting))
        XCTAssertTrue(recovered, "restart must re-arm the monitor and recover to running")
    }

    @MainActor
    func testRestartNoLeakedProcess() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-restart-leak-\(UUID().uuidString)")
        let countingSleeper = try makeCountingSleeperExecutable(marker: marker)
        let launcher = EngramServiceLauncher(
            healthIntervalNanoseconds: 5_000_000,
            maximumRestartAttempts: 1,
            startupGraceNanoseconds: 0
        )
        let config = EngramServiceLaunchConfiguration(
            executablePath: countingSleeper.path,
            socketPath: "/tmp/engram-restart-leak.sock",
            databasePath: "/tmp/engram-restart-leak.sqlite",
            foreground: false
        )

        try launcher.start(configuration: config)
        let markerAppeared = await waitForFile(at: marker, timeoutNanoseconds: 500_000_000)
        XCTAssertTrue(markerAppeared)
        await launcher.restart(
            configuration: config,
            statusProbe: { .running(total: 0, todayParents: 0) },
            onStatus: { _ in },
            onEvent: nil
        )
        // The restarted spawn appends a second 'start' line.
        let sawTwo = await waitForMarkerLineCount(marker, count: 2, timeoutNanoseconds: 500_000_000)
        launcher.stopIfOwned()

        let lines = (try? String(contentsOf: marker, encoding: .utf8))?
            .split(separator: "\n")
            .count ?? 0
        XCTAssertTrue(sawTwo)
        // Exactly 2: original spawn + restarted spawn, proving the old process
        // was terminated (not leaked) and a fresh one spawned.
        XCTAssertEqual(lines, 2)
    }

    @MainActor
    func testRestartWaitsForTerminatingHelperBeforeSpawningReplacement_repro() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-delayed-shutdown-\(UUID().uuidString)")
        let executable = try makeDelayedTerminationExecutable(marker: marker)
        let launcher = EngramServiceLauncher()
        let config = EngramServiceLaunchConfiguration(
            executablePath: executable.path,
            socketPath: "/tmp/engram-delayed-shutdown.sock",
            databasePath: "/tmp/engram-delayed-shutdown.sqlite",
            foreground: false
        )

        try launcher.start(configuration: config)
        let initialSpawned = await waitForMarkerLineCount(
            marker,
            count: 1,
            timeoutNanoseconds: 500_000_000
        )
        XCTAssertTrue(initialSpawned)

        let restartStartedAt = Date()
        await launcher.restart(
            configuration: config,
            statusProbe: { .running(total: 0, todayParents: 0) },
            onStatus: { _ in }
        )
        let restartElapsed = Date().timeIntervalSince(restartStartedAt)
        let spawnedReplacement = await waitForMarkerLineCount(
            marker,
            count: 2,
            timeoutNanoseconds: 250_000_000
        )

        // docs/invariants.md #1: a replacement must not race the still-live
        // helper for the service's single-writer lock.
        XCTAssertTrue(spawnedReplacement)
        XCTAssertGreaterThanOrEqual(
            restartElapsed,
            2.5,
            "restart must await the delayed helper's exit before returning with a replacement"
        )
        XCTAssertTrue(launcher.isRunning, "the replacement helper must remain owned")
        launcher.stopIfOwned()
    }

    @MainActor
    func testRestartWaitsThroughCooperativeShutdownBeforeReplacing_repro() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-cooperative-shutdown-\(UUID().uuidString)")
        let executable = try makeDelayedTerminationExecutable(marker: marker)
        let launcher = EngramServiceLauncher(
            healthIntervalNanoseconds: 5_000_000,
            maximumRestartAttempts: 1,
            startupGraceNanoseconds: 0
        )
        let config = EngramServiceLaunchConfiguration(
            executablePath: executable.path,
            socketPath: "/tmp/engram-cooperative-shutdown.sock",
            databasePath: "/tmp/engram-cooperative-shutdown.sqlite",
            foreground: false
        )
        let recorder = ServiceStatusRecorder()

        try launcher.start(configuration: config)
        let initialStarted = await waitForMarkerLineCount(
            marker,
            count: 1,
            timeoutNanoseconds: 500_000_000
        )
        XCTAssertTrue(initialStarted)
        await launcher.restart(
            configuration: config,
            statusProbe: { .running(total: 1, todayParents: 0) },
            onStatus: { recorder.append($0) }
        )
        let replacementStarted = await waitForMarkerLineCount(
            marker,
            count: 2,
            timeoutNanoseconds: 500_000_000
        )
        launcher.stopIfOwned()

        // docs/invariants.md #1: wait for the cooperative owner to release the
        // writer lock, then recover; a fixed 2s degrade must not strand restart.
        XCTAssertTrue(replacementStarted)
        XCTAssertTrue(recorder.statuses.contains(.starting))
    }

    @MainActor
    func testStartRefusesToSpawnWhileServiceProcessLockIsHeld_repro() async throws {
        let runtimeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-launch-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockPath = runtimeDirectory.appendingPathComponent("engram-service.lock").path
        let lockFD = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        XCTAssertGreaterThanOrEqual(lockFD, 0)
        XCTAssertEqual(flock(lockFD, LOCK_EX | LOCK_NB), 0)
        defer {
            flock(lockFD, LOCK_UN)
            close(lockFD)
            try? FileManager.default.removeItem(at: runtimeDirectory)
        }

        let marker = runtimeDirectory.appendingPathComponent("spawned")
        let executable = try makeCountingSleeperExecutable(marker: marker)
        let launcher = EngramServiceLauncher()
        let config = EngramServiceLaunchConfiguration(
            executablePath: executable.path,
            socketPath: runtimeDirectory.appendingPathComponent("engram.sock").path,
            databasePath: runtimeDirectory.appendingPathComponent("index.sqlite").path,
            foreground: false
        )

        XCTAssertThrowsError(try launcher.start(configuration: config)) { error in
            XCTAssertNotNil(engramServiceWriterBusyMessage(error))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    @MainActor
    func testWriterBusyExitZeroReportsStillShuttingDown_repro() async throws {
        let runtimeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-writer-busy-exit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: runtimeDirectory) }
        let launcher = EngramServiceLauncher(
            healthIntervalNanoseconds: 1_000_000_000,
            maximumRestartAttempts: 0,
            startupGraceNanoseconds: 0
        )
        let recorder = ServiceStatusRecorder()
        let config = EngramServiceLaunchConfiguration(
            executablePath: try makeWriterBusyExitExecutable().path,
            socketPath: runtimeDirectory.appendingPathComponent("engram.sock").path,
            databasePath: runtimeDirectory.appendingPathComponent("index.sqlite").path,
            foreground: false
        )

        launcher.startHealthMonitor(
            configuration: config,
            statusProbe: { .running(total: 0, todayParents: 0) },
            onStatus: { recorder.append($0) }
        )
        try launcher.start(configuration: config)
        let reported = await recorder.waitUntil(timeoutNanoseconds: 500_000_000) { statuses in
            statuses.contains { status in
                if case .degraded(let message) = status {
                    return message.contains("still shutting down")
                }
                return false
            }
        }
        launcher.stopIfOwned()

        XCTAssertTrue(reported)
        XCTAssertFalse(recorder.statuses.contains { status in
            if case .error(let message) = status { return message.contains("status 0") }
            return false
        })
    }

    @MainActor
    func testRestartWithMissingHelperSurfacesError() async throws {
        let launcher = EngramServiceLauncher()
        let config = EngramServiceLaunchConfiguration(
            executablePath: "/tmp/engram-does-not-exist-\(UUID().uuidString)",
            socketPath: "/tmp/engram-restart-missing.sock",
            databasePath: "/tmp/engram-restart-missing.sqlite",
            foreground: false
        )
        let recorder = ServiceStatusRecorder()

        await launcher.restart(
            configuration: config,
            statusProbe: { .running(total: 0, todayParents: 0) },
            onStatus: { status in recorder.append(status) },
            onEvent: nil
        )

        XCTAssertTrue(recorder.statuses.contains { status in
            if case .error = status { return true }
            return false
        })
        XCTAssertFalse(launcher.isRunning)
    }

    @MainActor
    func testQuitPreservesAdoptedServiceAndItsRuntimeSecrets_repro() async throws {
        let fixture = try AdoptedServiceFixture()
        defer { fixture.cleanup() }
        let launcher = EngramServiceLauncher(
            healthIntervalNanoseconds: 60_000_000_000,
            maximumRestartAttempts: 0,
            startupGraceNanoseconds: 0
        )
        let state = fixture.state
        let secrets = URL(fileURLWithPath: EngramServiceLauncher.runtimeAISecretsPath(
            forSocketPath: fixture.configuration.socketPath
        ))
        let original = Data("external-owner-secret".utf8)
        try original.write(to: secrets)

        await launcher.startOrAdopt(
            configuration: fixture.configuration,
            statusProbe: { try await state.status() },
            onStatus: { _ in }
        )
        launcher.stopIfOwned()
        try await Task.sleep(nanoseconds: 100_000_000)
        let requestedSockets = await state.requestedSockets()
        XCTAssertTrue(requestedSockets.isEmpty, "quitting the app must not shut down an external service")
        XCTAssertEqual(try Data(contentsOf: secrets), original, "external runtime credentials are not launcher-owned")
        let status = try await state.status()
        XCTAssertEqual(status, .running(total: 1, todayParents: 0))
    }

    @MainActor
    func testAdoptedServiceProbeFailureRecoversWithoutShutdownOrReplacement_repro() async throws {
        let fixture = try AdoptedServiceFixture()
        defer { fixture.cleanup() }
        let state = fixture.state
        let recorder = ServiceStatusRecorder()
        let launcher = EngramServiceLauncher(
            healthIntervalNanoseconds: 5_000_000,
            maximumRestartAttempts: 1,
            startupGraceNanoseconds: 0
        )
        defer { launcher.stopIfOwned() }
        await launcher.startOrAdopt(
            configuration: fixture.configuration,
            statusProbe: { try await state.status() },
            onStatus: { recorder.append($0) }
        )
        await state.failNextProbes(2)

        let recovered = await recorder.waitUntil(timeoutNanoseconds: 2_000_000_000) { statuses in
            guard let failure = statuses.firstIndex(where: {
                if case .degraded = $0 { return true }
                return false
            }) else { return false }
            return statuses.dropFirst(failure + 1).contains(.running(total: 1, todayParents: 0))
        }
        XCTAssertTrue(recovered, "an external service must remain monitored through temporary probe failures")
        let requestedSockets = await state.requestedSockets()
        XCTAssertTrue(requestedSockets.isEmpty)
        XCTAssertEqual(markerLineCount(fixture.marker), 0, "health checks must never replace an external service")
        XCTAssertFalse(recorder.statuses.contains(.starting))
    }

    @MainActor
    func testSuspendedAdoptedProbeCannotRestartAfterQuit_repro() async throws {
        let fixture = try AdoptedServiceFixture()
        defer { fixture.cleanup() }
        let state = fixture.state
        let recorder = ServiceStatusRecorder()
        let launcher = EngramServiceLauncher(
            healthIntervalNanoseconds: 5_000_000,
            maximumRestartAttempts: 1,
            startupGraceNanoseconds: 0
        )
        defer { launcher.stopIfOwned() }
        await launcher.startOrAdopt(
            configuration: fixture.configuration,
            statusProbe: { try await state.status() },
            onStatus: { recorder.append($0) }
        )
        await state.suspendNextProbe()
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await state.hasSuspendedProbe()), ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let suspended = await state.hasSuspendedProbe()
        XCTAssertTrue(suspended, "the health probe must be suspended before quitting")
        launcher.stopIfOwned()
        let statusesAtQuit = recorder.statuses
        await state.resumeSuspendedProbe()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(recorder.statuses, statusesAtQuit, "a cancelled monitor must not publish a late failure")
        XCTAssertEqual(markerLineCount(fixture.marker), 0, "a late probe failure must not spawn a helper after quit")
        let requestedSockets = await state.requestedSockets()
        XCTAssertTrue(requestedSockets.isEmpty)
    }

    @MainActor
    func testRestartOfAdoptedServiceOnlyReconnects_repro() async throws {
        let fixture = try AdoptedServiceFixture()
        defer { fixture.cleanup() }
        let state = fixture.state
        let launcher = EngramServiceLauncher(
            healthIntervalNanoseconds: 60_000_000_000,
            maximumRestartAttempts: 0,
            startupGraceNanoseconds: 0
        )
        defer { launcher.stopIfOwned() }
        let recorder = ServiceStatusRecorder()
        await launcher.startOrAdopt(
            configuration: fixture.configuration,
            statusProbe: { try await state.status() },
            onStatus: { recorder.append($0) }
        )
        await launcher.restart(
            configuration: fixture.configuration,
            statusProbe: { try await state.status() },
            onStatus: { recorder.append($0) }
        )
        await state.markStopped()
        await launcher.restart(
            configuration: fixture.configuration,
            statusProbe: { try await state.status() },
            onStatus: { recorder.append($0) }
        )

        let requestedSockets = await state.requestedSockets()
        XCTAssertTrue(requestedSockets.isEmpty)
        XCTAssertEqual(markerLineCount(fixture.marker), 0, "even an unavailable external service belongs to its supervisor")
        XCTAssertFalse(recorder.statuses.contains(.starting))
        XCTAssertTrue(recorder.statuses.contains { status in
            if case .degraded(let message) = status { return message.contains("externally managed") }
            return false
        })
    }
    @MainActor
    func testRuntimeRoleColdIndexCannotSpawnOrTouchLockAndSecrets_repro() async throws {
        let fixture = try RuntimeRoleLauncherFixture(role: .index)
        defer { fixture.cleanup() }
        let launcher = EngramServiceLauncher(healthIntervalNanoseconds: 60_000_000_000)
        defer { launcher.stopIfOwned() }
        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(
            socketPath: fixture.configuration.socketPath, connectTimeout: 0.05
        ))
        defer { client.close() }
        let recorder = ServiceStatusRecorder()
        await launcher.startOrAdopt(
            configuration: fixture.configuration,
            statusProbe: { try await client.status() },
            onStatus: { recorder.append($0) }
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(launcher.isRunning, "an absent external socket is not a running service")
        XCTAssertFalse(recorder.statuses.contains(.starting))
        XCTAssertTrue(recorder.statuses.contains {
            if case .degraded(let message) = $0 { return message.contains("externally managed") }
            return false
        })
        XCTAssertEqual(markerLineCount(fixture.marker), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lock.path))
        XCTAssertEqual(try? Data(contentsOf: fixture.secret), fixture.secretBytes)
    }

    @MainActor
    func testRuntimeRoleIndexReconnectsAfterInitialFailureWithoutTakingOwnership_repro() async throws {
        let fixture = try RuntimeRoleLauncherFixture(role: .index)
        defer { fixture.cleanup() }
        let launcher = EngramServiceLauncher(healthIntervalNanoseconds: 60_000_000_000)
        defer { launcher.stopIfOwned() }
        let state = AdoptedServiceState()
        await state.failNextProbes(1)
        let recorder = ServiceStatusRecorder()
        await launcher.startOrAdopt(
            configuration: fixture.configuration,
            statusProbe: { try await state.status() }, onStatus: { recorder.append($0) }
        )
        await launcher.restart(
            configuration: fixture.configuration,
            statusProbe: { try await state.status() }, onStatus: { recorder.append($0) }
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(launcher.isRunning)
        XCTAssertEqual(recorder.statuses.last, .running(total: 1, todayParents: 0))
        XCTAssertFalse(recorder.statuses.contains(.starting))
        launcher.stopIfOwned()
        XCTAssertEqual(markerLineCount(fixture.marker), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lock.path))
        XCTAssertEqual(try? Data(contentsOf: fixture.secret), fixture.secretBytes)
    }

    @MainActor
    func testRuntimeRoleSuspendedInitialProbeCannotStartAfterQuit_repro() async throws {
        for role in [EngramRuntimeRole.index, .local] {
            let fixture = try RuntimeRoleLauncherFixture(role: role)
            defer { fixture.cleanup() }
            let launcher = EngramServiceLauncher(healthIntervalNanoseconds: 60_000_000_000)
            defer { launcher.stopIfOwned() }
            let state = AdoptedServiceState()
            await state.suspendNextProbe()
            let recorder = ServiceStatusRecorder()
            let task = Task { @MainActor in
                await launcher.startOrAdopt(
                    configuration: fixture.configuration,
                    statusProbe: { try await state.status() }, onStatus: { recorder.append($0) }
                )
            }
            let deadline = ContinuousClock.now + .seconds(1)
            while !(await state.hasSuspendedProbe()), ContinuousClock.now < deadline {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let suspended = await state.hasSuspendedProbe()
            XCTAssertTrue(suspended)
            launcher.stopIfOwned()
            let statusesAtQuit = recorder.statuses
            await state.resumeSuspendedProbe()
            await task.value
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(recorder.statuses, statusesAtQuit)
            XCTAssertFalse(launcher.isRunning)
            XCTAssertEqual(markerLineCount(fixture.marker), 0, "\(role)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lock.path))
            XCTAssertEqual(try? Data(contentsOf: fixture.secret), fixture.secretBytes)
        }
    }

    @MainActor
    func testRuntimeRoleDirectStartRefusesNonLocalRolesBeforeAnySideEffects_repro() async throws {
        for role in [EngramRuntimeRole.collector, .replica, .invalidSettings, .index] {
            let fixture = try RuntimeRoleLauncherFixture(role: role)
            defer { fixture.cleanup() }
            let launcher = EngramServiceLauncher()
            defer { launcher.stopIfOwned() }
            XCTAssertThrowsError(try launcher.start(configuration: fixture.configuration))
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(markerLineCount(fixture.marker), 0, "\(role)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lock.path))
            XCTAssertEqual(try? Data(contentsOf: fixture.secret), fixture.secretBytes)
        }
    }
}

private final class RuntimeRoleLauncherFixture {
    let root: URL
    let marker: URL
    let lock: URL
    let secret: URL
    let secretBytes = Data("external-role-fixture-secret".utf8)
    let configuration: EngramServiceLaunchConfiguration
    private let executable: URL

    init(role: EngramRuntimeRole) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("e-role-\(UUID().uuidString.prefix(8))")
        let run = root.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        marker = root.appendingPathComponent("spawned")
        lock = run.appendingPathComponent("engram-service.lock")
        executable = try makeCountingExitExecutable(marker: marker)
        let socket = run.appendingPathComponent("service.sock").path
        secret = URL(fileURLWithPath: EngramServiceLauncher.runtimeAISecretsPath(forSocketPath: socket))
        try secretBytes.write(to: secret)
        _ = chmod(secret.path, 0o600)
        configuration = EngramServiceLaunchConfiguration(
            executablePath: executable.path, socketPath: socket,
            databasePath: root.appendingPathComponent("index.sqlite").path,
            foreground: false, runtimeRole: role
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: executable.deletingLastPathComponent())
    }
}

@MainActor
private final class ServiceStatusRecorder {
    private(set) var statuses: [EngramServiceStatus] = []

    func append(_ status: EngramServiceStatus) {
        statuses.append(status)
    }

    func waitUntil(
        timeoutNanoseconds: UInt64,
        predicate: ([EngramServiceStatus]) -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if predicate(statuses) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate(statuses)
    }
}

private actor ProbeFailureGate {
    private var remainingFailures: Int

    init(failuresBeforeRecovery: Int) {
        remainingFailures = failuresBeforeRecovery
    }

    func shouldFail() -> Bool {
        guard remainingFailures > 0 else { return false }
        remainingFailures -= 1
        return true
    }
}

private actor AdoptedServiceState {
    private var serving = true
    private var sockets: [String] = []
    private var remainingProbeFailures = 0
    private var shouldSuspendNextProbe = false
    private var suspendedProbe: CheckedContinuation<Void, Never>?

    func status() async throws -> EngramServiceStatus {
        if shouldSuspendNextProbe {
            shouldSuspendNextProbe = false
            await withCheckedContinuation { suspendedProbe = $0 }
            throw EngramServiceError.serviceUnavailable(message: "late probe failure")
        }
        if remainingProbeFailures > 0 {
            remainingProbeFailures -= 1
            throw EngramServiceError.serviceUnavailable(message: "temporary probe failure")
        }
        guard serving else {
            throw EngramServiceError.serviceUnavailable(message: "adopted service stopped")
        }
        return .running(total: 1, todayParents: 0)
    }

    func shutdown(socketPath: String) {
        sockets.append(socketPath)
        serving = false
    }

    func markStopped() {
        serving = false
    }

    func requestedSockets() -> [String] { sockets }

    func failNextProbes(_ count: Int) { remainingProbeFailures = count }

    func suspendNextProbe() { shouldSuspendNextProbe = true }

    func hasSuspendedProbe() -> Bool { suspendedProbe != nil }

    func resumeSuspendedProbe() {
        suspendedProbe?.resume()
        suspendedProbe = nil
    }
}

private final class AdoptedServiceFixture {
    let root: URL
    let marker: URL
    let configuration: EngramServiceLaunchConfiguration
    let state = AdoptedServiceState()
    private let executable: URL
    private let server: UnixSocketServiceServer

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("e-adopt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        marker = root.appendingPathComponent("replacement-started")
        executable = try makeCountingSleeperExecutable(marker: marker)
        let socketPath = root.appendingPathComponent("service.sock").path
        configuration = EngramServiceLaunchConfiguration(
            executablePath: executable.path,
            socketPath: socketPath,
            databasePath: root.appendingPathComponent("index.sqlite").path,
            foreground: false
        )
        let state = state
        server = UnixSocketServiceServer(socketPath: socketPath) { request in
            if request.command == "shutdown" {
                await state.shutdown(socketPath: socketPath)
            }
            return .success(requestId: request.requestId, result: Data("{}".utf8))
        }
        try server.start()
    }

    func cleanup() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: executable.deletingLastPathComponent())
    }
}

private func waitForFile(at url: URL, timeoutNanoseconds: UInt64) async -> Bool {
    let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
    while ContinuousClock.now < deadline {
        if FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return FileManager.default.fileExists(atPath: url.path)
}

private func markerLineCount(_ url: URL) -> Int {
    (try? String(contentsOf: url, encoding: .utf8))?
        .split(separator: "\n")
        .count ?? 0
}

private func waitForMarkerLineCount(_ url: URL, count: Int, timeoutNanoseconds: UInt64) async -> Bool {
    let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
    while ContinuousClock.now < deadline {
        if markerLineCount(url) >= count {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return markerLineCount(url) >= count
}

private func makeSleeperExecutable() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-service-launcher-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let executable = directory.appendingPathComponent("sleeper.sh")
    try "#!/bin/sh\nsleep 5\n".write(to: executable, atomically: true, encoding: .utf8)
    chmod(executable.path, 0o700)
    return executable
}

private func makeCountingSleeperExecutable(marker: URL) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-service-counting-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let executable = directory.appendingPathComponent("counting-sleeper.sh")
    try """
    #!/bin/sh
    printf 'start\\n' >> "\(marker.path)"
    sleep 5
    """.write(to: executable, atomically: true, encoding: .utf8)
    chmod(executable.path, 0o700)
    return executable
}

private func makeDelayedTerminationExecutable(marker: URL) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-service-delayed-stop-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let executable = directory.appendingPathComponent("delayed-stop.sh")
    try """
    #!/bin/sh
    trap '' TERM
    printf 'start\\n' >> "\(marker.path)"
    sleep 3
    """.write(to: executable, atomically: true, encoding: .utf8)
    chmod(executable.path, 0o700)
    return executable
}

private func makeCountingExitExecutable(marker: URL) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-service-exit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let executable = directory.appendingPathComponent("counting-exit.sh")
    try "#!/bin/sh\nprintf 'start\\n' >> \"\(marker.path)\"\nexit 0\n"
        .write(to: executable, atomically: true, encoding: .utf8)
    chmod(executable.path, 0o700)
    return executable
}

private func makeWriterBusyExitExecutable() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-service-writer-busy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let executable = directory.appendingPathComponent("writer-busy.sh")
    try "#!/bin/sh\necho 'EngramService: another instance owns the writer lock; exiting.' >&2\nexit 0\n"
        .write(to: executable, atomically: true, encoding: .utf8)
    chmod(executable.path, 0o700)
    return executable
}

private func makeNoisyExecutable(marker: URL) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-service-noisy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let executable = directory.appendingPathComponent("noisy.sh")
    // ~128KB of stdout (> typical 64KB pipe) so drain must run or we block before touch.
    // Keep volume modest: logging every chunk via os_log under xctest is expensive.
    try """
    #!/bin/sh
    i=0
    while [ "$i" -lt 800 ]; do
      printf '%0200d\\n' "$i"
      i=$((i + 1))
    done
    touch "\(marker.path)"
    sleep 5
    """.write(to: executable, atomically: true, encoding: .utf8)
    chmod(executable.path, 0o700)
    return executable
}
