// macos/Engram/Components/MotionAware.swift
import SwiftUI

enum MotionAware {
    static func effectiveAnimation(_ base: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : base
    }

    @discardableResult
    static func animate<Result>(
        _ animation: Animation? = .default,
        reduceMotion: Bool,
        _ body: () throws -> Result
    ) rethrows -> Result {
        if let animation = effectiveAnimation(animation, reduceMotion: reduceMotion) {
            return try SwiftUI.withAnimation(animation, body)
        }
        return try body()
    }
}

private struct MotionAwareAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let animation: Animation?
    let value: Value

    func body(content: Content) -> some View {
        content.animation(MotionAware.effectiveAnimation(animation, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    func motionAwareAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(MotionAwareAnimationModifier(animation: animation, value: value))
    }
}
