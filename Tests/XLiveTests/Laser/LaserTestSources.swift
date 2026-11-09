import Foundation
@testable import XLive

/// A source that answers with the same frame every time it is read, for tests of the stages
/// that follow it.
struct FixedFrame: Laser3DStream {
    var shapes: [Laser3DShape]
    init(_ shapes: [Laser3DShape]) { self.shapes = shapes }
    mutating func read() -> [Laser3DShape] { shapes }
}
