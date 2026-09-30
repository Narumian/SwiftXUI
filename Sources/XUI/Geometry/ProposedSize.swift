import Foundation

/// A size a parent offers to a child during the measure pass.
///
/// A `nil` component means "no preference — return your ideal size on this axis".
/// `0` and `.infinity` are meaningful proposals (SwiftUI's min / max probes).
public struct ProposedSize: Hashable, Sendable {
    public var width: Double?
    public var height: Double?

    public init(width: Double?, height: Double?) {
        self.width = width
        self.height = height
    }

    public init(_ size: Size) {
        self.init(width: size.width, height: size.height)
    }

    /// No preference on either axis.
    public static let unspecified = ProposedSize(width: nil, height: nil)
    /// Probe a child's minimum: propose zero on both axes.
    public static let zero = ProposedSize(width: 0, height: 0)
    /// Probe a child's maximum: propose infinity on both axes.
    public static let infinity = ProposedSize(width: .infinity, height: .infinity)

    /// Resolve to a concrete size, substituting `fallback` wherever a component is `nil`.
    public func resolved(fallback: Size = .zero) -> Size {
        Size(width: width ?? fallback.width, height: height ?? fallback.height)
    }

    func replacingUnspecified(width w: Double, height h: Double) -> ProposedSize {
        ProposedSize(width: width ?? w, height: height ?? h)
    }
}
