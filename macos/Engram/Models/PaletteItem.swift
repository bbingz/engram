// macos/Engram/Models/PaletteItem.swift
import SwiftUI

enum PaletteCategory: String {
    case navigation
    case session
    case action
}

struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String
    let category: PaletteCategory
    let action: () -> Void

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
}
