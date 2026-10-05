import Foundation

/// A GPU program written as a value. A composite returns more programs from
/// `body`; a primitive sets `Body == Never` and lowers itself directly.
///
/// Every `XView` is an `X3DProgram`: placed in a 3D context, a view is laid
/// out, rasterised, and drawn as a plane. `X3DView` is the opposite bridge.
public protocol X3DProgram {
    associatedtype Body: X3DProgram
    @XUIActor
    @XViewBuilder var body: Body { get async }
}

public extension X3DProgram where Body == Never {
    @XUIActor
    var body: Never {
        fatalError("\(type(of: self)) is a primitive X3DProgram — the walk should never read its body")
    }
}

/// The output of a multi-statement builder block that holds anything other
/// than views.
public struct TupleX3D: X3DProgram {
    public typealias Body = Never
    let children: [any X3DProgram]
    init(_ children: [any X3DProgram]) { self.children = children }
}
