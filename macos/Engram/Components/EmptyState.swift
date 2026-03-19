// macos/Engram/Components/EmptyState.swift
import SwiftUI

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var action: (label: String, action: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(Theme.tertiaryText)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            if let action {
                Button(action: action.action) {
                    Text(action.label)
                        .font(.callout)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
