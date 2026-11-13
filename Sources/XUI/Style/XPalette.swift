import Foundation

/// A colour written in OKLCH (lightness 0...1, chroma, hue in degrees), the space the palette is built in: equal
/// lightness looks equally light whatever the hue, so a scale built from one curve reads the same in every hue and
/// its contrast can be known ahead of time.
public struct XOKLCH: Equatable, Sendable {
    public var lightness: Double
    public var chroma: Double
    public var hue: Double

    public init(_ lightness: Double, _ chroma: Double, _ hue: Double) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
    }

    /// The sRGB colour, with the chroma pulled in just far enough to be inside the display's gamut.
    public var color: XColorValue {
        var low = 0.0, high = max(0, chroma)
        if Self.srgb(lightness, high, hue) != nil { return Self.make(Self.srgb(lightness, high, hue)!) }
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if Self.srgb(lightness, mid, hue) != nil { low = mid } else { high = mid }
        }
        return Self.make(Self.srgb(lightness, low, hue) ?? (lightness, lightness, lightness))
    }

    private static func make(_ c: (Double, Double, Double)) -> XColorValue {
        XColorValue(min(1, max(0, c.0)), min(1, max(0, c.1)), min(1, max(0, c.2)))
    }

    /// Gamma encoded sRGB, or nil when any channel falls outside 0...1.
    private static func srgb(_ l: Double, _ c: Double, _ hue: Double) -> (Double, Double, Double)? {
        let h = hue * .pi / 180
        let a = c * cos(h), b = c * sin(h)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let lc = l_ * l_ * l_, mc = m_ * m_ * m_, sc = s_ * s_ * s_
        let r = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
        let g = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
        let bl = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc
        let eps = 1e-6
        guard r >= -eps, r <= 1 + eps, g >= -eps, g <= 1 + eps, bl >= -eps, bl <= 1 + eps else { return nil }
        func encode(_ x: Double) -> Double {
            let v = min(1, max(0, x))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return (encode(r), encode(g), encode(bl))
    }
}

public extension XColorValue {
    /// WCAG relative luminance of the opaque colour.
    var relativeLuminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    /// WCAG contrast ratio, 1...21, between two opaque colours.
    func contrast(with other: XColorValue) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// One hue as a scale of five steps, from a faint wash to light text. The steps are built from fixed lightness and
/// chroma, so every hue keeps the same contrast against the neutrals.
public struct XAccent: Equatable, Sendable {
    public let hue: Double
    /// A wash for a quiet background (a selected row, a tinted zone).
    public let subtle: XColorValue
    /// A solid chip behind white text (a selected button).
    public let fill: XColorValue
    /// An outline.
    public let border: XColorValue
    /// Marks that stand on their own: an arc, a lamp, a thin line.
    public let base: XColorValue
    /// Text of this colour on a neutral surface.
    public let text: XColorValue

    public init(hue: Double) {
        self.hue = hue
        subtle = XOKLCH(0.30, 0.045, hue).color
        fill = XOKLCH(0.44, 0.09, hue).color
        border = XOKLCH(0.62, 0.13, hue).color
        base = XOKLCH(0.74, 0.16, hue).color
        text = XOKLCH(0.86, 0.08, hue).color
    }
}

private final class XAccentCache: @unchecked Sendable {
    private let lock = NSLock()
    private var scales: [Double: XAccent] = [:]
    func scale(hue: Double) -> XAccent {
        lock.lock(); defer { lock.unlock() }
        if let found = scales[hue] { return found }
        let made = XAccent(hue: hue)
        scales[hue] = made
        return made
    }
}

public extension XAccent {
    private static let cache = XAccentCache()
    /// The scale of `hue`, built the first time and kept. Use it wherever a scale is read while drawing.
    static func cached(hue: Double) -> XAccent { cache.scale(hue: hue) }
}

/// A hue the user may pick for an accent: a short list that stays clear of the hues that mean something fixed
/// (red for danger, green for running), so a chosen colour never reads as a state.
public struct XAccentChoice: Equatable, Hashable, Sendable, Identifiable {
    public let name: String
    public let hue: Double
    public var id: String { name }

