import SwiftUI
import XCTest

@testable import Engram

final class MotionAwareTests: XCTestCase {
    func testEffectiveAnimationRemovesAnimationWhenReduceMotionEnabled() {
        XCTAssertNil(MotionAware.effectiveAnimation(.easeInOut(duration: 0.2), reduceMotion: true))
    }

    func testEffectiveAnimationPreservesNilAnimationWhenReduceMotionDisabled() {
        XCTAssertNil(MotionAware.effectiveAnimation(nil, reduceMotion: false))
    }

    func testEffectiveAnimationPreservesAnimationWhenReduceMotionDisabled() {
        XCTAssertNotNil(MotionAware.effectiveAnimation(.default, reduceMotion: false))
    }
}
