import Testing
@testable import SwiftXUI

// MARK: - Curves

@Test func everyTimedCurveStartsAtZeroAndRestsAtOne() {
    for animation in [Animation.linear(duration: 1), .easeIn(duration: 1), .easeOut(duration: 1),
                      .easeInOut(duration: 1), .timingCurve(0.2, 0.8, 0.4, 1, duration: 1)] {
        #expect(animation.progress(elapsed: 0) == 0)
        #expect(animation.progress(elapsed: 1) == 1)
        #expect(animation.progress(elapsed: 5) == 1)
        let samples = stride(from: 0.0, through: 1.0, by: 0.1).map { animation.progress(elapsed: $0) }
        #expect(samples == samples.sorted(), "a timed curve never runs backwards")
    }
}

@Test func theNamedCurvesHaveTheirCharacter() {
    #expect(Animation.linear(duration: 1).progress(elapsed: 0.5) == 0.5)
    #expect(Animation.easeIn(duration: 1).progress(elapsed: 0.5) < 0.5)       // slow start
    #expect(Animation.easeOut(duration: 1).progress(elapsed: 0.5) > 0.5)      // fast start
    #expect(abs(Animation.easeInOut(duration: 1).progress(elapsed: 0.5) - 0.5) < 1e-9)
}

@Test func aDelayHoldsTheStartAndASpeedScalesTime() {
    let delayed = Animation.linear(duration: 1).delay(0.5)
    #expect(delayed.progress(elapsed: 0.4) == 0)
    #expect(abs(delayed.progress(elapsed: 1.0) - 0.5) < 1e-9)
    #expect(delayed.totalDuration == 1.5)

    let fast = Animation.linear(duration: 1).speed(2)
    #expect(abs(fast.progress(elapsed: 0.25) - 0.5) < 1e-9)
    #expect(fast.totalDuration == 0.5)
}

@Test func aSpringOvershootsWhenUnderdampedAndNeverWhenCriticallyDamped() {
    let bouncy = Animation.spring(response: 0.5, dampingFraction: 0.4)
    let peak = stride(from: 0.0, through: bouncy.totalDuration, by: 0.01).map { bouncy.progress(elapsed: $0) }.max() ?? 0
    #expect(peak > 1.05)
    #expect(bouncy.progress(elapsed: 0) == 0)
    #expect(bouncy.progress(elapsed: bouncy.totalDuration + 1) == 1)

    let firm = Animation.spring(response: 0.5, dampingFraction: 1)
    let firmPeak = stride(from: 0.0, through: firm.totalDuration, by: 0.01).map { firm.progress(elapsed: $0) }.max() ?? 0
    #expect(firmPeak <= 1.0 + 1e-9)
}

// MARK: - Interpolation

@Test func valuesBlendAndAnOvershootIsNotClamped() {
    #expect(Double.interpolate(from: 10, to: 20, at: 0.5) == 15)
    #expect(Double.interpolate(from: 10, to: 20, at: 1.2) == 22)
    #expect(Point.interpolate(from: Point(x: 0, y: 0), to: Point(x: 10, y: 20), at: 0.5) == Point(x: 5, y: 10))
    #expect(XColorValue.interpolate(from: XColorValue(0, 0, 0, 1), to: XColorValue(1, 1, 1, 0), at: 0.5)
            == XColorValue(0.5, 0.5, 0.5, 0.5))
}

// MARK: - The state machine

private let animating = Transaction(animation: .linear(duration: 1), triggered: true)
private let quiet = Transaction(animation: .linear(duration: 1), triggered: false)

@Test func aValueThatJustAppearedIsThereNotAnimatedIn() {
    var state = AnimationState<Double>(100)
    #expect(state.update(target: 100, now: 0, transaction: animating) == 100)
}

@Test func aTriggeredChangeMovesOverTheAnimationsDuration() {
    var state = AnimationState<Double>(100)
    #expect(state.update(target: 200, now: 10, transaction: animating) == 100)   // starts where it was
    #expect(state.update(target: 200, now: 10.5, transaction: quiet) == 150)     // halfway
    #expect(state.update(target: 200, now: 11, transaction: quiet) == 200)       // arrived
    #expect(state.update(target: 200, now: 12, transaction: quiet) == 200)
    #expect(!state.isMoving)
}

