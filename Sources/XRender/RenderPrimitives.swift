import Foundation

/// Presentation frame counter. This belongs to the render boundary rather
/// than a game engine so XRender can be used by games, tools, and previews.
public struct FrameIndex: Hashable, Comparable, Sendable {
    public var value: UInt64

    public init(_ value: UInt64 = 0) { self.value = value }

    public static let zero = FrameIndex(0)
    public static func < (lhs: FrameIndex, rhs: FrameIndex) -> Bool {
        lhs.value < rhs.value
    }

    public func next() -> FrameIndex { FrameIndex(value &+ 1) }
}

/// Everything a presentation driver receives for one rendered frame.
public struct EngineFrame: Sendable {
    public let index: FrameIndex
    public let delta: Double
    public let elapsed: Double

    public init(index: FrameIndex, delta: Double, elapsed: Double) {
        self.index = index
        self.delta = delta
        self.elapsed = elapsed
    }
}

public struct RenderSize: Sendable, Equatable {
    public var width: Float
    public var height: Float

    public init(width: Float, height: Float) {
        self.width = max(width, 1)
        self.height = max(height, 1)
    }
}

public struct RenderPoint: Sendable, Equatable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

public struct RenderRect: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func contains(_ point: RenderPoint) -> Bool {
        point.x >= x && point.x <= x + width && point.y >= y && point.y <= y + height
    }

    /// Returns the axis-aligned overlap with another rect.
    ///
    /// Keeping the result non-negative makes nested render clips safe even
    /// when a child is completely outside its parent's clip.
    public func intersection(_ other: Self) -> Self {
        let minX = max(x, other.x)
        let minY = max(y, other.y)
        let maxX = min(x + width, other.x + other.width)
        let maxY = min(y + height, other.y + other.height)
        return Self(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }
}

public struct RenderColor: Sendable, Equatable {
    public var red: Float
    public var green: Float
    public var blue: Float
    public var alpha: Float

    public init(_ red: Float, _ green: Float, _ blue: Float, _ alpha: Float = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public func withAlpha(_ alpha: Float) -> Self {
        Self(red, green, blue, alpha)
    }

    public static let white = Self(1, 1, 1)
    public static let black = Self(0, 0, 0)
    public static let pink = Self(1, 0.12, 0.46)
    public static let cyan = Self(0.12, 0.86, 1)
    public static let yellow = Self(1, 0.82, 0.12)
    public static let orange = Self(1, 0.42, 0.08)
}

public enum PointerPhase: Sendable, Equatable {
    case began
    case moved
    case ended
    case cancelled
}

public struct PointerEvent: Sendable, Equatable {
    public var phase: PointerPhase
    public var position: RenderPoint

    public init(phase: PointerPhase, position: RenderPoint) {
        self.phase = phase
        self.position = position
    }
}

/// A moment worth a haptic tap and/or a short sound. The vendor shell maps
/// these to native feedback; presentation decides when they fire.
public enum PresentationFeedback: Sendable, Equatable, CaseIterable {
    case selection   // UI tap
    case impact      // generic thud (transition, misc)
    case spin        // the reels launched
    case reward      // coins / resource gain / jackpot
    case damage      // a hit landed on someone
    case reelStop    // one physical reel finished braking
    case spinEnd     // every reel finished settling
}

/// Cross-platform presentation boundary. Vendor shells only provide a surface,
/// a frame clock, pointer coordinates and feedback execution.
public protocol RenderContent: AnyObject {
    func scene(_ frame: EngineFrame, size: RenderSize) -> Scene
    func pointer(_ event: PointerEvent)
    func drainFeedback() -> [PresentationFeedback]
}

public extension RenderContent {
    func pointer(_ event: PointerEvent) {}
    func drainFeedback() -> [PresentationFeedback] { [] }
}
