import GameRender
import SwiftXUI

// Value-type conversions between SwiftXUI's backend-agnostic geometry/colour and
// GameRender's `Render*` types. SwiftXUI works in `Double`; GameRender in `Float`.

private let textureImageSourcePrefix = "gamerender-texture:"

public extension SwiftXUI.ImageSource {
    init(_ texture: TextureID, naturalSize: SwiftXUI.Size) {
        self.init("\(textureImageSourcePrefix)\(texture.rawValue)", naturalSize: naturalSize)
    }

    init(_ texture: TextureID, naturalSize: SIMD2<Float>) {
        self.init(texture, naturalSize: SwiftXUI.Size(width: Double(naturalSize.x), height: Double(naturalSize.y)))
    }

    var textureID: TextureID? {
        guard name.hasPrefix(textureImageSourcePrefix),
              let raw = UInt32(name.dropFirst(textureImageSourcePrefix.count)) else {
            return nil
        }
        return TextureID(raw)
    }
}

public extension SwiftXUI.Rect {
    var render: RenderRect {
        RenderRect(x: Float(x), y: Float(y), width: Float(width), height: Float(height))
    }
    init(_ r: RenderRect) {
        self.init(x: Double(r.x), y: Double(r.y), width: Double(r.width), height: Double(r.height))
    }
}

public extension SwiftXUI.Point {
    var render: RenderPoint {
        RenderPoint(x: Float(x), y: Float(y))
    }
    init(_ p: RenderPoint) {
        self.init(x: Double(p.x), y: Double(p.y))
    }
}

public extension SwiftXUI.Size {
    var render: RenderSize {
        RenderSize(width: Float(width), height: Float(height))
    }
    init(_ s: RenderSize) {
        self.init(width: Double(s.width), height: Double(s.height))
    }
}

public extension XColorValue {
    var render: RenderColor {
        RenderColor(Float(red), Float(green), Float(blue), Float(opacity))
    }
    init(_ c: RenderColor) {
        self.init(Double(c.red), Double(c.green), Double(c.blue), Double(c.alpha))
    }
}

public extension XTransform {
    var render: Transform2D {
        Transform2D(a: Float(a), b: Float(b), c: Float(c), d: Float(d), tx: Float(tx), ty: Float(ty))
    }
}

public extension SwiftXUI.TextFont {
    var render: FontRole {
        switch self {
        case .ui: .ui
        case .numeric: .numeric
        case .display: .display
        }
    }
}
