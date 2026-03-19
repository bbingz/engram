// macos/Engram/Components/AlertBanner.swift
import SwiftUI

struct AlertBanner: View {
    let message: String
    var action: (label: String, action: () -> Void)? = nil

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(hex: 0xFF9F0A))
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
                    .foregroundStyle(Color(hex: 0xFF9F0A))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(hex: 0xFF9F0A).opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(hex: 0xFF9F0A).opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
