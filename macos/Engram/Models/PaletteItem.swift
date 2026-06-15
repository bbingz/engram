// macos/Engram/Models/PaletteItem.swift
import SwiftUI

enum PaletteCategory: String {
    case navigation
    case session
    case action
}

/// A secondary affordance on a palette row (e.g. Resume / Export on a session
/// result). Surfaced on the selected row and bound to modifier-Return keys.
struct PaletteAction: Identifiable {
    let id: String
    let label: String
    let icon: String
    let run: () -> Void
}

struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String
    let category: PaletteCategory
    let action: () -> Void
    var secondaryActions: [PaletteAction] = []

    static func navigationCommands(navigate: @escaping (Screen) -> Void) -> [PaletteItem] {
        Screen.allCases.map { screen in
            PaletteItem(
                id: "nav-\(screen.rawValue)",
                title: "Go to \(screen.title)",
                subtitle: nil,
                icon: screen.icon,
                category: .navigation,
                action: { navigate(screen) }
            )
        }
    }

    /// Real, session-less global actions with confirmed backends. Deliberately
    /// excludes reindex/triggerSync (a confirmed stub) and global Resume/Export
    /// (no current-session context — those live on session result rows).
    static func actionCommands(
        navigate: @escaping (Screen) -> Void,
        refreshUsage: @escaping () -> Void,
        regenerateTitles: @escaping () -> Void
    ) -> [PaletteItem] {
        [
            PaletteItem(
                id: "action-open-settings",
                title: "Open Settings",
                subtitle: nil,
                icon: "gear",
                category: .action,
                action: { navigate(.settings) }
            ),
            PaletteItem(
                id: "action-refresh-usage",
                title: "Refresh Usage Data",
                subtitle: nil,
                icon: "arrow.clockwise",
                category: .action,
                action: refreshUsage
            ),
            PaletteItem(
                id: "action-regenerate-titles",
                title: "Regenerate All Titles",
                subtitle: nil,
                icon: "sparkles",
                category: .action,
                action: regenerateTitles
            ),
        ]
    }

    /// A `.session`-category result whose primary action navigates and whose
    /// secondary actions are Resume + Export.
    static func sessionResult(
        id: String,
        title: String,
        subtitle: String?,
        onSelect: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onExport: @escaping () -> Void
    ) -> PaletteItem {
        PaletteItem(
            id: id,
            title: title,
            subtitle: subtitle,
            icon: "bubble.left.and.bubble.right",
            category: .session,
            action: onSelect,
            secondaryActions: [
                PaletteAction(id: "\(id)-resume", label: "Resume", icon: "play.fill", run: onResume),
                PaletteAction(id: "\(id)-export", label: "Export", icon: "square.and.arrow.up", run: onExport),
            ]
        )
    }
}
