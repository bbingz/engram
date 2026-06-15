import Foundation
import UserNotifications

struct UsagePressureNotificationSettings: Equatable {
    let monitorEnabled: Bool
    let notifyOnUsagePressure: Bool
    // Defaulted so existing call sites (e.g. UsagePressureNotifierTests) that
    // predate the cost-budget fields still compile via the memberwise init.
    var notifyOnCostThreshold: Bool = true
    var dailyCostBudget: Double = 0
    var monthlyCostBudget: Double = 0

    static func current(settings: [String: Any]? = readEngramSettings()) -> UsagePressureNotificationSettings {
        let monitor = settings?["monitor"] as? [String: Any]
        return UsagePressureNotificationSettings(
            monitorEnabled: monitor?["enabled"] as? Bool ?? true,
            notifyOnUsagePressure: monitor?["notifyOnUsagePressure"] as? Bool ?? true,
            notifyOnCostThreshold: monitor?["notifyOnCostThreshold"] as? Bool ?? true,
            dailyCostBudget: Self.number(monitor?["dailyCostBudget"]) ?? 0,
            monthlyCostBudget: Self.number(monitor?["monthlyCostBudget"]) ?? 0
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}

/// A single budget-breach event. `identity` is day-keyed so the notifier fires
/// at most once per local day per budget kind, re-arming on the next day.
struct CostBudgetSummary: Equatable, Sendable {
    let identity: String
    let message: String
}

@MainActor
protocol UsagePressureNotificationPosting: AnyObject {
    func postUsagePressureNotification(_ summary: UsagePressureSummary)
    func postCostBudgetNotification(_ summary: CostBudgetSummary)
}

extension UsagePressureNotificationPosting {
    // Default no-op keeps existing conformers (e.g. test recorders that only
    // care about usage pressure) source-compatible.
    func postCostBudgetNotification(_ summary: CostBudgetSummary) {}
}

@MainActor
final class UsagePressureNotifier {
    private let poster: UsagePressureNotificationPosting
    private let settingsProvider: () -> UsagePressureNotificationSettings
    private let dayKeyProvider: () -> String
    private var lastNotifiedKey: String?
    private var lastCostNotifiedKey: String?

    init(
        poster: UsagePressureNotificationPosting? = nil,
        settingsProvider: @escaping () -> UsagePressureNotificationSettings = { .current() },
        dayKeyProvider: (() -> String)? = nil
    ) {
        self.poster = poster ?? UserNotificationUsagePressurePoster()
        self.settingsProvider = settingsProvider
        self.dayKeyProvider = dayKeyProvider ?? { Self.localDayKey() }
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

    /// Budget-breach check. Fires at most once per local day per breached budget
    /// kind (daily/monthly). Re-arms on the next day, and clears its dedup state
    /// when disabled or when no budget is configured so re-enabling can notify.
    func observeCosts(todayUsd: Double, monthToDateUsd: Double) {
        let settings = settingsProvider()
        guard settings.monitorEnabled, settings.notifyOnCostThreshold else {
            lastCostNotifiedKey = nil
            return
        }

        let dailyBudget = settings.dailyCostBudget
        let monthlyBudget = settings.monthlyCostBudget
        guard dailyBudget > 0 || monthlyBudget > 0 else {
            lastCostNotifiedKey = nil
            return
        }

        let day = dayKeyProvider()
        // Daily breach takes precedence; fall through to monthly otherwise.
        if dailyBudget > 0, todayUsd >= dailyBudget {
            fireCostBreach(
                kind: "daily",
                day: day,
                message: "Engram daily budget reached — \(Self.formatUsd(todayUsd)) of \(Self.formatUsd(dailyBudget))"
            )
        } else if monthlyBudget > 0, monthToDateUsd >= monthlyBudget {
            fireCostBreach(
                kind: "monthly",
                day: day,
                message: "Engram monthly budget reached — \(Self.formatUsd(monthToDateUsd)) of \(Self.formatUsd(monthlyBudget))"
            )
        }
    }

    private func fireCostBreach(kind: String, day: String, message: String) {
        let key = "\(kind):\(day)"
        guard key != lastCostNotifiedKey else { return }
        poster.postCostBudgetNotification(CostBudgetSummary(identity: key, message: message))
        lastCostNotifiedKey = key
    }

    static func localDayKey(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func formatUsd(_ value: Double) -> String {
        if value >= 1000 { return String(format: "$%.0f", value) }
        return String(format: "$%.2f", value)
    }
}

/// Routes a usage/cost notification's default tap to the Sources page. Lives on
/// the poster so it is unit-testable without constructing a `UNNotification`
/// (which is not publicly constructible).
@MainActor
final class UserNotificationUsagePressurePoster: NSObject, UsagePressureNotificationPosting, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private var didRequestAuthorization = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func postUsagePressureNotification(_ summary: UsagePressureSummary) {
        postNotification(
            title: summary.severity == .critical ? "Engram usage critical" : "Engram usage attention",
            body: summary.message,
            sound: summary.severity == .critical
        )
    }

    func postCostBudgetNotification(_ summary: CostBudgetSummary) {
        postNotification(title: "Engram budget reached", body: summary.message, sound: true)
    }

    private func postNotification(title: String, body: String, sound: Bool) {
        Task { [center] in
            if !didRequestAuthorization {
                didRequestAuthorization = true
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
                    return
                }
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = sound ? .default : nil

            let request = UNNotificationRequest(
                identifier: "engram-usage-pressure-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    /// Opens the main window and navigates to the Sources page. `.openWindow`
    /// posts synchronously; `.navigateToScreen` is deferred to the next run-loop
    /// tick so a freshly-created window's `.onReceive` subscriber is attached
    /// before it lands (cold-window race; mirrors MenuBarController.handleOpenWindow).
    func openUsageSurface() {
        NotificationCenter.default.post(name: .openWindow, object: nil)
        Task { @MainActor in
            NotificationCenter.default.post(name: .navigateToScreen, object: Screen.sourcePulse.rawValue)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in self.openUsageSurface() }
        }
        completionHandler()
    }
}
