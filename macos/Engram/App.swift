// macos/Engram/App.swift
import SwiftUI

@main
struct EngramApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(appDelegate.db)
                .environment(appDelegate.serviceStatusStore)
                .environment(appDelegate.serviceClient)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let environment: AppEnvironment
    let db: DatabaseManager
    let serviceStatusStore: EngramServiceStatusStore
    let serviceClient: EngramServiceClient
    let serviceLauncher: EngramServiceLauncher
    private var serviceStatusTask: Task<Void, Never>?
    private var menuBarController: MenuBarController?
    private var onboardingWindow: NSWindow?
    private var popoverWindow: NSWindow?

    override init() {
        self.environment = AppEnvironment.fromCommandLine()
        self.db = DatabaseManager(path: environment.dbPath)
        self.serviceStatusStore = EngramServiceStatusStore()
        self.serviceClient = EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(socketPath: environment.serviceSocketPath)
        )
        self.serviceLauncher = EngramServiceLauncher()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One-time: migrate plaintext API keys from settings.json to Keychain
        migrateKeysToKeychainIfNeeded()

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
            let savedTheme = UserDefaults.standard.string(forKey: "appTheme") ?? "system"
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
            serviceStatusStore.apply(.starting)
            do {
                let serviceConfiguration = environment.serviceLaunchConfiguration()
                try serviceLauncher.start(configuration: serviceConfiguration)
                startServiceStatusObservation()
                serviceLauncher.startHealthMonitor(
                    configuration: serviceConfiguration,
                    statusProbe: { [serviceClient] in
                        try await serviceClient.status()
                    },
                    onStatus: { [serviceStatusStore] status in
                        serviceStatusStore.apply(status)
                    }
                )
            } catch {
                serviceStatusStore.apply(.error(message: error.localizedDescription))
                EngramLogger.error("EngramService launch failed", module: .daemon, error: error)
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
            window.contentView = NSHostingView(rootView: PopoverView()
                .environment(db)
                .environment(serviceStatusStore)
                .environment(serviceClient))
            window.title = "Popover Preview"
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
                windowSize: environment.windowSize
            )

            // In test mode with a window size, auto-open the main window so UI tests can find the sidebar
            if environment.windowSize != nil {
                menuBarController?.openWindow()
            }
        }

        // First-run onboarding (skip in test mode)
        let isTestMode = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || !environment.autoStartService
        if !isTestMode {
            if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
                showOnboarding()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            menuBarController?.openWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        serviceStatusTask?.cancel()
        serviceLauncher.stopIfOwned()
        Task.detached { [serviceClient] in
            await serviceClient.close()
        }
    }

    private func startServiceStatusObservation() {
        serviceStatusTask?.cancel()
        serviceStatusTask = Task { [serviceClient, serviceStatusStore] in
            do {
                let status = try await serviceClient.status()
                await MainActor.run {
                    serviceStatusStore.apply(status)
                }
            } catch {
                await MainActor.run {
                    serviceStatusStore.apply(.error(message: error.localizedDescription))
                }
                return
            }

            do {
                for try await event in serviceClient.events() {
                    await MainActor.run {
                        serviceStatusStore.apply(event)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    serviceStatusStore.apply(.degraded(message: error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        let onboardingView = OnboardingView {
            self.completeOnboarding()
        }
        let hostingController = NSHostingController(rootView: onboardingView)

        let win = NSWindow(contentViewController: hostingController)
        win.title = "Welcome to Engram"
        win.setContentSize(NSSize(width: 460, height: 380))
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.center()

        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.onboardingWindow = win
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        onboardingWindow?.close()
        onboardingWindow = nil

        // Revert to accessory mode, then open the main window
        NSApp.setActivationPolicy(.accessory)
        menuBarController?.openWindow()
    }
}
