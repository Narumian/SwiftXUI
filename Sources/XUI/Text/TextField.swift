import Foundation

/// How a `TextField` looks. Every colour is explicit so an app can match its theme.
public struct TextFieldStyle: Sendable, Equatable {
    public var fontSize: Double = 17
    public var font: TextFont = .ui
    public var textColor = XColorValue(0.95, 0.95, 0.97)
    public var placeholderColor = XColorValue(0.55, 0.56, 0.62)
    public var background = XColorValue(0.12, 0.13, 0.17)
    public var border = XColorValue(0.28, 0.30, 0.38)
    public var focusedBorder = XColorValue(0.1, 0.85, 1)
    public var selection = XColorValue(0.1, 0.85, 1, 0.35)
    public var caret = XColorValue(0.1, 0.85, 1)
    public var cornerRadius: Double = 10
    public var horizontalPadding: Double = 12
    public var verticalPadding: Double = 9
    public var borderWidth: Double = 1.5

    public init() {}
}

/// A single-line text field.
///
/// XUI owns the editing: the text lives in `text`, the caret / selection /
/// input-method composition live here, and every input source (hardware keys,
/// the XUI on-screen keyboard, an OS input method) arrives as the same
/// `TextInputEvent` through `TextFocusStore`. The OS soft keyboard is never
/// involved.
///
/// Touch / click: pressing places the caret between the glyphs under the finger,
/// dragging selects, a quick second press selects the word. The text scrolls
/// to keep the caret in view; the caret blinks and holds steady while typing.
public struct TextField: XView, _PrimitiveXView {
    public typealias Body = Never

    let placeholder: String
    let text: Binding<String>
    let id: String
    let kind: TextInputKind
    let returnKey: TextReturnKey
    let style: TextFieldStyle
    let onSubmit: (@Sendable () -> Void)?
    let autofocus: Bool

    public init(
        _ placeholder: String = "",
        text: Binding<String>,
        id: String,
        kind: TextInputKind = .text,
        returnKey: TextReturnKey = .done,
        style: TextFieldStyle = TextFieldStyle(),
        autofocus: Bool = false,
        onSubmit: (@Sendable () -> Void)? = nil
    ) {
        self.placeholder = placeholder
        self.text = text
        self.id = id
        self.kind = kind
        self.returnKey = returnKey
        self.style = style
        self.onSubmit = onSubmit
        self.autofocus = autofocus
    }

    @XUIActor
    func _lower(id stateID: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let runtime = store.box(for: stateID.child(type: TextFieldRuntime.self)) { TextFieldRuntime() }.value
        let (placeholder, text, fieldID, kind, returnKey, style, onSubmit) =
            (placeholder, text, id, kind, returnKey, style, onSubmit)
        let focusStore = _EnvironmentObjectContext.currentOrEmpty.object(TextFocusStore.self)

        // Focus once, the first time the field is declared (a search row that just opened).
        if autofocus, runtime.claimAutofocus() { focusStore?.focus(fieldID) }

        let height = style.fontSize * 1.3 + style.verticalPadding * 2
        let node = LayoutNode(layout: TextFieldLayout(height: height))
        node.control = XControl(id: ControlID(rawValue: fieldID), label: placeholder.isEmpty ? fieldID : placeholder)

        // Automation and gamepad "confirm" land here: focus with the caret at the end.
        node.tapGesture = { [weak focusStore] in
            runtime.focusAtEnd(text: text.wrappedValue)
            focusStore?.focus(fieldID)
        }
        node.tapGestureID = fieldID
        node.tapGestureLabel = placeholder.isEmpty ? fieldID : placeholder

        node.dragGesture = DragGesture(minimumDistance: 0)
            .onChanged { [weak focusStore] value in
                focusStore?.focus(fieldID)
                runtime.pointer(value, text: text.wrappedValue)
            }
            .onEnded { _ in runtime.endPointer() }

        let handler: @Sendable (TextInputEvent) -> Void = { event in
            if let changed = runtime.handle(event, current: text.wrappedValue) {
                if changed != text.wrappedValue { text.wrappedValue = changed }
            }
            switch event {
            case .submit:
                if returnKey == .next, let focusStore {
                    focusStore.focusNext()
                } else {
                    onSubmit?()
                    // Done / Search / Go end the editing session, like every native field.
                    focusStore?.blur()
                }
            case .cancel:
                focusStore?.blur()
            default: break
            }
        }

        node.draw = { rect, context in
            focusStore?.record(
                id: fieldID, rect: rect, kind: kind, returnKey: returnKey,
                selectedText: { runtime.selectedText(current: text.wrappedValue) }, handler: handler
            )
            let focused = focusStore?.isFocused(fieldID) ?? false
            runtime.draw(
                rect: rect, context: context, text: text.wrappedValue, placeholder: placeholder,
                focused: focused, style: style
            )
        }
        return [node]
    }
}

struct TextFieldLayout: NodeLayout {
    var height: Double

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        Size(width: proposal.width ?? 200, height: height)
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {}
}

