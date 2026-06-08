import Foundation
import UserNotifications

struct UsagePressureNotificationSettings: Equatable {
    let monitorEnabled: Bool
    let notifyOnUsagePressure: Bool

    static func current(settings: [String: Any]? = readEngramSettings()) -> UsagePressureNotificationSettings {
        let monitor = settings?["monitor"] as? [String: Any]
        return UsagePressureNotificationSettings(
            monitorEnabled: monitor?["enabled"] as? Bool ?? true,
            notifyOnUsagePressure: monitor?["notifyOnUsagePressure"] as? Bool ?? true
        )
    }
}

@MainActor
protocol UsagePressureNotificationPosting: AnyObject {
    func postUsagePressureNotification(_ summary: UsagePressureSummary)
}

@MainActor
final class UsagePressureNotifier {
    private let poster: UsagePressureNotificationPosting
    private let settingsProvider: () -> UsagePressureNotificationSettings
    private var lastNotifiedKey: String?

    init(
        poster: UsagePressureNotificationPosting? = nil,
        settingsProvider: @escaping () -> UsagePressureNotificationSettings = { .current() }
    ) {
        self.poster = poster ?? UserNotificationUsagePressurePoster()
        self.settingsProvider = settingsProvider
    }

    func observe(summary: UsagePressureSummary?) {
        guard let summary else {
            lastNotifiedKey = nil
            return
        }

        let settings = settingsProvider()
        guard settings.monitorEnabled, settings.notifyOnUsagePressure else {
            lastNotifiedKey = nil
            return
        }

        let key = "\(summary.severity.rawValue):\(summary.identity)"
        guard key != lastNotifiedKey else { return }

        poster.postUsagePressureNotification(summary)
        lastNotifiedKey = key
    }
}

@MainActor
final class UserNotificationUsagePressurePoster: UsagePressureNotificationPosting {
    private let center: UNUserNotificationCenter
    private var didRequestAuthorization = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func postUsagePressureNotification(_ summary: UsagePressureSummary) {
        Task { [center] in
            if !didRequestAuthorization {
                didRequestAuthorization = true
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
                    return
                }
            }

            let content = UNMutableNotificationContent()
            content.title = summary.severity == .critical
                ? "Engram usage critical"
                : "Engram usage attention"
            content.body = summary.message
            content.sound = summary.severity == .critical ? .default : nil

            let request = UNNotificationRequest(
                identifier: "engram-usage-pressure-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}
