import Darwin
import XCTest
@testable import Engram

private final class LockedPersistenceHistory<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    func snapshot() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class AISettingsSectionTests: XCTestCase {
    private var macOSRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testAISettingsSaveIsDebounced_repro() throws {
        let source = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Views/Settings/AISettingsSection.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("settingsSaveDebounceNanoseconds"))
        XCTAssertTrue(source.contains("scheduleSaveAISettings"))
        XCTAssertFalse(source.contains(".onChange(of: aiBaseURL) { saveAISettings() }"))
        XCTAssertTrue(source.contains(".onChange(of: aiBaseURL) { scheduleSaveAISettings() }"))
        XCTAssertGreaterThanOrEqual(AISettingsSection.settingsSaveDebounceNanoseconds, 100_000_000)
    }

    /// R9/M21 residual: leave before debounce fires must flush pending saves.
    func testAISettingsFlushesPendingSavesOnDisappear_repro() throws {
        let source = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Views/Settings/AISettingsSection.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(".onDisappear { flushPendingAISettingsSaves() }"))
        XCTAssertTrue(source.contains("await AISettingsPersister.waitForPendingPersistence()"))
        XCTAssertTrue(source.contains("func flushPendingAISettingsSaves()"))
        XCTAssertTrue(source.contains("AISettingsSaveFlush.shouldFlush"))
        XCTAssertTrue(AISettingsSaveFlush.shouldFlush(pendingTask: true, isLoadingSettings: false))
        XCTAssertFalse(AISettingsSaveFlush.shouldFlush(pendingTask: false, isLoadingSettings: false))
        XCTAssertFalse(AISettingsSaveFlush.shouldFlush(pendingTask: true, isLoadingSettings: true))
        XCTAssertTrue(source.contains("saveAISettings(commitFocusedEmpty: false)"))
        XCTAssertTrue(source.contains("saveTitleSettings(commitFocusedEmpty: false)"))
    }

    func testEmptyAPIKeySnapshotsPreserveUntilExplicitClear_repro() throws {
        XCTAssertEqual(APIKeyEditAction.decide(apiKey: "", preserveEmptyAPIKey: true), .preserveExisting)
        XCTAssertEqual(APIKeyEditAction.decide(apiKey: "", preserveEmptyAPIKey: false), .deleteExisting)
        XCTAssertEqual(APIKeyEditAction.decide(apiKey: " replacement ", preserveEmptyAPIKey: true), .write("replacement"))

        let source = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Views/Settings/AISettingsSection.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("case .preserveExisting:"))
        XCTAssertTrue(source.contains("Button(\"Clear\")"))
    }

    /// R9: debounce/flush snapshot on MainActor, persist Keychain + settings.json off-main.
    func testAISettingsPersistsKeychainAndFileOffMain_repro() throws {
        let source = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Views/Settings/AISettingsSection.swift"),
            encoding: .utf8
        )
        let saveStart = try XCTUnwrap(source.range(of: "private func saveAISettings("))
        let saveEnd = try XCTUnwrap(
            source.range(of: "private func saveTitleSettings(", range: saveStart.lowerBound..<source.endIndex)
        )
        let saveBody = String(source[saveStart.lowerBound..<saveEnd.lowerBound])
        XCTAssertTrue(saveBody.contains("AISettingsPersister.persistAIOffMain"))
        XCTAssertFalse(saveBody.contains("KeychainHelper.set"))
        XCTAssertFalse(saveBody.contains("mutateEngramSettings"))

        let persistStart = try XCTUnwrap(source.range(of: "static func persistAIOffMain"))
        let persistEnd = try XCTUnwrap(
            source.range(of: "static func persistTitleOffMain", range: persistStart.lowerBound..<source.endIndex)
        )
        let persistOffMain = String(source[persistStart.lowerBound..<persistEnd.lowerBound])
        XCTAssertTrue(persistOffMain.contains("Task.detached"))

        let mailboxStart = try XCTUnwrap(source.range(of: "func persistAI("))
        let mailboxEnd = try XCTUnwrap(
            source.range(of: "func persistTitle(", range: mailboxStart.lowerBound..<source.endIndex)
        )
        let mailboxBody = String(source[mailboxStart.lowerBound..<mailboxEnd.lowerBound])
        XCTAssertTrue(mailboxBody.contains("applyAPIKey"))
        XCTAssertTrue(mailboxBody.contains("mutateEngramSettings"))
    }

    /// concurrency-5: appear-load must not read settings.json or Keychain on MainActor.
    func testAISettingsAppearLoadRunsBlockingIOOffMain_repro() throws {
        let source = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Views/Settings/AISettingsSection.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(".task { await loadAISettings() }"))
        XCTAssertFalse(source.contains(".onAppear { loadAISettings() }"))

        let loadStart = try XCTUnwrap(source.range(of: "private func loadAISettings() async"))
        let loadEnd = try XCTUnwrap(
            source.range(of: "private func clearLoadingSettingsAfterViewUpdate", range: loadStart.lowerBound..<source.endIndex)
        )
        let loadBody = String(source[loadStart.lowerBound..<loadEnd.lowerBound])
        XCTAssertTrue(loadBody.contains("await AISettingsLoader.loadOffMain()"))
        XCTAssertFalse(loadBody.contains("readEngramSettings()"))
        XCTAssertFalse(loadBody.contains("KeychainHelper.get"))

        let loaderStart = try XCTUnwrap(source.range(of: "enum AISettingsLoader"))
        let loaderBody = String(source[loaderStart.lowerBound...])
        XCTAssertTrue(loaderBody.contains("Task.detached"))
        XCTAssertTrue(loaderBody.contains("readEngramSettingsData()"))
        XCTAssertTrue(loaderBody.contains("KeychainHelper.get"))
    }

    @MainActor
    func testAISettingsNewestSubmissionWinsWhenDetachedArrivalInverts_repro() async {
        let history = LockedPersistenceHistory<String>()
        let hooks = AISettingsPersistenceHooks(
            beforeMailbox: { snapshot in
                if snapshot.aiModel == "older" {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            },
            persist: { snapshot in
                history.append(snapshot.aiModel)
                return .saved
            }
        )

        AISettingsPersister.persistAIOffMain(
            aiSnapshot(model: "older"),
            serviceSocketPath: "/tmp/engram-ai-settings-tests.sock",
            testHooks: hooks,
            onAPIKeyResult: { _ in }
        )
        AISettingsPersister.persistAIOffMain(
            aiSnapshot(model: "newer"),
            serviceSocketPath: "/tmp/engram-ai-settings-tests.sock",
            testHooks: hooks,
            onAPIKeyResult: { _ in }
        )

        let completed = await waitForCount(2, in: history)
        XCTAssertTrue(completed)
        XCTAssertEqual(history.snapshot().last, "newer")
    }

    @MainActor
    func testTitleSettingsNewestSubmissionWinsWhenDetachedArrivalInverts_repro() async {
        let history = LockedPersistenceHistory<String>()
        let hooks = TitleSettingsPersistenceHooks(
            beforeMailbox: { snapshot in
                if snapshot.model == "older" {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            },
            persist: { snapshot in
                history.append(snapshot.model)
                return .saved
            }
        )

        AISettingsPersister.persistTitleOffMain(
            titleSnapshot(model: "older"),
            serviceSocketPath: "/tmp/engram-ai-settings-tests.sock",
            testHooks: hooks,
            onAPIKeyResult: { _ in }
        )
        AISettingsPersister.persistTitleOffMain(
            titleSnapshot(model: "newer"),
            serviceSocketPath: "/tmp/engram-ai-settings-tests.sock",
            testHooks: hooks,
            onAPIKeyResult: { _ in }
        )

        let completed = await waitForCount(2, in: history)
        XCTAssertTrue(completed)
        XCTAssertEqual(history.snapshot().last, "newer")
    }

    /// M20: pure helper — invalid/empty free-text URLs must fail closed.
    func testParseConnectionURLRejectsInvalidAndEmpty_repro() {
        XCTAssertNil(AISettingsURLValidation.parseConnectionURL(""))
        XCTAssertNil(AISettingsURLValidation.parseConnectionURL("   "))
        XCTAssertNil(AISettingsURLValidation.parseConnectionURL(" not a url"))
        XCTAssertNil(AISettingsURLValidation.parseConnectionURL("localhost:11434"))
        XCTAssertNil(AISettingsURLValidation.parseConnectionURL("http://"))
        XCTAssertNil(AISettingsURLValidation.parseConnectionURL("file:///tmp/x"))
        // Leading space after trim OK if still valid absolute URL
        let ok = AISettingsURLValidation.parseConnectionURL("  http://localhost:11434  ")
        XCTAssertEqual(ok?.scheme, "http")
        XCTAssertEqual(ok?.host, "localhost")
        XCTAssertEqual(ok?.port, 11434)
        let https = AISettingsURLValidation.parseConnectionURL("https://api.example.com/v1")
        XCTAssertEqual(https?.host, "api.example.com")
    }

    /// M20: Test Connection path must call the pure helper (not force-unwrap).
    func testTestConnectionUsesParseConnectionURLHelper_repro() throws {
        let source = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Views/Settings/AISettingsSection.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("AISettingsURLValidation.parseConnectionURL(testURL)"))
        XCTAssertFalse(source.contains("URLRequest(url: URL(string: testURL)!)"))
    }

    func testMarkerLoadedEmptyAPIKeyIsPreserved_repro() {
        var settings: [String: Any] = ["aiApiKey": "@keychain"]
        var deleted = false

        let result = APIKeyPersistencePolicy.apply(
            settingsKey: "aiApiKey",
            value: "",
            preserveEmptyValue: true,
            saveToKeychain: { _ in false },
            deleteFromKeychain: { deleted = true },
            allowsPlaintextFallback: false,
            mutateSettings: { transform in transform(&settings); return true }
        )

        XCTAssertEqual(result, .unchanged)
        XCTAssertFalse(deleted)
        XCTAssertEqual(settings["aiApiKey"] as? String, "@keychain")
    }

    func testInvalidSettingsFileIsNotReplacedBySnapshotMutation_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-invalid-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("settings.json")
        let original = Data(#"{"aiApiKey":"plaintext-secret""#.utf8)
        try original.write(to: file)

        mutateEngramSettingsIfNeeded(at: file) { settings in
            settings["aiModel"] = "must-not-replace-invalid-json"
            return true
        }

        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testSettingsReadAndMigrationRefuseSymlinkWithoutTouchingTarget_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-linked-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("outside.json")
        let linked = root.appendingPathComponent("settings.json")
        let original = Data(#"{"aiApiKey":"plaintext-secret"}"#.utf8)
        try original.write(to: target)
        chmod(target.path, 0o644)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)

        XCTAssertNil(readEngramSettingsData(at: linked))
        migrateKeysToKeychainIfNeeded(at: linked)

        var info = stat()
        XCTAssertEqual(lstat(target.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o644)
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testSettingsReadAndMigrationRefuseFIFOWithoutBlocking_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-fifo-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fifo = root.appendingPathComponent("settings.json")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)

        let started = Date()
        XCTAssertNil(readEngramSettingsData(at: fifo))
        migrateKeysToKeychainIfNeeded(at: fifo)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testMissingSettingsDoesNotDeleteUnavailableAPIKey_repro() {
        let loaded = APIKeyLoadedState.resolve(keychainValue: nil, storedValue: nil)
        XCTAssertEqual(loaded.value, "")
        XCTAssertTrue(loaded.preserveEmptyValue)

        var deleted = false
        var settings: [String: Any] = [:]
        let result = APIKeyPersistencePolicy.apply(
            settingsKey: "aiApiKey",
            value: loaded.value,
            preserveEmptyValue: loaded.preserveEmptyValue,
            saveToKeychain: { _ in false },
            deleteFromKeychain: { deleted = true },
            allowsPlaintextFallback: false,
            mutateSettings: { transform in transform(&settings); return true }
        )

        XCTAssertEqual(result, .unchanged)
        XCTAssertFalse(deleted)
    }

    func testLoadedPlaintextIsReportedAndUserEmptyDeleteIsCleared_repro() {
        let loaded = APIKeyLoadedState.resolve(keychainValue: nil, storedValue: "debug-secret")
        XCTAssertEqual(loaded.persistenceResult, .plaintext)

        var deleted = false
        var settings: [String: Any] = ["aiApiKey": "@keychain"]
        let result = APIKeyPersistencePolicy.apply(
            settingsKey: "aiApiKey",
            value: "",
            preserveEmptyValue: false,
            saveToKeychain: { _ in false },
            deleteFromKeychain: { deleted = true },
            allowsPlaintextFallback: false,
            mutateSettings: { transform in transform(&settings); return true }
        )
        XCTAssertEqual(result, .cleared)
        XCTAssertTrue(deleted)
        XCTAssertNil(settings["aiApiKey"])
    }

    func testFailedSettingsRMWDoesNotMutateKeychain_repro() {
        var saveCalls = 0
        var deleteCalls = 0

        let clearResult = APIKeyPersistencePolicy.apply(
            settingsKey: "aiApiKey",
            value: "",
            preserveEmptyValue: false,
            saveToKeychain: { _ in saveCalls += 1; return true },
            deleteFromKeychain: { deleteCalls += 1 },
            allowsPlaintextFallback: false,
            mutateSettings: { _ in false }
        )
        let saveResult = APIKeyPersistencePolicy.apply(
            settingsKey: "aiApiKey",
            value: "new-key",
            preserveEmptyValue: false,
            saveToKeychain: { _ in saveCalls += 1; return true },
            deleteFromKeychain: { deleteCalls += 1 },
            allowsPlaintextFallback: false,
            probeSettings: { false },
            mutateSettings: { _ in false }
        )

        XCTAssertEqual(clearResult, .failed)
        XCTAssertEqual(saveResult, .failed)
        XCTAssertEqual(deleteCalls, 0)
        XCTAssertEqual(saveCalls, 0)
    }

    func testFocusedEmptyAPIKeyDefersDeleteUntilBlurOrExplicitFlush_repro() {
        XCTAssertTrue(
            APIKeyFocusedEmptyPolicy.shouldPreserve(
                value: "",
                isFocused: true,
                commitFocusedEmpty: false
            )
        )
        XCTAssertTrue(
            APIKeyFocusedEmptyPolicy.shouldPreserve(
                value: "",
                isFocused: false,
                commitFocusedEmpty: false
            )
        )
        XCTAssertFalse(
            APIKeyFocusedEmptyPolicy.shouldPreserve(
                value: "",
                isFocused: true,
                commitFocusedEmpty: true
            )
        )
        XCTAssertFalse(
            APIKeyFocusedEmptyPolicy.shouldPreserve(
                value: "replacement",
                isFocused: true,
                commitFocusedEmpty: false
            )
        )
        XCTAssertTrue(
            APIKeyFocusedEmptyPolicy.shouldPreserve(
                value: " \n\t ",
                isFocused: true,
                commitFocusedEmpty: false
            )
        )
    }

    func testModelOnlySnapshotDoesNotApplyLoadedAPIKey_repro() {
        XCTAssertEqual(
            APIKeyEditAction.decide(
                apiKey: "previous-secret",
                preserveEmptyAPIKey: false,
                applyAPIKey: false
            ),
            .preserveExisting
        )
        XCTAssertEqual(
            TitleAPIKeyPersistenceAction.decide(
                provider: "openai",
                apiKey: "previous-secret",
                preserveEmptyAPIKey: false,
                applyAPIKey: false
            ),
            .preserveExisting
        )
    }

    @MainActor
    func testLoadCanAwaitPendingPersistenceTail_repro() async {
        let history = LockedPersistenceHistory<String>()
        let hooks = AISettingsPersistenceHooks(
            beforeMailbox: { _ in
                try? await Task.sleep(nanoseconds: 150_000_000)
            },
            persist: { snapshot in
                history.append(snapshot.aiModel)
                return .saved
            }
        )

        AISettingsPersister.persistAIOffMain(
            aiSnapshot(model: "must-finish-before-load"),
            serviceSocketPath: "/tmp/engram-ai-settings-tests.sock",
            testHooks: hooks,
            onAPIKeyResult: { _ in }
        )
        await AISettingsPersister.waitForPendingPersistence()

        XCTAssertEqual(history.snapshot(), ["must-finish-before-load"])
    }

    func testReleaseKeychainFailureDoesNotMaterializeMissingSettings_repro() {
        var probeCalls = 0
        var mutationCalls = 0

        let result = APIKeyPersistencePolicy.apply(
            settingsKey: "aiApiKey",
            value: "new-secret",
            preserveEmptyValue: false,
            saveToKeychain: { _ in false },
            deleteFromKeychain: {},
            allowsPlaintextFallback: false,
            probeSettings: {
                probeCalls += 1
                return true
            },
            mutateSettings: { _ in
                mutationCalls += 1
                return true
            }
        )

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(probeCalls, 1)
        XCTAssertEqual(mutationCalls, 0)
    }

    func testMissingSettingsReadabilityProbeDoesNotCreateFile_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-api-key-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")

        let result = APIKeyPersistencePolicy.apply(
            settingsKey: "aiApiKey",
            value: "new-secret",
            preserveEmptyValue: false,
            saveToKeychain: { _ in false },
            deleteFromKeychain: {},
            allowsPlaintextFallback: false,
            probeSettings: { probeEngramSettingsForMutation(at: file) },
            mutateSettings: { transform in
                mutateEngramSettingsIfNeeded(at: file) { settings in
                    transform(&settings)
                    return true
                }
            }
        )

        XCTAssertEqual(result, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testFailedAPIKeyApplyBlocksRemainingSnapshotPersistence_repro() {
        XCTAssertFalse(APIKeyPersistenceResult.failed.permitsSettingsSnapshotPersistence)
        XCTAssertTrue(APIKeyPersistenceResult.saved.permitsSettingsSnapshotPersistence)
        XCTAssertTrue(APIKeyPersistenceResult.unchanged.permitsSettingsSnapshotPersistence)
    }

    func testAPIKeyEditStateWaitsForMatchingSuccessfulApply_repro() {
        XCTAssertFalse(
            APIKeyEditCompletion.shouldClearEdited(
                result: .failed,
                submittedValue: "replacement",
                currentValue: "replacement"
            )
        )
        XCTAssertFalse(
            APIKeyEditCompletion.shouldClearEdited(
                result: .saved,
                submittedValue: "older",
                currentValue: "newer"
            )
        )
        XCTAssertTrue(
            APIKeyEditCompletion.shouldClearEdited(
                result: .saved,
                submittedValue: "replacement",
                currentValue: "replacement"
            )
        )
    }

    func testNonKeySnapshotCannotReplaceLastAPIKeyApplyCaption_repro() throws {
        let source = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Views/Settings/AISettingsSection.swift"),
            encoding: .utf8
        )
        let aiStart = try XCTUnwrap(source.range(of: "private func saveAISettings("))
        let titleStart = try XCTUnwrap(
            source.range(of: "private func saveTitleSettings(", range: aiStart.lowerBound..<source.endIndex)
        )
        let loadStart = try XCTUnwrap(
            source.range(of: "private func loadAISettings()", range: titleStart.lowerBound..<source.endIndex)
        )
        let aiBody = String(source[aiStart.lowerBound..<titleStart.lowerBound])
        let titleBody = String(source[titleStart.lowerBound..<loadStart.lowerBound])

        XCTAssertTrue(aiBody.contains("guard applyAPIKey, result.isRealKeyApply else { return }"))
        XCTAssertTrue(titleBody.contains("guard applyAPIKey, result.isRealKeyApply else { return }"))
        XCTAssertFalse(aiBody.contains("if applyAPIKey {\n            aiAPIKeyWasEdited = false"))
        XCTAssertFalse(titleBody.contains("if applyAPIKey {\n            titleAPIKeyWasEdited = false"))
    }

    func testKeychainSuccessWithMarkerFailureRemainsRefreshable_repro() {
        var settings: [String: Any] = [:]
        var saveCalls = 0

        let result = APIKeyPersistencePolicy.apply(
            settingsKey: "aiApiKey",
            value: "new-secret",
            preserveEmptyValue: false,
            saveToKeychain: { _ in saveCalls += 1; return true },
            deleteFromKeychain: {},
            allowsPlaintextFallback: false,
            mutateSettings: { transform in
                transform(&settings)
                return false
            }
        )

        XCTAssertEqual(result, .savedMarkerFailed)
        XCTAssertTrue(result.changedKeychain)
        XCTAssertFalse(result.permitsSettingsSnapshotPersistence)
        XCTAssertEqual(saveCalls, 1)
    }

    func testRuntimeSecretRefreshDoesNotMaskMarkerWriteFailure_repro() throws {
        let source = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Views/Settings/AISettingsSection.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("if result == .savedMarkerFailed, bridgeWritten { result = .saved }"))
    }

    func testRuntimeBridgeFailureDoesNotReportSavedOrCleared_repro() throws {
        let source = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Views/Settings/AISettingsSection.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("case runtimeBridgeRefreshFailed"))
        XCTAssertTrue(source.contains("func reconcilingRuntimeBridgeRefresh"))

        let persistAIStart = try XCTUnwrap(source.range(of: "func persistAI("))
        let persistAIEnd = try XCTUnwrap(
            source.range(of: "func persistTitle(", range: persistAIStart.upperBound..<source.endIndex)
        )
        let persistAI = String(source[persistAIStart.lowerBound..<persistAIEnd.lowerBound])
        XCTAssertFalse(persistAI.contains("_ = refreshRuntimeAISecrets"), persistAI)
        XCTAssertTrue(persistAI.contains("reconcilingRuntimeBridgeRefresh"), persistAI)

        let persistTitleStart = persistAIEnd
        let persistTitleEnd = try XCTUnwrap(
            source.range(of: "private func applyAPIKey", range: persistTitleStart.upperBound..<source.endIndex)
        )
        let persistTitle = String(source[persistTitleStart.lowerBound..<persistTitleEnd.lowerBound])
        XCTAssertFalse(persistTitle.contains("_ = refreshRuntimeAISecrets"), persistTitle)
        XCTAssertTrue(persistTitle.contains("reconcilingRuntimeBridgeRefresh"), persistTitle)

        var refreshCalls = 0
        XCTAssertEqual(
            APIKeyPersistenceResult.saved.reconcilingRuntimeBridgeRefresh {
                refreshCalls += 1
                return false
            },
            .runtimeBridgeRefreshFailed
        )
        XCTAssertEqual(
            APIKeyPersistenceResult.cleared.reconcilingRuntimeBridgeRefresh {
                refreshCalls += 1
                return false
            },
            .runtimeBridgeRefreshFailed
        )
        XCTAssertEqual(refreshCalls, 2)
        XCTAssertTrue(APIKeyPersistenceResult.runtimeBridgeRefreshFailed.permitsSettingsSnapshotPersistence)
    }

    func testRuntimeSecretRefreshUsesInjectedAppSocket_repro() throws {
        let app = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/App.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Views/SettingsView.swift"),
            encoding: .utf8
        )
        let menuBar = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/MenuBarController.swift"),
            encoding: .utf8
        )
        let mainWindow = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Views/MainWindowView.swift"),
            encoding: .utf8
        )
        let ai = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Views/Settings/AISettingsSection.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(app.contains("SettingsView(serviceSocketPath: appDelegate.environment.serviceSocketPath)"))
        XCTAssertTrue(app.contains("serviceSocketPath: environment.serviceSocketPath"))
        XCTAssertTrue(settings.contains("AISettingsSection(serviceSocketPath: serviceSocketPath)"))
        XCTAssertTrue(menuBar.contains("private let serviceSocketPath: String"))
        XCTAssertGreaterThanOrEqual(
            menuBar.components(separatedBy: "SettingsView(serviceSocketPath: serviceSocketPath)").count - 1,
            1
        )
        XCTAssertTrue(menuBar.contains("serviceSocketPath: serviceSocketPath"))
        XCTAssertTrue(mainWindow.contains("let serviceSocketPath: String"))
        XCTAssertTrue(mainWindow.contains("SettingsView(serviceSocketPath: serviceSocketPath)"))
        XCTAssertTrue(ai.contains("serviceSocketPath: serviceSocketPath"))
        XCTAssertFalse(settings.contains("serviceSocketPath: String ="))
        XCTAssertFalse(ai.contains("serviceSocketPath: String ="))
        XCTAssertFalse(menuBar.contains("defaultSocketPath"))
        XCTAssertFalse(mainWindow.contains("defaultSocketPath"))

        let refreshStart = try XCTUnwrap(ai.range(of: "private func refreshRuntimeAISecrets("))
        let refreshEnd = try XCTUnwrap(ai.range(of: "\n        }\n    }", range: refreshStart.upperBound..<ai.endIndex))
        let refresh = String(ai[refreshStart.lowerBound..<refreshEnd.upperBound])
        XCTAssertTrue(refresh.contains("forSocketPath: serviceSocketPath"), refresh)
        XCTAssertFalse(refresh.contains("defaultSocketPath()"), refresh)
    }

    func testMarkerFailureStillAttemptsRuntimeBridgeRefresh_repro() throws {
        let source = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Views/Settings/AISettingsSection.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(APIKeyPersistenceResult.savedMarkerFailed.changedKeychain)
        XCTAssertTrue(source.contains("result = result.reconcilingRuntimeBridgeRefresh"))

        var refreshCalls = 0
        let result = APIKeyPersistenceResult.savedMarkerFailed.reconcilingRuntimeBridgeRefresh {
            refreshCalls += 1
            return false
        }
        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(result, .savedMarkerFailed)
    }

    func testEmptyDeleteVerifiesKeychainRemovalBeforeReportingCleared_repro() {
        var settings: [String: Any] = ["aiApiKey": "@keychain"]
        let storedValue: String? = "still-present"

        let result = APIKeyPersistencePolicy.apply(
            settingsKey: "aiApiKey",
            value: "",
            preserveEmptyValue: false,
            saveToKeychain: { _ in false },
            deleteFromKeychain: {},
            keychainReader: { storedValue },
            allowsPlaintextFallback: false,
            mutateSettings: { transform in transform(&settings); return true }
        )

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(settings["aiApiKey"] as? String, "@keychain")
        XCTAssertEqual(storedValue, "still-present")
    }

    func testKeychainMarkerWriteRetriesBeforeReportingFailure_repro() {
        var settings: [String: Any] = [:]
        var mutationCalls = 0

        let result = APIKeyPersistencePolicy.apply(
            settingsKey: "aiApiKey",
            value: "new-secret",
            preserveEmptyValue: false,
            saveToKeychain: { _ in true },
            deleteFromKeychain: {},
            allowsPlaintextFallback: false,
            mutateSettings: { transform in
                mutationCalls += 1
                transform(&settings)
                return mutationCalls >= 2
            }
        )

        XCTAssertEqual(result, .saved)
        XCTAssertEqual(mutationCalls, 2)
        XCTAssertEqual(settings["aiApiKey"] as? String, "@keychain")
    }

    func testEmptyPreserveIsCaptionNoopAndFailedApplyBlocksSnapshot_repro() {
        XCTAssertFalse(APIKeyPersistenceResult.unchanged.isRealKeyApply)
        XCTAssertTrue(APIKeyPersistenceResult.failed.isRealKeyApply)
        XCTAssertFalse(
            APIKeySnapshotPersistenceGate.permitsSnapshot(
                wasBlockedByFailedApply: true,
                action: .preserveExisting,
                result: .unchanged
            )
        )
        XCTAssertTrue(
            APIKeySnapshotPersistenceGate.permitsSnapshot(
                wasBlockedByFailedApply: true,
                action: .write("retry"),
                result: .saved
            )
        )
    }

    func testMarkerLoadedEmptyTitleAPIKeyIsPreserved_repro() {
        XCTAssertEqual(
            TitleAPIKeyPersistenceAction.decide(
                provider: "openai",
                apiKey: "",
                preserveEmptyAPIKey: true
            ),
            .preserveExisting
        )
    }

    func testKeychainFailureReportsFailureWithoutInventingMarker_repro() {
        var settings: [String: Any] = ["aiApiKey": "previous"]

        let result = APIKeyPersistencePolicy.apply(
            settingsKey: "aiApiKey",
            value: "new-secret",
            preserveEmptyValue: false,
            saveToKeychain: { _ in false },
            deleteFromKeychain: {},
            allowsPlaintextFallback: false,
            mutateSettings: { transform in transform(&settings); return true }
        )

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(settings["aiApiKey"] as? String, "previous")
    }

    func testDebugPlaintextFallbackIsReportedHonestly_repro() {
        var settings: [String: Any] = [:]

        let result = APIKeyPersistencePolicy.apply(
            settingsKey: "aiApiKey",
            value: "debug-secret",
            preserveEmptyValue: false,
            saveToKeychain: { _ in false },
            deleteFromKeychain: {},
            allowsPlaintextFallback: true,
            mutateSettings: { transform in transform(&settings); return true }
        )

        XCTAssertEqual(result, .plaintext)
        XCTAssertEqual(settings["aiApiKey"] as? String, "debug-secret")
    }

    func testSettingsLoadGenerationGatesPostLoadOnChange_repro() throws {
        let source = try String(
            contentsOf: macOSRoot.appendingPathComponent("Engram/Views/Settings/AISettingsSection.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func clearLoadingSettingsAfterViewUpdate(generation:"))
        let end = try XCTUnwrap(
            source.range(of: "private func appendAPIPath", range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("Task.yield()"))
        XCTAssertTrue(body.contains("generation == settingsLoadGeneration"))
        XCTAssertFalse(body.contains("Task.sleep"))
        XCTAssertTrue(source.contains(".disabled(!settingsLoadApplied)"))
    }

    private func aiSnapshot(model: String) -> AISettingsPersistSnapshot {
        AISettingsPersistSnapshot(
            apiKey: "",
            preserveEmptyAPIKey: false,
            applyAPIKey: true,
            aiProtocol: "openai",
            aiBaseURL: "",
            aiModel: model,
            summaryLanguage: "auto",
            summaryMaxSentences: 3,
            summaryStyle: "",
            summaryPrompt: "",
            summaryPreset: "balanced",
            summaryMaxTokens: 300,
            summaryTemperature: 0.3,
            summarySampleFirst: 3,
            summarySampleLast: 3,
            summaryTruncateChars: 12_000
        )
    }

    private func titleSnapshot(model: String) -> TitleSettingsPersistSnapshot {
        TitleSettingsPersistSnapshot(
            provider: "openai",
            apiKey: "",
            preserveEmptyAPIKey: false,
            applyAPIKey: true,
            baseURL: "",
            model: model
        )
    }

    private func waitForCount<Value>(
        _ count: Int,
        in history: LockedPersistenceHistory<Value>
    ) async -> Bool where Value: Sendable {
        for _ in 0..<100 {
            if history.snapshot().count >= count { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return history.snapshot().count >= count
    }
}
