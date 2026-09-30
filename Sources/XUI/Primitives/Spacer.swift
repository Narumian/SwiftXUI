import Foundation

/// A flexible gap. Inside a stack it expands along the stack's main axis, down
/// to `minLength`, and contributes nothing on the cross axis. Outside a stack it
/// is inert (zero size).
public struct Spacer: XView, _PrimitiveXView {
    public typealias Body = Never
    public var minLength: Double

    public init(minLength: Double = 0) {
        self.minLength = minLength
    }

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let node = LayoutNode(layout: FixedSizeLayout(size: .zero))
        node.isSpacer = true
        node.spacerMinLength = minLength
        return [node]
    }
}
