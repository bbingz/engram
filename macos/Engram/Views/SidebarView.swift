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
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x6E7078))
                            .padding(.horizontal, 12)
                            .padding(.top, section == .overview ? 8 : 16)
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

private struct SidebarItem: View {
    let screen: Screen
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: screen.icon)
                    .font(.system(size: 13))
                    .frame(width: 20)
                Text(screen.title)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected
                ? Color(hex: 0x4A8FE7).opacity(0.25)
                : Color.clear)
            .foregroundStyle(isSelected
                ? Color(hex: 0x6CB4FF)
                : Color(hex: 0xA0A1A8))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}
