// macos/Engram/Components/SkeletonRow.swift
import SwiftUI

struct SkeletonRow: View {
    @State private var shimmer = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.border)
                .frame(width: 60, height: 20)
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.border)
                .frame(height: 16)
            Spacer()
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.border)
                .frame(width: 80, height: 14)
        }
        .padding(.vertical, 8)
        // Skip the repeatForever display-link animation when the user prefers
        // reduced motion (also avoids per-row animation cost in that mode).
        .opacity(reduceMotion ? 0.7 : (shimmer ? 0.4 : 1.0))
        .motionAwareAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: shimmer)
        .onAppear { if !reduceMotion { shimmer = true } }
    }
}
