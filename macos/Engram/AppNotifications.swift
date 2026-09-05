import Foundation

extension Notification.Name {
    static let openSettings = Notification.Name("com.engram.openSettings")
    static let openWindow = Notification.Name("com.engram.openWindow")
    static let openSession = Notification.Name("com.engram.openSession")
    static let navigateToScreen = Notification.Name("com.engram.navigateToScreen")
    static let restartService = Notification.Name("com.engram.restartService")
    /// Opens first-run onboarding (Help menu / context menu).
    static let showOnboarding = Notification.Name("com.engram.showOnboarding")
}

@MainActor
enum SessionNavigationGate {
    private static var currentToken: UUID?

    static func begin() -> UUID {
        let token = UUID()
        currentToken = token
        return token
    }

    static func isCurrent(_ token: UUID) -> Bool {
        currentToken == token
    }

    static func complete(_ token: UUID) {
        if currentToken == token {
            currentToken = nil
        }
    }

    static func cancelAll() {
        currentToken = nil
    }
}

/// Box wrapper to safely pass Swift structs through `Notification.object`.
final class SessionBox {
    let session: Session
    let searchTerm: String?
    let navigationId: UUID?

    init(_ session: Session, searchTerm: String? = nil, navigationId: UUID? = nil) {
        self.session = session
        self.searchTerm = searchTerm
        self.navigationId = navigationId
    }
}
