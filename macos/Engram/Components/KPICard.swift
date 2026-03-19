// macos/Engram/Components/KPICard.swift
import SwiftUI

struct KPICard: View {
    let value: String
    let label: String
    var delta: String? = nil
    var deltaPositive: Bool = true

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.primaryText)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            if let delta {
                Text(delta)
                    .font(.caption2)
                    .foregroundStyle(deltaPositive ? Color(hex: 0x30D158) : Color(hex: 0xFF453A))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
