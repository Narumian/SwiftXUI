import Foundation

/// Colours and shape of the on-screen keyboard.
public struct KeyboardStyle: Sendable, Equatable {
    public var background = XColorValue(0.07, 0.075, 0.10)
    public var key = XColorValue(0.22, 0.24, 0.31)
    public var functionKey = XColorValue(0.14, 0.15, 0.20)
    public var accentKey = XColorValue(0.1, 0.62, 0.78)
    public var pressedKey = XColorValue(0.42, 0.46, 0.58)
    public var text = XColorValue(0.96, 0.96, 0.98)
    public var dimText = XColorValue(0.75, 0.77, 0.84)
    public var keyShadow = XColorValue(0, 0, 0, 0.35)
    public var cornerRadius: Double = 7
    public init() {}
}

/// Everything the keyboard remembers between frames: which page it is on, shift,
/// which fingers are down on which keys, and the key-repeat clock.
final class KeyboardRuntime: @unchecked Sendable {
    private struct Touch {
        var key: PlacedKey?
        var startedKey: KeyAction?
        var nextRepeat: Double?
        var repeats: Int = 0
    }

    private let lock = NSLock()
    private var page = KeyboardPage.letters
    private var pageFieldID: String?
    private var shift = ShiftState.off
    private var lastShiftTap = -10.0
    private var touches: [Int: Touch] = [:]
    private var now = 0.0
    // From the last draw.
    private var placed: [PlacedKey] = []
    private var metrics: KeyboardMetrics?
    private var keyboardRect: Rect = .zero

    private static let repeatDelay = 0.42
    private static let repeatInterval = 0.055
    private static let fastRepeatInterval = 0.032

    var pageValue: KeyboardPage { lock.withLock { page } }
    var shiftValue: ShiftState { lock.withLock { shift } }

    /// Switches pages when focus moves to a different field.
    func follow(field: TextFocusStore.Field) {
        lock.withLock {
            guard pageFieldID != field.id else { return }
            pageFieldID = field.id
            page = KeyboardLayout.firstPage(for: field.kind)
            shift = .off
            touches.removeAll()
        }
    }

    /// Handles one pointer sample, returning the text events and focus changes it caused.
    func pointer(_ input: PointerInput, store: TextFocusStore?) {
        var effects: [Effect] = []
        lock.withLock {
            switch input.phase {
            case .began:
                let key = hit(input.position)
                var touch = Touch(key: key, startedKey: key?.key.action)
                if let action = key?.key.action, Self.repeats(action) {
                    effects += fire(action)
                    touch.nextRepeat = now + Self.repeatDelay
                }
                touches[input.id] = touch
                if key != nil { effects.append(.feedback) }
            case .moved:
                guard var touch = touches[input.id] else { return }
                let key = hit(input.position)
                if key?.key.action != touch.key?.key.action || key?.row != touch.key?.row || key?.column != touch.key?.column {
                    touch.key = key
                    if key != nil { effects.append(.feedback) }
                    // A repeating key stops repeating once the finger leaves it.
                    if touch.startedKey != key?.key.action { touch.nextRepeat = nil }
                }
                touches[input.id] = touch
            case .ended:
                guard let touch = touches.removeValue(forKey: input.id), let key = hit(input.position) else { return }
                // A repeating key already fired on touch-down; lifting on it adds nothing.
                let alreadyFired = touch.startedKey.map(Self.repeats) == true && key.key.action == touch.startedKey
                if !alreadyFired { effects += fire(key.key.action) }
            case .cancelled:
                touches.removeValue(forKey: input.id)
            }
        }
        run(effects, store: store)
    }

    /// Advances the key-repeat clock; called once per drawn frame.
    func tick(time: Double, store: TextFocusStore?) {
        var effects: [Effect] = []
        lock.withLock {
            now = time
            for id in touches.keys {
                guard var touch = touches[id], let due = touch.nextRepeat, time >= due,
                      let key = touch.key, key.key.action == touch.startedKey else { continue }
                effects += fire(key.key.action)
                touch.repeats += 1
                let interval = touch.repeats > 14 ? Self.fastRepeatInterval : Self.repeatInterval
                touch.nextRepeat = max(due + interval, time - interval)
                touches[id] = touch
            }
        }
        run(effects, store: store)
    }

