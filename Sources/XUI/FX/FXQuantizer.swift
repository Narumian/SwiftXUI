import Foundation

public protocol FXQuantizer: Sendable {
    var delay: Double { get }
}

public struct NoQuantizer: FXQuantizer {
    public init() {}

    public var delay: Double { 0 }
}