/// The state of one field that outlives a frame: editing state, scroll, caret blink,
/// and what the last draw measured (so pointer input can map x → character).
final class TextFieldRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var editing = TextEditing()
    private var scrollX = 0.0
    private var blinkOrigin = 0.0
    private var seenRevision = -1
    private var pointerAnchor: Int?
    private var lastPress: (time: Double, offset: Int)?
    // From the last draw.
    private var contentX = 0.0
    private var drawFontSize = 17.0
    private var drawFont = TextFont.ui
    private var measure: TextMeasurer?

    /// Applies an event. Returns the text to write back, or nil if nothing about the text changed.
    func handle(_ event: TextInputEvent, current: String) -> String? {
        lock.withLock {
            editing.reconcile(with: current)
            let changed = editing.apply(event)
            return changed ? editing.text : nil
        }
    }

    private var didAutofocus = false
    func claimAutofocus() -> Bool {
        lock.withLock {
            defer { didAutofocus = true }
            return !didAutofocus
        }
    }

    func selectedText(current: String) -> String? {
        lock.withLock {
            editing.reconcile(with: current)
            return editing.selection.map { editing.substring($0) }
        }
    }

    func focusAtEnd(text: String) {
        lock.withLock {
            editing.reconcile(with: text)
            editing.place(caret: editing.count)
        }
    }

    private func metrics() -> TextMetrics? {
        guard let measure else { return nil }
        return TextMetrics(text: editing, fontSize: drawFontSize, font: drawFont, measure: measure)
    }

    /// Press / drag. A press (zero translation) places the caret, or selects a word on a
    /// quick second press; a drag from there selects.
    func pointer(_ value: DragGestureValue, text: String) {
        lock.withLock {
            editing.reconcile(with: text)
            guard let metrics = metrics() else { return }
            let offset = metrics.offset(at: value.location.x - contentX)
            if value.translation == .zero {
                let doubled = value.time > 0 && lastPress.map { value.time - $0.time < 0.35 && abs($0.offset - offset) <= 1 } == true
                if doubled {
                    editing.selectWord(at: offset)
                    pointerAnchor = nil
                    lastPress = nil
                } else {
                    editing.place(caret: offset)
                    pointerAnchor = editing.caret
                    lastPress = (value.time, offset)
                }
            } else if let anchor = pointerAnchor {
                editing.select(from: anchor, to: offset)
            }
        }
    }

    func endPointer() {
        lock.withLock { pointerAnchor = nil }
    }

    func draw(rect: Rect, context: RenderContext, text: String, placeholder: String, focused: Bool, style: TextFieldStyle) {
        let canvas = context.canvas
        let measure = context.environment.measureText
        let time = context.environment.fxTime

        let (caretX, selectionX, markedX, textWidth, scroll, blinkOn) = lock.withLock { () -> (Double, (Double, Double)?, (Double, Double)?, Double, Double, Bool) in
            editing.reconcile(with: text)
            self.measure = measure
            drawFontSize = style.fontSize
            drawFont = style.font
            let metrics = TextMetrics(text: editing, fontSize: style.fontSize, font: style.font, measure: measure)
            let innerWidth = rect.width - style.horizontalPadding * 2
            let caretX = metrics.x(of: editing.caret)
            let textWidth = metrics.totalWidth
            scrollX = TextMetrics.scroll(
                current: scrollX, caretX: caretX, textWidth: textWidth, visibleWidth: innerWidth, caretWidth: 2
            )
            contentX = rect.x + style.horizontalPadding - scrollX
            if editing.revision != seenRevision {
                seenRevision = editing.revision
                blinkOrigin = time
            }
            let selection = editing.selection.map { (metrics.x(of: $0.lowerBound), metrics.x(of: $0.upperBound)) }
            let marked = editing.marked.map { (metrics.x(of: $0.lowerBound), metrics.x(of: $0.upperBound)) }
            // Solid for the first half second after an edit or move, then 530 ms on / 530 ms off.
            let sinceEdit = time - blinkOrigin
            let on = sinceEdit < 0.5 || Int(((sinceEdit - 0.5) / 0.53).rounded(.down)) % 2 == 1
            return (caretX, selection, marked, textWidth, scrollX, on)
        }

        // Frame.
        canvas.fillRoundedRect(rect, cornerRadius: style.cornerRadius, color: style.background)
        let inner = Rect(
            x: rect.x + style.horizontalPadding, y: rect.y,
            width: max(0, rect.width - style.horizontalPadding * 2), height: rect.height
        )
        canvas.pushClip(inner)
        let lineHeight = style.fontSize * 1.3
        let lineY = rect.y + (rect.height - lineHeight) / 2
        let originX = inner.x - scroll

        if let (from, to) = selectionX {
            canvas.fillRect(Rect(x: originX + from, y: lineY, width: to - from, height: lineHeight), color: style.selection)
        }
        if text.isEmpty {
            if !placeholder.isEmpty {
                canvas.drawText(
                    placeholder, in: Rect(x: inner.x, y: lineY, width: inner.width, height: lineHeight),
                    fontSize: style.fontSize, font: style.font, color: style.placeholderColor,
                    alignment: .leading, outline: nil
                )
            }
        } else {
            canvas.drawText(
                text, in: Rect(x: originX, y: lineY, width: textWidth + 4, height: lineHeight),
                fontSize: style.fontSize, font: style.font, color: style.textColor,
                alignment: .leading, outline: nil
            )
        }
        if let (from, to) = markedX {
            // The composition is underlined until it is confirmed.
            canvas.fillRect(Rect(x: originX + from, y: lineY + lineHeight - 2, width: max(2, to - from), height: 2), color: style.caret)
        }
        if focused, blinkOn, selectionX == nil {
            canvas.fillRect(Rect(x: originX + caretX - 1, y: lineY + 1, width: 2, height: lineHeight - 2), color: style.caret)
        }
        canvas.popClip()

        canvas.strokeRoundedRect(
            rect.inset(by: EdgeInsets(style.borderWidth / 2)),
            cornerRadius: style.cornerRadius,
            color: focused ? style.focusedBorder : style.border,
            lineWidth: focused ? style.borderWidth + 0.5 : style.borderWidth
        )
    }
}
