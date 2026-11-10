import XUI

public protocol LaserGeometry: XLive {
    func process(_ input: Void) -> Laser3DBuffer
}

public protocol LaserEffect: XLive {
    func process(_ input: Laser3DBuffer) -> Laser3DBuffer
}

public extension LaserGeometry {
    var body: some XView { EmptyView() }
}

public extension LaserEffect {
    var body: some XView { EmptyView() }
}
