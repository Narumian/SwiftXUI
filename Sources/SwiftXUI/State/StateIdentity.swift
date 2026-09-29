import Foundation

/// A structural position in a declarative tree walk (`FX`'s `emit`, and in a
/// future stage `XView`'s `lower`), used to find the same persistent storage
/// across separate walks of a freshly-rebuilt value-type tree.
///
/// Built by chaining cheap, non-allocating combines from a root seed as the
/// walk descends — never a growing path array. A hash collision between two
/// distinct structural paths would silently alias their state; at the tree
/// sizes this project walks that risk is accepted, the same way SwiftUI's
/// own private diffing accepts it.
public struct StateIdentity: Hashable, Sendable {
    private var bits: UInt64

    private init(bits: UInt64) { self.bits = bits }

    public static let root = StateIdentity(bits: 0x9E37_79B9_7F4A_7C15)

    /// One structural step: this node's concrete type plus its position
    /// among its siblings.
    public func child(type: Any.Type, index: Int = 0) -> StateIdentity {
        var h = Hasher()
        h.combine(bits)
        h.combine(ObjectIdentifier(type))
        h.combine(index)
        return StateIdentity(bits: UInt64(bitPattern: Int64(h.finalize())))
    }

    /// One property-name step, for disambiguating multiple `@XState`
    /// properties on the same node — the name is stable source text the
    /// `@Stateful` macro reads at expansion time, no call-site capture needed.
    public func child(name: String) -> StateIdentity {
        var h = Hasher()
        h.combine(bits)
        h.combine(name)
        return StateIdentity(bits: UInt64(bitPattern: Int64(h.finalize())))
    }
}
