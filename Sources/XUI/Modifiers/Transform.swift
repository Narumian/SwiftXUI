import Foundation

/// A subtree drawn through a render-only affine transform. Layout is untouched —
/// the content occupies exactly the same slot; only its pixels move. Mirrors
/// SwiftUI's `.rotationEffect` / `.scaleEffect` / `.transformEffect`.
public struct _TransformModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let transform: XTransform

    func _lower(id: StateIdentity, store: StateStore) -> [LayoutNode] {
        let node = LayoutNode(layout: PassthroughLayout(), children: lower(content, id: id, store: store))
        node.transform = transform
        return [node]
    }
}

public struct _AnchoredTransformModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let transform: XTransform
    let anchor: Alignment

    func _lower(id: StateIdentity, store: StateStore) -> [LayoutNode] {
        let node = LayoutNode(layout: PassthroughLayout(), children: lower(content, id: id, store: store))
        let transform = transform
        let anchor = anchor
        node.transformInFrame = { rect in
            let pivot = Point(
                x: rect.x + rect.width * anchor.horizontal.fraction,
                y: rect.y + rect.height * anchor.vertical.fraction
            )
            return XTransform.translation(x: -pivot.x, y: -pivot.y)
                .concatenating(transform)
                .concatenating(.translation(x: pivot.x, y: pivot.y))
        }
        return [node]
    }
}

public extension XView {
    /// Draw this view's subtree through `transform` (rotation / scale /
    /// translation), without affecting layout.
    func transform(_ transform: XTransform) -> _TransformModifier<Self> {
        _TransformModifier(content: self, transform: transform)
    }

    /// Rotate the drawn pixels by `radians` about the view's centre.
    func rotationEffect(_ radians: Double) -> _AnchoredTransformModifier<Self> {
        rotationEffect(radians, anchor: .center)
    }

    /// Rotate the drawn pixels by `radians` about an alignment point in the
    /// view's resolved frame.
    func rotationEffect(_ radians: Double, anchor: Alignment) -> _AnchoredTransformModifier<Self> {
        transform(.rotation(radians), anchor: anchor)
    }

    /// Scale the drawn pixels about the view's centre.
    func scaleEffect(x: Double = 1, y: Double = 1) -> _AnchoredTransformModifier<Self> {
        scaleEffect(x: x, y: y, anchor: .center)
    }

    /// Scale the drawn pixels about an alignment point in the view's resolved
    /// frame.
    func scaleEffect(x: Double = 1, y: Double = 1, anchor: Alignment) -> _AnchoredTransformModifier<Self> {
        transform(.scale(x: x, y: y), anchor: anchor)
    }

    /// Apply a render-only transform about an alignment point in the view's
    /// resolved frame.
    func transform(_ transform: XTransform, anchor: Alignment) -> _AnchoredTransformModifier<Self> {
        _AnchoredTransformModifier(content: self, transform: transform, anchor: anchor)
    }

    /// Rotate the drawn pixels by `radians` about the global origin.
    func rotationEffectAboutOrigin(_ radians: Double) -> _TransformModifier<Self> {
        transform(.rotation(radians))
    }

    /// Scale the drawn pixels about the global origin.
    func scaleEffectAboutOrigin(x: Double = 1, y: Double = 1) -> _TransformModifier<Self> {
        transform(.scale(x: x, y: y))
    }
}
