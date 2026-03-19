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
                .foregroundStyle(Color(hex: 0x6E7078))
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.callout)
                .foregroundStyle(Color(hex: 0xA0A1A8))
                .multilineTextAlignment(.center)
            if let action {
                Button(action: action.action) {
                    Text(action.label)
                        .font(.callout)
                        .foregroundStyle(Color(hex: 0x4A8FE7))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
