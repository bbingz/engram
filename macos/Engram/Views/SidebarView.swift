// macos/Engram/Views/SidebarView.swift
import SwiftUI

struct SidebarView: View {
    @Binding var selectedScreen: Screen
    // observability-6: hide the developer-diagnostics nav item unless Developer
    // Tools are enabled (default off). The Settings toggle that flips this flag
    // is added by a later Settings WP.
    @AppStorage("showDeveloperTools") private var showDeveloperTools = false
    // Row 31: scale column width with Dynamic Type so larger fonts don't clip
    // lineLimit(1) labels against a hard 160pt pin.
    @ScaledMetric(relativeTo: .body) private var sidebarWidth: CGFloat = 160

    private func screens(in section: Screen.Section) -> [Screen] {
        section.screens.filter { showDeveloperTools || $0 != .observability }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Screen.Section.allCases, id: \.self) { section in
                        Text(LocalizedStringKey(section.rawValue))
                            .scaledFont(8, weight: .semibold)
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(.horizontal, 12)
                            .padding(.top, section == .overview ? 6 : 8)
                            .padding(.bottom, 2)

                        ForEach(screens(in: section)) { screen in
                            SidebarItem(
                                screen: screen,
                                isSelected: selectedScreen == screen,
                                action: { selectedScreen = screen }
                            )
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .modernScrollIndicators()

            Divider()
                .opacity(0.2)

            SidebarFooter(selectedScreen: $selectedScreen)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .frame(minWidth: sidebarWidth)
        .navigationSplitViewColumnWidth(
            min: max(120, sidebarWidth * 0.9),
            ideal: sidebarWidth,
            max: max(sidebarWidth * 1.8, 280)
        )
        .accessibilityIdentifier("sidebar")
    }
}

private struct SidebarFooter: View {
    @Binding var selectedScreen: Screen
    @AppStorage("appTheme") var appTheme: String = "system"

    private var icon: String {
        switch appTheme {
        case "light": return "sun.max.fill"
        case "dark": return "moon.fill"
        default: return "circle.lefthalf.filled"
        }
    }

    private func applyTheme(_ theme: String) {
        switch theme {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil  // nil = follow system
        }
    }

    private func cycleTheme() {
        switch appTheme {
        case "system": appTheme = "light"
        case "light": appTheme = "dark"
        default: appTheme = "system"
        }
        applyTheme(appTheme)
    }

    var body: some View {
        HStack(spacing: 0) {
            footerButton(
                icon: Screen.settings.icon,
                title: Screen.settings.title,
                isSelected: selectedScreen == .settings,
                accessibilityIdentifier: "sidebar_item_settings",
                action: { selectedScreen = .settings }
            )

            Rectangle()
                .fill(Theme.border)
                .frame(width: 1, height: 18)
                .padding(.horizontal, 2)

            footerButton(
                icon: icon,
                title: "Theme",
                isSelected: false,
                accessibilityIdentifier: "sidebar_themeToggle",
                action: cycleTheme
            )
            .help(Text("Toggle theme: System → Light → Dark"))
        }
        .frame(height: 28)
        .accessibilityElement(children: .contain)
    }

    private func footerButton(
        icon: String,
        title: String,
        isSelected: Bool,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .scaledFont(10)
                    .frame(width: 13)
                Text(LocalizedStringKey(title))
                    .scaledFont(10, weight: isSelected ? .semibold : .regular)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? Theme.sidebarSelectedText : Theme.secondaryText)
            .background(isSelected ? Theme.sidebarSelection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .focusEffectDisabled()
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
                    .scaledFont(10.5)
                    .frame(width: 16)
                Text(LocalizedStringKey(screen.title))
                    .scaledFont(10.5)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected
                ? Theme.sidebarSelection
                : Color.clear)
            .foregroundStyle(isSelected
                ? Theme.sidebarSelectedText
                : Theme.secondaryText)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar_item_\(screen.rawValue)")
        .focusEffectDisabled()
        .padding(.horizontal, 8)
    }
}