    private enum Effect {
        case send(TextInputEvent)
        case blur
        case feedback
    }

    private func run(_ effects: [Effect], store: TextFocusStore?) {
        guard let store else { return }
        for effect in effects {
            switch effect {
            case .send(let event): store.send(event)
            case .blur: store.blur()
            case .feedback: store.onKeyPress?()
            }
        }
    }

    private static func repeats(_ action: KeyAction) -> Bool {
        switch action {
        case .backspace, .moveLeft, .moveRight: return true
        default: return false
        }
    }

    private func fire(_ action: KeyAction) -> [Effect] {
        switch action {
        case .character(let text):
            let wasOnce = shift == .once
            if wasOnce { shift = .off }
            return [.send(.insert(text))]
        case .space: return [.send(.insert(" "))]
        case .backspace: return [.send(.deleteBackward)]
        case .returnKey: return [.send(.submit)]
        case .moveLeft: return [.send(.move(.left, extend: false))]
        case .moveRight: return [.send(.move(.right, extend: false))]
        case .hide: return [.blur]
        case .page(let next):
            page = next
            return []
        case .shift:
            switch shift {
            case .off:
                shift = .once
                lastShiftTap = now
            case .once:
                shift = now - lastShiftTap < 0.4 ? .capsLock : .off
            case .capsLock:
                shift = .off
            }
            return []
        case .spacer: return []
        }
    }

    private func hit(_ point: Point) -> PlacedKey? {
        guard let metrics else { return nil }
        return metrics.key(at: point, in: placed, rect: keyboardRect)
    }

    // MARK: - Drawing

    func draw(
        rect: Rect, field: TextFocusStore.Field, container: Size, context: RenderContext,
        style: KeyboardStyle, store: TextFocusStore?
    ) {
        follow(field: field)
        tick(time: context.environment.fxTime, store: store)

        let pressed = lock.withLock { () -> [PlacedKey] in
            let rows = KeyboardLayout.rows(page: page, shift: shift, returnKey: field.returnKey)
            let metrics = KeyboardMetrics.compute(container: container, rowCount: rows.count, numberPad: page == .numberPad)
            self.metrics = metrics
            // The keyboard's own rect may be offset from the metrics' (while sliding in).
            keyboardRect = Rect(x: metrics.rect.x, y: rect.y, width: metrics.rect.width, height: metrics.rect.height)
            placed = metrics.place(rows, in: keyboardRect)
            return touches.values.compactMap(\.key)
        }
        let (placedKeys, kbRect, shiftState) = lock.withLock { (placed, keyboardRect, shift) }
        let canvas = context.canvas

        store?.recordKeyboard(rect: kbRect) { [weak self] input in self?.pointer(input, store: store) }

        canvas.fillRoundedRect(kbRect, cornerRadius: style.cornerRadius * 1.6, color: style.background)
        let keyHeight = placedKeys.first?.rect.height ?? 40
        let labelSize = keyHeight * 0.38
        for placedKey in placedKeys {
            let key = placedKey.key
            if key.action == .spacer { continue }
            let isDown = pressed.contains { $0.row == placedKey.row && $0.column == placedKey.column }
            let base: XColorValue
            switch key.role {
            case .character: base = style.key
            case .function: base = style.functionKey
            case .accent: base = style.accentKey
            }
            var rect = placedKey.rect
            canvas.fillRoundedRect(rect.offsetBy(dx: 0, dy: 1.5), cornerRadius: style.cornerRadius, color: style.keyShadow)
            canvas.fillRoundedRect(rect, cornerRadius: style.cornerRadius, color: isDown ? style.pressedKey : base)
            let large = key.role == .character && key.action != .space
            let size = large ? labelSize : labelSize * 0.72
            let height = size * 1.3
            rect = Rect(x: rect.x, y: rect.midY - height / 2, width: rect.width, height: height)
            if KeyIcons.draw(key.action, shift: shiftState, in: placedKey.rect, color: key.role == .function ? style.dimText : style.text, canvas: canvas) {
                // Icons are drawn as shapes: no font carries these symbols reliably.
            } else if !key.label.isEmpty && key.action != .space {
                canvas.drawText(key.label, in: rect, fontSize: size, font: .ui,
                                color: key.role == .function ? style.dimText : style.text,
                                alignment: .center, outline: nil)
            }
        }
        // The pressed character, enlarged above the finger.
        for down in pressed {
            guard case .character = down.key.action, !down.key.label.isEmpty else { continue }
            let w = down.rect.width * 1.5, h = down.rect.height * 1.3
            var bubble = Rect(x: down.rect.midX - w / 2, y: down.rect.y - h - 4, width: w, height: h)
            bubble.x = min(max(kbRect.x, bubble.x), kbRect.maxX - w)
            canvas.fillRoundedRect(bubble, cornerRadius: style.cornerRadius * 1.4, color: style.pressedKey)
            let size = keyHeight * 0.7
            canvas.drawText(down.key.label, in: Rect(x: bubble.x, y: bubble.midY - size * 0.65, width: w, height: size * 1.3),
                            fontSize: size, font: .ui, color: style.text, alignment: .center, outline: nil)
        }
    }
}