    public static let blue = XAccentChoice(name: "Blue", hue: 255)
    public static let cyan = XAccentChoice(name: "Cyan", hue: 205)
    public static let violet = XAccentChoice(name: "Violet", hue: 295)
    public static let magenta = XAccentChoice(name: "Magenta", hue: 345)
    public static let orange = XAccentChoice(name: "Orange", hue: 55)
    public static let amber = XAccentChoice(name: "Amber", hue: 80)
    public static let all: [XAccentChoice] = [.blue, .cyan, .violet, .magenta, .orange, .amber]

    public static func named(_ name: String) -> XAccentChoice? { all.first { $0.name == name } }
}

/// Every colour of an interface, by role. The surfaces and text are neutral grey; colour comes from two accents the
/// user chooses and two fixed state colours.
///
/// - `primary`: what is being edited or chosen: the selection, focus, a value's arc.
/// - `secondary`: what is live: the cell that is playing, an assigned controller, a value being changed.
/// - `success`: running (the output is on). `danger`: stop and error. Fixed hues, never chosen.
public struct XPalette: Equatable, Sendable {
    public struct Neutrals: Equatable, Sendable {
        /// The darkest: wells and fields, behind other surfaces.
        public let inset: XColorValue
        /// The bars at the top and the edges of the window.
        public let window: XColorValue
        /// A panel.
        public let panel: XColorValue
        /// A button or a cell on a panel.
        public let raised: XColorValue
        /// The same under the pointer, or selected without colour.
        public let raisedHigh: XColorValue
        /// A hairline.
        public let border: XColorValue
        public let borderStrong: XColorValue
        public let textDisabled: XColorValue
        public let textSecondary: XColorValue
        public let textPrimary: XColorValue

        init() {
            func grey(_ l: Double) -> XColorValue { XOKLCH(l, 0, 0).color }
            inset = grey(0.20)
            window = grey(0.235)
            panel = grey(0.26)
            raised = grey(0.30)
            raisedHigh = grey(0.345)
            border = grey(0.42)
            borderStrong = grey(0.50)
            textDisabled = grey(0.63)
            textSecondary = grey(0.73)
            textPrimary = grey(0.97)
        }
    }

    public static let defaultPrimary = XAccentChoice.blue
    public static let defaultSecondary = XAccentChoice.amber
    public static let successHue = 148.0
    public static let dangerHue = 25.0

    public let neutral: Neutrals
    public let primary: XAccent
    public let secondary: XAccent
    public let success: XAccent
    public let danger: XAccent

    /// Building a scale takes a few microseconds (30 colours through a gamut clamp), so a palette is made from scales
    /// kept per hue and from one shared set of neutrals. Reading `XPalette(...)` is then a handful of copies.
    private static let sharedNeutrals = Neutrals()

    public init(primary: XAccentChoice = defaultPrimary, secondary: XAccentChoice = defaultSecondary) {
        neutral = Self.sharedNeutrals
        self.primary = XAccent.cached(hue: primary.hue)
        self.secondary = XAccent.cached(hue: secondary.hue)
        success = XAccent.cached(hue: Self.successHue)
        danger = XAccent.cached(hue: Self.dangerHue)
    }

    public static let standard = XPalette()
}

private enum XPaletteKey: EnvironmentKey {
    static let defaultValue = XPalette.standard
}

public extension EnvironmentValues {
    /// The colours of the interface. Controls that are not given a colour read their own from here, so one palette set
    /// on the host recolours every text field, focus ring and keyboard.
    var palette: XPalette {
        get { self[XPaletteKey.self] }
        set { self[XPaletteKey.self] = newValue }
    }
}
