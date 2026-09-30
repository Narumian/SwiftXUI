import Foundation

/// The one protocol you implement. Mirrors SwiftUI's `View`: a composite view
/// returns more views from `body`; a primitive sets `Body == Never` and plugs
/// into the layout engine directly (see `_PrimitiveXView`).
///
/// The authored tree is fully static and compiler-checked. Erasure to
/// `[any XView]` happens only inside the engine's walk, one shallow level per
/// container — never in the types you write.
public protocol XView {
    associatedtype Body: XView
    @XViewBuilder var body: Body { get }
}

extension Never: XView {
    public var body: Never { fatalError("Never has no body") }
}

public extension XView where Body == Never {
    var body: Never {
        fatalError("\(type(of: self)) is a primitive XView — the layout engine should never read its body")
    }
}
