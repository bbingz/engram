// macos/Engram/Views/SidebarView.swift
import SwiftUI

struct SidebarView: View {
    @Binding var selectedScreen: Screen

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Screen.Section.allCases, id: \.self) { section in
                        Text(section.rawValue)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(.horizontal, 12)
                            .padding(.top, section == .overview ? 8 : 12)
                            .padding(.bottom, 4)

                        ForEach(section.screens) { screen in
                            SidebarItem(
                                screen: screen,
                                isSelected: selectedScreen == screen,
                                action: { selectedScreen = screen }
                            )
                        }
                    }
                }
                .padding(.bottom, 8)
            }

            Divider()
                .opacity(0.2)

            // Theme toggle
            ThemeToggleButton()
                .padding(.horizontal, 8)
                .padding(.top, 8)

            // Pinned Settings button
            SidebarItem(
                screen: .settings,
                isSelected: selectedScreen == .settings,
                action: { selectedScreen = .settings }
            )
            .padding(.vertical, 8)
        }
        .frame(minWidth: 160, maxWidth: 160)
    }
}

private struct ThemeToggleButton: View {
    @AppStorage("appTheme") var appTheme: String = "system"

    private var icon: String {
        switch appTheme {
        case "light": return "sun.max.fill"
        case "dark": return "moon.fill"
        default: return "circle.lefthalf.filled"
        }
    }

    private var label: String {
        switch appTheme {
        case "light": return "Light"
        case "dark": return "Dark"
        default: return "System"
        }
    }

    var body: some View {
        Button {
            switch appTheme {
            case "system": appTheme = "light"
            case "light": appTheme = "dark"
            default: appTheme = "system"
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 11))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(Theme.secondaryText)
        }
        .buttonStyle(.plain)
        .help("Toggle theme: System → Light → Dark")
    }
}

private struct SidebarItem: View {
    let screen: Screen
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: screen.icon)
                    .font(.system(size: 11))
                    .frame(width: 18)
                Text(screen.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected
                ? Theme.sidebarSelection
                : Color.clear)
            .foregroundStyle(isSelected
                ? Theme.sidebarSelectedText
                : Theme.secondaryText)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(.horizontal, 8)
    }
}
