import Foundation

/// The animation context a subtree is being declared in, like SwiftUI's
/// `Transaction`. `View.animation(_:value:)` sets it for everything inside it;
/// animatable modifiers read it to decide whether a change moves or jumps.
public struct Transaction: Sendable {
    /// The animation to use, or nil to make changes jump.
    public var animation: Animation?
    /// The watched `value` of the enclosing `.animation(_:value:)` changed in
    /// this pass, so changes made now should animate.
    public internal(set) var triggered: Bool
    /// True inside any `.animation(_:value:)`, even one with a nil animation.
    /// Outside one, modifiers skip animation work entirely.
    public internal(set) var isActive: Bool

    public init(animation: Animation? = nil) {
        self.animation = animation
        self.triggered = false
        self.isActive = false
    }

    init(animation: Animation?, triggered: Bool) {
        self.animation = animation
        self.triggered = triggered
        self.isActive = true
    }

    /// A change made now should move rather than jump.
    var animates: Bool { isActive && triggered && animation != nil }
}
