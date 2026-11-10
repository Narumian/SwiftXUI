import Foundation
import XUI

/// The master filter at the head of a zone: the last thing that happens to the shapes in 3D
/// before they are projected. It is meant to hold a set of compound effects that apply to
/// the whole zone (colour, transform, and others to come), the way a mastering stage sits
/// on the whole mix and not on one track. Legacy's `postTransform` was the one member it
/// had.
///
/// It is a `LaserEffect` like any other, so it keeps its state and time in
/// `update(context:)`. It is a placeholder for now: shapes pass through untouched and
/// nothing is stored, because its members and their settings are not decided yet.
public struct LaserMastering: LaserEffect, Equatable {
    public init() {}

    public mutating func update(context: LiveUpdateContext) async {}

    public func process(_ input: Laser3DBuffer) -> Laser3DBuffer { input }
}
