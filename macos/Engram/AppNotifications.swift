import Foundation

extension Notification.Name {
    static let openSettings = Notification.Name("com.engram.openSettings")
    static let openWindow = Notification.Name("com.engram.openWindow")
    static let openSession = Notification.Name("com.engram.openSession")
    static let navigateToScreen = Notification.Name("com.engram.navigateToScreen")
    static let restartService = Notification.Name("com.engram.restartService")
}

/// Box wrapper to safely pass Swift structs through `Notification.object`.
final class SessionBox {
    let session: Session
    let searchTerm: String?

    init(_ session: Session, searchTerm: String? = nil) {
        self.session = session
        self.searchTerm = searchTerm
    }
}
