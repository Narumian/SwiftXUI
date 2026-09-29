import Foundation

/// A key for a value threaded down the view tree. Conform a type and give it a
/// `defaultValue`; read it in a primitive via `context.environment[MyKey.self]`.
public protocol EnvironmentKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

/// The bag of values available to every node during layout and render.
///
/// v1 is deliberately thin: there is no dependency tracking and no `@Environment`
/// property wrapper. Primitives and `DrawLayer` closures read it through the
/// `RenderContext`. Apps inject their own values (animation clock, effects
/// state, theme tokens) via custom `EnvironmentKey`s.
public struct EnvironmentValues {
    private var storage: [ObjectIdentifier: Any] = [:]

    public init() {}

    public subscript<K: EnvironmentKey>(key: K.Type) -> K.Value {
        get { storage[ObjectIdentifier(key)] as? K.Value ?? K.defaultValue }
        set { storage[ObjectIdentifier(key)] = newValue }
    }
}

/// The reading direction. Leading maps to the left edge under `.leftToRight`.
public enum LayoutDirection: Hashable, Sendable {
    case leftToRight
    case rightToLeft
}

private enum LayoutDirectionKey: EnvironmentKey {
    static let defaultValue: LayoutDirection = .leftToRight
}

public extension EnvironmentValues {
    /// The host's monotonic presentation clock, used by implicit FX playback.
    var fxTime: Double {
        get { self[FXTimeKey.self] }
        set { self[FXTimeKey.self] = newValue }
    }

    var layoutDirection: LayoutDirection {
        get { self[LayoutDirectionKey.self] }
        set { self[LayoutDirectionKey.self] = newValue }
    }
}

private enum SafeAreaInsetsKey: EnvironmentKey {
    static let defaultValue: EdgeInsets = .zero
}

public extension EnvironmentValues {
    /// The parts of the canvas the host says are obscured (status bar, notch,
    /// rounded corners, window title bar), in canvas units. `.safeAreaPadding`
    /// reads it; hosts set it before `LayoutHost.render`.
    var safeAreaInsets: EdgeInsets {
        get { self[SafeAreaInsetsKey.self] }
        set { self[SafeAreaInsetsKey.self] = newValue }
    }
}

private enum FXTimeKey: EnvironmentKey {
    static let defaultValue: Double = 0
}

/// How `Text` measures itself. `LayoutHost.render` wires this to the canvas's
/// `measureText`, so atlas metrics reach the layout pass; the default is a crude
/// monospace estimate for canvas-free tests.
public typealias TextMeasurer = (_ string: String, _ fontSize: Double, _ font: TextFont) -> Size

private enum TextMeasurerKey: EnvironmentKey {
    static var defaultValue: TextMeasurer {
        { string, fontSize, _ in
            Size(width: Double(string.count) * fontSize * 0.6, height: fontSize * 1.3)
        }
    }
}

public extension EnvironmentValues {
    var measureText: TextMeasurer {
        get { self[TextMeasurerKey.self] }
        set { self[TextMeasurerKey.self] = newValue }
    }
}
