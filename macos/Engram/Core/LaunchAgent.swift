// macos/Engram/Core/LaunchAgent.swift
import Foundation
import ServiceManagement

enum LaunchAgent {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else       { try SMAppService.mainApp.unregister() }
        } catch {
            EngramLogger.error("LaunchAgent update failed", module: .ui, error: error)
        }
    }
}
