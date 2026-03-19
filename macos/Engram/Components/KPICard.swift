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
                .foregroundStyle(.white)
            Text(label)
                .font(.caption)
                .foregroundStyle(Color(hex: 0xA0A1A8))
            if let delta {
                Text(delta)
                    .font(.caption2)
                    .foregroundStyle(deltaPositive ? Color(hex: 0x30D158) : Color(hex: 0xFF453A))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.02))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
