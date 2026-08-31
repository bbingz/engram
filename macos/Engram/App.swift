// macos/Engram/App.swift
import SwiftUI

private struct EngramServiceClientEnvironmentKey: EnvironmentKey {
    static let defaultValue: any EngramServiceClientProtocol = EngramServiceClient(
        transport: UnixSocketEngramServiceTransport(
            socketPath: UnixSocketEngramServiceTransport.defaultSocketPath()
        )
    )
}

extension EnvironmentValues {
    var engramServiceClient: any EngramServiceClientProtocol {
        get { self[EngramServiceClientEnvironmentKey.self] }
        set { self[EngramServiceClientEnvironmentKey.self] = newValue }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .english:
            return Locale(identifier: "en")
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .system:
            return "System"
        case .english:
            return "English"
        case .simplifiedChinese:
            return "Simplified Chinese"
        }
    }

    static func resolved(from rawValue: String) -> AppLanguage {
        AppLanguage(rawValue: rawValue) ?? .system
    }
}

struct LocalizedRoot<Content: View>: View {
    @AppStorage("appLanguage") private var appLanguage: String = AppLanguage.system.rawValue
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.locale, AppLanguage.resolved(from: appLanguage).locale)
    }
}

@main
struct EngramApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            LocalizedRoot {
                SettingsView()
                    .environment(appDelegate.db)
                    .environment(appDelegate.serviceStatusStore)
                    .environment(\.engramServiceClient, appDelegate.serviceClient)
            }
            .defaultAppStorage(appDelegate.appStorage)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let environment: AppEnvironment
    let db: DatabaseManager
    let serviceStatusStore: EngramServiceStatusStore
    let serviceClient: any EngramServiceClientProtocol
    let serviceLauncher: EngramServiceLauncher
    let appStorage: UserDefaults
    private var restartObserverToken: NSObjectProtocol?
    private var showOnboardingObserverToken: NSObjectProtocol?
    private var menuBarController: MenuBarController?
    private var onboardingWindow: NSWindow?
    private var popoverWindow: NSWindow?

    override init() {
        self.environment = AppEnvironment.fromCommandLine()
        self.appStorage = Self.makeAppStorage(
            isTestMode: environment.isTestMode,
            environment: ProcessInfo.processInfo.environment
        )
        self.db = DatabaseManager(path: environment.dbPath)
        self.serviceStatusStore = EngramServiceStatusStore()
        self.serviceClient = Self.makeServiceClient(for: environment)
        self.serviceLauncher = EngramServiceLauncher()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !environment.isTestMode {
            // Invariant 6: UI tests must not mutate production settings or Keychain state.
            // One-time: migrate plaintext API keys from settings.json to Keychain
            migrateKeysToKeychainIfNeeded()
            // One-time: scrub settings + Keychain entries for removed features (e.g. Viking)
            removeDeprecatedSettingsKeysIfNeeded()
        }

        // Row 16: opt-in main-thread stall monitor (DEBUG only; no-ops without
        // ENGRAM_PERF_MONITOR). Release has no MainThreadStallMonitor type.
        #if DEBUG
        MainThreadStallMonitor.shared.start()
        #endif

        // Hide from Dock — menu bar only (keep .regular for test/popover so XCUITest can see the window)
        if environment.popoverStandalone || environment.windowSize != nil {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }

        // Appearance override for screenshot tests
        if let idx = CommandLine.arguments.firstIndex(of: "--appearance"),
           CommandLine.arguments.indices.contains(idx + 1) {
            let name: NSAppearance.Name = CommandLine.arguments[idx + 1] == "dark"
                ? .darkAqua : .aqua
            NSApp.appearance = NSAppearance(named: name)
        } else {
            // Restore saved theme preference on launch
            let savedTheme = appStorage.string(forKey: "appTheme") ?? "system"
            switch savedTheme {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: NSApp.appearance = nil  // follow system
            }
        }

        // Open SQLite
        do {
            try db.open()
        } catch {
            EngramLogger.error("Database open failed", module: .database, error: error)
        }

        if environment.autoStartService {
            Task { @MainActor in
                let serviceConfiguration = environment.serviceLaunchConfiguration()
                await serviceLauncher.startOrAdopt(
                    configuration: serviceConfiguration,
                    statusProbe: { [serviceClient] in
                        try await serviceClient.status()
                    },
                    onStatus: { [serviceStatusStore] status in
                        serviceStatusStore.apply(status)
                    },
                    onEvent: { [serviceStatusStore] event in
                        Self.applyServiceEvent(event, to: serviceStatusStore)
                    }
                )
            }

            // One-click recovery: the HomeView Service State panel and the
            // menu-bar right-click menu post .restartService while
            // serviceStatusStore.isFailed. Gated on autoStartService so headless
            // test runs never spawn the helper.
            restartObserverToken = NotificationCenter.default.addObserver(
                forName: .restartService, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.restartService() }
            }
        }

        // Setup menu bar (or standalone popover window in test mode)
        if environment.popoverStandalone {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(rootView: LocalizedRoot {
                PopoverView()
                    .environment(db)
                    .environment(serviceStatusStore)
                    .environment(\.engramServiceClient, serviceClient)
            }.defaultAppStorage(appStorage))
            window.title = String(localized: "Popover Preview")
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.setContentSize(NSSize(width: 400, height: 600))
            window.styleMask.remove(.resizable)
            self.popoverWindow = window
        } else {
            menuBarController = MenuBarController(
                db: db,
                serviceStatusStore: serviceStatusStore,
                serviceClient: serviceClient,
                fixedDate: environment.fixedDate,
                windowSize: environment.windowSize,
                appStorage: appStorage,
                isTestMode: environment.isTestMode,
                hasOnboardingWindow: { [weak self] in self?.onboardingWindow != nil }
            )

            // In test mode with a window size, auto-open the main window so UI tests can find the sidebar
            if environment.windowSize != nil {
                menuBarController?.openWindow()
            }
        }

        // Help menu / context menu can re-open onboarding (row 17).
        showOnboardingObserverToken = NotificationCenter.default.addObserver(
            forName: .showOnboarding, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showOnboarding() }
        }

        // First-run onboarding (skip in test mode unless explicitly forced by UI tests)
        let isTestMode = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || !environment.autoStartService
        if environment.showOnboarding {
            showOnboarding()
        } else if !isTestMode {
            if !appStorage.bool(forKey: "hasCompletedOnboarding") {
                showOnboarding()
            }
        }
    }

    static func makeAppStorage(
        isTestMode: Bool,
        environment: [String: String],
        standard: UserDefaults = .standard
    ) -> UserDefaults {
        // Invariant 6: UI tests use a throwaway defaults suite so @AppStorage
        // interactions never mutate the installed app's preference domain.
        guard isTestMode,
              let suite = environment["ENGRAM_UI_TEST_DEFAULTS_SUITE"],
              !suite.isEmpty,
              let isolated = UserDefaults(suiteName: suite) else {
            return standard
        }
        return isolated
    }

    static func makeServiceClient(for environment: AppEnvironment) -> any EngramServiceClientProtocol {
        if environment.mockDaemon {
            return MockEngramServiceClient(
                searchResult: .failure(
                    EngramServiceError.serviceUnavailable(
                        message: "UI test mock search unavailable"
                    )
                ),
                liveSessionsResult: .failure(
                    EngramServiceError.serviceUnavailable(
                        message: "UI test mock live sessions unavailable"
                    )
                ),
                sourcesResult: .failure(
                    EngramServiceError.serviceUnavailable(
                        message: "UI test mock sources unavailable"
                    )
                ),
                memoryFilesResult: .failure(
                    EngramServiceError.serviceUnavailable(
                        message: "UI test mock memory files unavailable"
                    )
                ),
                insightsResult: .failure(
                    EngramServiceError.serviceUnavailable(
                        message: "UI test mock insights unavailable"
                    )
                )
            )
        }
        return EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(socketPath: environment.serviceSocketPath)
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            menuBarController?.openWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let restartObserverToken {
            NotificationCenter.default.removeObserver(restartObserverToken)
        }
        if let showOnboardingObserverToken {
            NotificationCenter.default.removeObserver(showOnboardingObserverToken)
        }
        serviceLauncher.stopIfOwned()
        serviceClient.close()
    }

    /// One-click recovery wrapper. Thin: flips the store to `.starting` for
    /// instant feedback, then delegates to the single restart sequencing point
    /// in `EngramServiceLauncher`. Reuses the exact closures built at first
    /// launch; does NOT re-implement the start+monitor sequence.
    @MainActor
    func restartService() {
        serviceStatusStore.apply(.starting)
        let serviceConfiguration = environment.serviceLaunchConfiguration()
        Task { @MainActor in
            await serviceLauncher.restart(
                configuration: serviceConfiguration,
                statusProbe: { [serviceClient] in
                    try await serviceClient.status()
                },
                onStatus: { [serviceStatusStore] status in
                    serviceStatusStore.apply(status)
                },
                onEvent: { [serviceStatusStore] event in
                    Self.applyServiceEvent(event, to: serviceStatusStore)
                }
            )
        }
    }

    /// OBS-O2: route service events through one place so `index_error` (which the
    /// shared `EngramServiceStatusStore.apply(event:)` does not handle — it falls
    /// to `default: break`) surfaces as a degraded status instead of vanishing.
    /// On a subsequent successful index (`indexed`/`ready`) the store's own
    /// handling restores `.running`, clearing the degraded state.
    @MainActor
    static func applyServiceEvent(_ event: EngramServiceEvent, to store: EngramServiceStatusStore) {
        if event.event == "index_error" {
            // The service emits the failure under the `error` key, not `message`.
            let detail = event.errorDetail ?? event.message ?? "indexing failed"
            store.apply(.degraded(message: "Last index scan failed: \(detail)"))
            return
        }
        store.apply(event)
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        if let onboardingWindow {
            NSApp.setActivationPolicy(.regular)
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let onboardingView = LocalizedRoot {
            OnboardingView {
                self.completeOnboarding()
            }
        }
        .defaultAppStorage(appStorage)
        let hostingController = NSHostingController(rootView: onboardingView)

        let win = NSWindow(contentViewController: hostingController)
        win.title = String(localized: "Welcome to Engram")
        win.setContentSize(NSSize(width: 460, height: 380))
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.center()
        // Row 7: any window dismissal records completion.
        win.delegate = self

        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.onboardingWindow = win
    }

    /// Single completion path for button, red close, and Cmd-W (row 7).
    private func completeOnboarding() {
        // Nil delegate before close so close→windowWillClose cannot re-enter.
        onboardingWindow?.delegate = nil
        appStorage.set(true, forKey: "hasCompletedOnboarding")
        onboardingWindow?.close()
        onboardingWindow = nil

        // Revert to accessory mode, then open the main window
        NSApp.setActivationPolicy(.accessory)
        menuBarController?.openWindow()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            guard (notification.object as? NSWindow) === self.onboardingWindow else { return }
            self.completeOnboarding()
        }
    }
}
