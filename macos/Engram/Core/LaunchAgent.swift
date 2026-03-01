// macos/Engram/Core/LaunchAgent.swift
import Foundation
import ServiceManagement

enum LaunchAgent {
    @available(macOS 13.0, *)
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else       { try SMAppService.mainApp.unregister() }
            } catch {
                print("LaunchAgent error:", error)
            }
        } else {
            setLegacy(enabled)
        }
    }

    private static func setLegacy(_ enabled: Bool) {
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.engram.app.plist")
        if !enabled {
            try? FileManager.default.removeItem(at: plistURL)
            return
        }
        guard let exe = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label":            "com.engram.app",
            "ProgramArguments": [exe],
            "RunAtLoad":        true,
            "KeepAlive":        false,
        ]
        let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try? data?.write(to: plistURL)
    }
}