/// Vector icons for the keys whose symbols a text font can not be trusted to carry.
enum KeyIcons {
    /// Draws the icon for `action` centred in `rect`. Returns false for keys that show text.
    static func draw(_ action: KeyAction, shift: ShiftState, in rect: Rect, color: XColorValue, canvas: any XCanvas) -> Bool {
        let cx = rect.midX, cy = rect.midY
        let s = min(rect.width, rect.height) * 0.26
        func p(_ x: Double, _ y: Double) -> Point { Point(x: cx + x * s, y: cy + y * s) }
        func fill(_ points: [Point]) {
            if let box = bounds(points) { canvas.fillPath(Path(points: points), in: box, color: color) }
        }
        func line(_ points: [Point], closed: Bool = false, width: Double = max(1.5, s * 0.22)) {
            if let box = bounds(points) { canvas.strokePath(Path(points: points, closed: closed), in: box, color: color, lineWidth: width) }
        }
        switch action {
        case .moveLeft:
            fill([p(0.6, -0.9), p(-0.7, 0), p(0.6, 0.9)])
        case .moveRight:
            fill([p(-0.6, -0.9), p(0.7, 0), p(-0.6, 0.9)])
        case .hide:
            line([p(-1, -0.4), p(0, 0.6), p(1, -0.4)])
        case .backspace:
            line([p(-1.3, 0), p(-0.6, -0.85), p(1.2, -0.85), p(1.2, 0.85), p(-0.6, 0.85)], closed: true)
            line([p(-0.1, -0.35), p(0.7, 0.35)])
            line([p(0.7, -0.35), p(-0.1, 0.35)])
        case .shift:
            let arrow = [p(0, -1), p(1, 0.1), p(0.38, 0.1), p(0.38, 0.8), p(-0.38, 0.8), p(-0.38, 0.1), p(-1, 0.1)]
            if shift == .off { line(arrow, closed: true) } else { fill(arrow) }
            if shift == .capsLock {
                fill([p(-0.38, 1.0), p(0.38, 1.0), p(0.38, 1.25), p(-0.38, 1.25)])
            }
        default:
            return false
        }
        return true
    }

    /// The tight box around `points`, widened to a hair when degenerate so the fit never divides by zero.
    private static func bounds(_ points: [Point]) -> Rect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return Rect(x: minX, y: minY, width: max(0.01, maxX - minX), height: max(0.01, maxY - minY))
    }
}
