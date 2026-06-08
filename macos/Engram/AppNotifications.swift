import Foundation

extension Notification.Name {
    static let openSettings = Notification.Name("com.engram.openSettings")
    static let openWindow = Notification.Name("com.engram.openWindow")
    static let openSession = Notification.Name("com.engram.openSession")
    static let navigateToScreen = Notification.Name("com.engram.navigateToScreen")
}

/// Box wrapper to safely pass Swift structs through `Notification.object`.
final class SessionBox {
    let session: Session

    init(_ session: Session) {
        self.session = session
    }
}
