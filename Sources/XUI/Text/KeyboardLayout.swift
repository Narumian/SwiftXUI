import Foundation

public enum KeyboardPage: Sendable, Equatable {
    case letters, numbers, symbols, numberPad
}

/// What a key does when it fires.
public enum KeyAction: Sendable, Equatable {
    case character(String)
    case shift
    case backspace
    case space
    case returnKey
    case page(KeyboardPage)
    case moveLeft, moveRight
    case hide
    /// An empty cell that only takes up room (the margins of the home row).
    case spacer
}

public enum KeyRole: Sendable, Equatable {
    /// An ordinary character key.
    case character
    /// Shift, backspace, page switches, arrows: a darker, secondary key.
    case function
    /// Return, drawn in the accent colour.
    case accent
}

public struct KeyboardKey: Sendable, Equatable {
    public var action: KeyAction
    public var label: String
    /// Relative width within its row.
    public var weight: Double
    public var role: KeyRole

    init(_ action: KeyAction, _ label: String, weight: Double = 1, role: KeyRole = .character) {
        self.action = action
        self.label = label
        self.weight = weight
        self.role = role
    }
}

public enum ShiftState: Sendable, Equatable {
    case off, once, capsLock
}

/// The rows of keys for each page. Pure data so every layout can be checked in a test.
public enum KeyboardLayout {
    public static func rows(
        page: KeyboardPage, shift: ShiftState, returnKey: TextReturnKey
    ) -> [[KeyboardKey]] {
        switch page {
        case .letters: return letters(shift: shift, returnKey: returnKey)
        case .numbers: return numbers(returnKey: returnKey)
        case .symbols: return symbols(returnKey: returnKey)
        case .numberPad: return numberPad(returnKey: returnKey)
        }
    }

    private static func chars(_ string: String, uppercase: Bool = false) -> [KeyboardKey] {
        string.map { KeyboardKey(.character(uppercase ? String($0).uppercased() : String($0)), uppercase ? String($0).uppercased() : String($0)) }
    }

    static func returnLabel(_ key: TextReturnKey) -> String {
        switch key {
        case .done: return "Done"
        case .search: return "Search"
        case .go: return "Go"
        case .next: return "Next"
        }
    }

    private static func bottomRow(pageKey: KeyboardKey, returnKey: TextReturnKey) -> [KeyboardKey] {
        [
            pageKey,
            KeyboardKey(.moveLeft, "◀", weight: 1, role: .function),
            KeyboardKey(.space, "space", weight: 4.4),
            KeyboardKey(.moveRight, "▶", weight: 1, role: .function),
            KeyboardKey(.hide, "⌄", weight: 1, role: .function),
            KeyboardKey(.returnKey, returnLabel(returnKey), weight: 2, role: .accent),
        ]
    }

    private static func letters(shift: ShiftState, returnKey: TextReturnKey) -> [[KeyboardKey]] {
        let upper = shift != .off
        let shiftLabel: String
        switch shift {
        case .off: shiftLabel = "⇧"
        case .once: shiftLabel = "⬆"
        case .capsLock: shiftLabel = "⇪"
        }
        return [
            chars("qwertyuiop", uppercase: upper),
            [KeyboardKey(.spacer, "", weight: 0.5)] + chars("asdfghjkl", uppercase: upper) + [KeyboardKey(.spacer, "", weight: 0.5)],
            [KeyboardKey(.shift, shiftLabel, weight: 1.5, role: .function)]
                + chars("zxcvbnm", uppercase: upper)
                + [KeyboardKey(.backspace, "⌫", weight: 1.5, role: .function)],
            bottomRow(pageKey: KeyboardKey(.page(.numbers), "123", weight: 1.5, role: .function), returnKey: returnKey),
        ]
    }

    private static func numbers(returnKey: TextReturnKey) -> [[KeyboardKey]] {
        [
            chars("1234567890"),
            chars("-/:;()$&@\""),
            [KeyboardKey(.page(.symbols), "#+=", weight: 1.5, role: .function)]
                + chars(".,?!'", uppercase: false).map { var k = $0; k.weight = 1.4; return k }
                + [KeyboardKey(.backspace, "⌫", weight: 1.5, role: .function)],
            bottomRow(pageKey: KeyboardKey(.page(.letters), "ABC", weight: 1.5, role: .function), returnKey: returnKey),
        ]
    }

    private static func symbols(returnKey: TextReturnKey) -> [[KeyboardKey]] {
        [
            chars("[]{}#%^*+="),
            chars("_\\|~<>€£¥•"),
            [KeyboardKey(.page(.numbers), "123", weight: 1.5, role: .function)]
                + chars(".,?!'", uppercase: false).map { var k = $0; k.weight = 1.4; return k }
                + [KeyboardKey(.backspace, "⌫", weight: 1.5, role: .function)],
            bottomRow(pageKey: KeyboardKey(.page(.letters), "ABC", weight: 1.5, role: .function), returnKey: returnKey),
        ]
    }

