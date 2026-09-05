// macos/Engram/Components/AlertBanner.swift
import SwiftUI

struct AlertBanner: View {
    let message: String
    var action: (label: String, action: () -> Void)? = nil

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.primaryText)
            Spacer()
            if let action {
                Button(action: action.action) {
                    HStack(spacing: 4) {
                        Text(action.label)
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.orange)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Theme.orange.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.orange.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
