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
                // Text style (not a fixed size) so the hero number scales with
                // Dynamic Type like the rest of the page.
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(LocalizedStringKey(label))
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            if let delta {
                Text(delta)
                    .font(.caption2)
                    .foregroundStyle(deltaPositive ? Theme.green : Theme.red)
            }
        }
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        // UI-H3: combine the value+label (and optional delta) into one VoiceOver
        // element with a real label/value instead of two disconnected strings.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalizedStringKey(label))
        .accessibilityValue(accessibilityValueText)
    }

    private var accessibilityValueText: String {
        guard let delta else { return value }
        return "\(value), \(deltaPositive ? "up" : "down") \(delta)"
    }
}