    private static func numberPad(returnKey: TextReturnKey) -> [[KeyboardKey]] {
        [
            chars("123") + [KeyboardKey(.backspace, "⌫", role: .function)],
            chars("456") + [KeyboardKey(.character("-"), "−", role: .function)],
            chars("789") + [KeyboardKey(.character("."), ".", role: .function)],
            [KeyboardKey(.moveLeft, "◀", role: .function), KeyboardKey(.character("0"), "0"),
             KeyboardKey(.moveRight, "▶", role: .function), KeyboardKey(.returnKey, returnLabel(returnKey), role: .accent)],
        ]
    }

    /// The page a field of `kind` starts on.
    public static func firstPage(for kind: TextInputKind) -> KeyboardPage {
        kind == .number ? .numberPad : .letters
    }
}

/// A key placed in the keyboard's rect.
package struct PlacedKey: Equatable {
    package var key: KeyboardKey
    package var rect: Rect
    /// Row and column, for hit testing.
    package var row: Int
    package var column: Int
}

/// Where the keyboard goes and how big its keys are, for the space available.
///
/// The keyboard adapts to the *shape* of the box, not just its size: on a tall box
/// the keys are as wide as the width allows; on a wide, short box (a phone in
/// landscape, a big screen) the keyboard is capped so it never swallows the
/// screen and sits centred rather than stretched edge to edge.
package struct KeyboardMetrics: Equatable {
    package var rect: Rect
    package var keyHeight: Double
    package var gap: Double
    package var padding: Double

    /// `container` is the whole area the keyboard may occupy (the app's box).
    package static func compute(container: Size, rowCount: Int, numberPad: Bool = false) -> KeyboardMetrics {
        let rows = Double(max(1, rowCount))
        // Narrower on wide boxes: keys stay finger-shaped instead of becoming planks.
        let maxWidth = numberPad ? min(container.width, container.height * 0.9)
                                 : min(container.width, container.height * 1.55)
        let width = max(0, maxWidth)
        let gap = max(3, min(width, container.height) * 0.012)
        let padding = max(4, gap * 1.5)
        // A key about 1.25× as tall as one tenth of the width is comfortable, but the whole
        // keyboard may use at most 48% of the height (and 4 rows must still fit).
        let columns = numberPad ? 4.0 : 10.0
        let idealKey = (width - padding * 2 - gap * (columns - 1)) / columns * 1.25
        let heightCap = (container.height * 0.48 - padding * 2 - gap * (rows - 1)) / rows
        let keyHeight = max(10, min(idealKey, heightCap))
        let height = rows * keyHeight + (rows - 1) * gap + padding * 2
        let x = (container.width - width) / 2
        return KeyboardMetrics(
            rect: Rect(x: x, y: container.height - height, width: width, height: height),
            keyHeight: keyHeight, gap: gap, padding: padding
        )
    }

    package var height: Double { rect.height }

    /// Positions the keys of `rows`; the weight of a row's keys decides their share of its width.
    package func place(_ rows: [[KeyboardKey]], in rect: Rect) -> [PlacedKey] {
        var placed: [PlacedKey] = []
        let innerWidth = rect.width - padding * 2
        for (rowIndex, row) in rows.enumerated() {
            let totalWeight = row.reduce(0) { $0 + $1.weight }
            let usable = innerWidth - gap * Double(row.count - 1)
            var x = rect.x + padding
            let y = rect.y + padding + Double(rowIndex) * (keyHeight + gap)
            for (column, key) in row.enumerated() {
                let w = usable * key.weight / totalWeight
                placed.append(PlacedKey(key: key, rect: Rect(x: x, y: y, width: w, height: keyHeight), row: rowIndex, column: column))
                x += w + gap
            }
        }
        return placed
    }

    private func distance(_ rect: Rect, _ x: Double) -> Double {
        x < rect.x ? rect.x - x : (x > rect.maxX ? x - rect.maxX : 0)
    }

    /// The key a finger at `point` means. Touches in the gaps and padding still
    /// resolve to the nearest key in that row, so there are no dead zones; spacer
    /// cells (the half-width margins of the home row) never fire.
    package func key(at point: Point, in placed: [PlacedKey], rect: Rect) -> PlacedKey? {
        guard point.x >= rect.x - gap, point.x <= rect.maxX + gap,
              point.y >= rect.y - gap, point.y <= rect.maxY + gap else { return nil }
        let pitch = keyHeight + gap
        let rowCount = (placed.map(\.row).max() ?? -1) + 1
        guard rowCount > 0 else { return nil }
        let rowIndex = min(max(0, Int(((point.y - rect.y - padding + gap / 2) / pitch).rounded(.down))), rowCount - 1)
        let candidates = placed.filter { $0.row == rowIndex && $0.key.action != .spacer }
        // The key whose span contains x, else (in a gap or margin) the nearest one.
        return candidates.min { distance($0.rect, point.x) < distance($1.rect, point.x) }
    }
}
