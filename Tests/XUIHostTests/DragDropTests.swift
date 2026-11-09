import Foundation
import Testing
import XRender
import XUI
@testable import XUIHost

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

private let screen = RenderSize(width: 400, height: 400)
private let sourceCenter = Point(x: 60, y: 60)
private let targetCenter = Point(x: 60, y: 260)

/// A draggable square above a drop target, both 100 wide, inside a `DragDropArea`.

@XUIActor
private struct Scene {
    let host = XUIHost(size: screen)
    let log = Log()
    var time = 0.0
    var menu = false
    var activation: DragActivation = .automatic
    var acceptsDrops = true
    var lastFrame: XUIFrame?

    @XUIActor
    mutating func render(advance dt: Double = 0.02) async -> XUIFrame {
        time += dt
        let log = log, menu = menu, activation = activation, accepts = acceptsDrops
        let source = Color.red.frame(width: .pt(100), height: .pt(100))
            .onTapGesture(id: "tap", label: "tap") { log.add("tap") }
            .draggable("item", activation: activation)
        let frame = await host.render(DragDropArea {
            VStack(spacing: 100) {
                if menu {
                    source.contextMenu { [ContextMenuItem("Rename") { log.add("rename") }, ContextMenuItem("Delete", role: .destructive) { log.add("delete") }] }
                } else {
                    source
                }
                Color.blue.frame(width: .pt(100), height: .pt(100))
                    .dropDestination(for: String.self, isValid: { _ in accepts }, isTargeted: { log.add($0 ? "enter" : "leave") }) { items, _ in
                        log.add("drop:\(items.first ?? "")")
                        return true
                    }
            }.padding(10).frame(width: .fraction(1), height: .fraction(1), alignment: .topLeading)
        }, time: time)
        lastFrame = frame
        return frame
    }

    @XUIActor
    mutating func run(seconds: Double) async {
        let steps = Int((seconds / 0.02).rounded(.up))
        for _ in 0..<steps { _ = await render() }
    }

    @XUIActor
    mutating func point(_ phase: PointerPhase, _ p: Point) async {
        if lastFrame == nil { _ = await render() }
        _ = host.pointer(PointerEvent(phase: phase, position: RenderPoint(x: Float(p.x), y: Float(p.y)), timestamp: time), in: lastFrame!)
    }
}

@Test @XUIActor
func holdingLiftsAndReleasingOverATargetDrops() async {
    var s = Scene()
    _ = await s.render()
    await s.point(.began, sourceCenter)
    #expect(!s.host.dragDrop.isDragging)
    await s.run(seconds: 0.3)
    #expect(s.host.dragDrop.isDragging)

    await s.point(.moved, targetCenter)
    _ = await s.render()
    #expect(s.log.all == ["enter"])
    await s.point(.ended, targetCenter)
    #expect(s.log.all == ["enter", "leave", "drop:item"])
    #expect(s.log.all.contains("drop:item"))

    // The preview lands, then the drag is over.
    await s.run(seconds: 0.4)
    #expect(!s.host.dragDrop.isDragging)
}

@Test @XUIActor
func movingBeforeTheHoldLeavesThePressToScrolling() async {
    var s = Scene()
    _ = await s.render()
    await s.point(.began, sourceCenter)
    await s.point(.moved, Point(x: 60, y: 160))
    await s.run(seconds: 0.4)
    #expect(!s.host.dragDrop.isDragging)
}

@Test @XUIActor
func aQuickTapStillTaps() async {
    var s = Scene()
    _ = await s.render()
    await s.point(.began, sourceCenter)
    await s.run(seconds: 0.05)
    await s.point(.ended, sourceCenter)
    #expect(s.log.all == ["tap"])
}

@Test @XUIActor
func releasingAwayFromEveryTargetSpringsBack() async {
    var s = Scene()
    _ = await s.render()
    await s.point(.began, sourceCenter)
    await s.run(seconds: 0.3)
    await s.point(.moved, Point(x: 300, y: 150))
    _ = await s.render()
    await s.point(.ended, Point(x: 300, y: 150))
    #expect(s.host.dragDrop.isDragging)
    await s.run(seconds: 1.5)
    #expect(!s.host.dragDrop.isDragging)
    #expect(s.log.all.isEmpty)
}

@Test @XUIActor
func aMovementActivationLiftsWithoutWaiting() async {
    var s = Scene()
    s.activation = .movement(8)
    _ = await s.render()
    await s.point(.began, sourceCenter)
    #expect(!s.host.dragDrop.isDragging)
    await s.point(.moved, Point(x: 60, y: 75))
    #expect(s.host.dragDrop.isDragging)
}

@Test @XUIActor
func aTargetThatRefusesTheValueIsNotTargeted() async {
    var s = Scene()
    s.acceptsDrops = false
    _ = await s.render()
    await s.point(.began, sourceCenter)
    await s.run(seconds: 0.3)
    await s.point(.moved, targetCenter)
    _ = await s.render()
    await s.point(.ended, targetCenter)
    #expect(s.log.all.isEmpty)
}

@Test @XUIActor
func liftingAndReleasingInPlaceOpensTheContextMenu() async throws {
    var s = Scene()
    s.menu = true
    _ = await s.render()
    await s.point(.began, sourceCenter)
    await s.run(seconds: 0.3)
    #expect(s.host.dragDrop.isDragging)
    await s.point(.ended, sourceCenter)
    #expect(s.host.dragDrop.isMenuOpen)

    let frame = await s.render()
    let rename = try #require(frame.layout.tapGestures.first { $0.id == "context-menu.0" })
    #expect(frame.layout.tapGestures.first { $0.id == "context-menu.1" } != nil)
    // The screen behind the menu does not take presses while it is open.
    #expect(!frame.layout.tapGestures.contains { $0.id == "tap" })
    _ = s.host.pointer(PointerEvent(phase: .began, position: RenderPoint(x: Float(rename.rect.midX), y: Float(rename.rect.midY))), in: frame)
    _ = s.host.pointer(PointerEvent(phase: .ended, position: RenderPoint(x: Float(rename.rect.midX), y: Float(rename.rect.midY))), in: frame)
    #expect(s.log.all == ["rename"])
    #expect(!s.host.dragDrop.isMenuOpen)
}

@Test @XUIActor
func aSecondaryClickOpensTheMenuAndAScrimTapClosesIt() async throws {
    var s = Scene()
    s.menu = true
    _ = await s.render()
    #expect(s.host.contextClick(at: RenderPoint(x: 60, y: 60)))
    #expect(s.host.dragDrop.isMenuOpen)
    let frame = await s.render()
    let dismiss = try #require(frame.layout.tapGestures.first { $0.id == "context-menu-dismiss" })
    let away = RenderPoint(x: Float(dismiss.rect.maxX - 5), y: Float(dismiss.rect.maxY - 5))
    _ = s.host.pointer(PointerEvent(phase: .began, position: away), in: frame)
    _ = s.host.pointer(PointerEvent(phase: .ended, position: away), in: frame)
    #expect(!s.host.dragDrop.isMenuOpen)
    #expect(s.log.all.isEmpty)
}

@Test @XUIActor
func aSecondaryClickOutsideEveryMenuViewDoesNothing() async throws {
    var s = Scene()
    s.menu = true
    _ = await s.render()
    #expect(s.host.contextClick(at: RenderPoint(x: 395, y: 395)) == false)
    // The lone draggable is in the corner; a click there is outside every menu view.
    _ = await s.render()
    #expect(!s.host.dragDrop.isMenuOpen)
}