@Test func aChangeThatIsNotTriggeredJumps() {
    var state = AnimationState<Double>(100)
    #expect(state.update(target: 200, now: 5, transaction: quiet) == 200)
    #expect(state.update(target: 300, now: 5, transaction: Transaction(animation: nil, triggered: true)) == 300)
}

@Test func aTargetThatChangesMidFlightBendsFromWhereTheValueIs() {
    var state = AnimationState<Double>(0)
    _ = state.update(target: 100, now: 0, transaction: animating)
    #expect(state.update(target: 100, now: 0.5, transaction: quiet) == 50)
    // Redirected at 50: it continues from 50, not from 0 or 100.
    #expect(state.update(target: 0, now: 0.5, transaction: animating) == 50)
    #expect(state.update(target: 0, now: 1.0, transaction: quiet) == 25)
    #expect(state.update(target: 0, now: 1.5, transaction: quiet) == 0)
}

// MARK: - In a view tree

private let canvas = Size(width: 400, height: 100)
private let bar = AnchorID("bar")

/// One frame at presentation time `time`, with the same store as the last.
private func frameWidth(_ width: Double, watching value: Int, at time: Double, store: StateStore,
                        animation: Animation? = .linear(duration: 1)) -> Double {
    var environment = EnvironmentValues()
    environment.fxTime = time
    let view = Color.clear.frame(width: width, height: 10).anchor(bar).animation(animation, value: value)
    return LayoutHost(canvas: canvas, environment: environment).resolveAnchors(view, store: store)[bar]?.width ?? -1
}

@Test func aFrameWidthEasesToItsNewValueOnThePresentationClock() {
    let store = StateStore()
    #expect(frameWidth(100, watching: 1, at: 0, store: store) == 100)
    #expect(frameWidth(100, watching: 1, at: 0.5, store: store) == 100)      // nothing changed: nothing moves
    #expect(frameWidth(200, watching: 2, at: 1.0, store: store) == 100)      // the change starts here
    #expect(abs(frameWidth(200, watching: 2, at: 1.5, store: store) - 150) < 1e-9)
    #expect(frameWidth(200, watching: 2, at: 2.0, store: store) == 200)
    #expect(frameWidth(200, watching: 2, at: 3.0, store: store) == 200)
}

@Test func aWidthChangeWhoseWatchedValueDidNotChangeJumps() {
    let store = StateStore()
    #expect(frameWidth(100, watching: 1, at: 0, store: store) == 100)
    #expect(frameWidth(200, watching: 1, at: 0.1, store: store) == 200)      // `value` is the same: no animation
}

@Test func aNilAnimationMakesEverythingInsideJump() {
    let store = StateStore()
    #expect(frameWidth(100, watching: 1, at: 0, store: store, animation: nil) == 100)
    #expect(frameWidth(200, watching: 2, at: 0.1, store: store, animation: nil) == 200)
}

@Test func withoutAnAnimationModifierNothingChangesAndNothingIsStored() {
    let store = StateStore()
    var environment = EnvironmentValues()
    func width(_ w: Double, at time: Double) -> Double {
        environment.fxTime = time
        let view = Color.clear.frame(width: w, height: 10).anchor(bar)
        return LayoutHost(canvas: canvas, environment: environment).resolveAnchors(view, store: store)[bar]?.width ?? -1
    }
    #expect(width(100, at: 0) == 100)
    #expect(width(300, at: 0.1) == 300)
    #expect(!store.transaction.isActive)
}

@Test func anOffsetEasesAndAnAnimatedRegionDoesNotLeakIntoItsSiblings() {
    let store = StateStore()
    func frames(_ x: Double, _ value: Int, at time: Double) -> (moving: Double, sibling: Double) {
        var environment = EnvironmentValues()
        environment.fxTime = time
        let view = VStack(spacing: 0) {
            Color.clear.frame(width: 10, height: 10).anchor("moving").offset(x: x).animation(.linear(duration: 1), value: value)
            Color.clear.frame(width: 10, height: 10).anchor("sibling").offset(x: x)   // outside the region
        }
        let anchors = LayoutHost(canvas: canvas, environment: environment).resolveAnchors(view, store: store)
        return (anchors["moving"]?.x ?? -1, anchors["sibling"]?.x ?? -1)
    }
    _ = frames(0, 1, at: 0)
    _ = frames(100, 2, at: 1)
    let half = frames(100, 2, at: 1.5)
    #expect(abs(half.moving - 50) < 1e-9)
    #expect(half.sibling == 100)                              // not animated: it is outside `.animation`
}
