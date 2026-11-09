import Foundation
import XRender
import XRenderWGPU
import XUI
import XUIHost

/// A canvas shape to preview a view in. Logical size is what the view lays out
/// against; `scale` is device pixels per logical unit.
public struct PreviewShape: Sendable, Equatable {
    public var name: String
    public var width: Int
    public var height: Int
    public var scale: Float

    public init(_ name: String, width: Int, height: Int, scale: Float = 1) {
        self.name = name
        self.width = width
        self.height = height
        self.scale = scale
    }

    public static let phonePortrait = PreviewShape("phone-portrait", width: 390, height: 844)
    public static let phoneLandscape = PreviewShape("phone-landscape", width: 844, height: 390)
    public static let tablet = PreviewShape("tablet", width: 1194, height: 834)
    public static let square = PreviewShape("square", width: 600, height: 600)
    /// A short, wide box: a filmstrip dock or a status strip.
    public static let strip = PreviewShape("strip", width: 900, height: 200)
    /// A narrow, tall panel, such as a side drawer.
    public static let panel = PreviewShape("panel", width: 260, height: 640)

    public static let standard: [PreviewShape] = [.phonePortrait, .phoneLandscape, .tablet, .square, .strip, .panel]
}

/// What one preview cost to build, measured over repeated frames of the final state.
public struct PreviewStats: Sendable, Equatable {
    public var frames: Int
    public var meanMilliseconds: Double
    public var p95Milliseconds: Double
    public var maxMilliseconds: Double
    /// Draw commands in the scene.
    public var commands: Int
    /// Text-width requests per frame (the usual hidden cost).
    public var measureCalls: Int
    /// Distinct tap regions (a proxy for how many interactive nodes exist).
    public var tapRegions: Int

    public var summary: String {
        String(format: "%.3f ms mean, %.3f p95, %.3f max | %d commands, %d measureText, %d tap regions",
               meanMilliseconds, p95Milliseconds, maxMilliseconds, commands, measureCalls, tapRegions)
    }
}

public struct PreviewResult: Sendable {
    public var shape: PreviewShape
    public var png: Data
    public var stats: PreviewStats
}

public enum PreviewError: Error { case noRenderer, renderFailed }

/// What a preview script can do to the running view before the picture is taken.
@XUIActor
public final class PreviewDriver {
    public let host: XUIHost
    private let renderFrame: @XUIActor (Double) async -> XUIFrame
    private let pointerEvent: @XUIActor (PointerEvent) -> Bool
    private let keyEvent: @XUIActor (KeyEvent) -> Bool
    private(set) public var time = 0.0
    public private(set) var frame: XUIFrame?

    init(host: XUIHost, render: @escaping @XUIActor (Double) async -> XUIFrame,
         pointer: @escaping @XUIActor (PointerEvent) -> Bool, key: @escaping @XUIActor (KeyEvent) -> Bool) {
        self.host = host
        self.renderFrame = render
        self.pointerEvent = pointer
        self.keyEvent = key
    }

    /// Renders `count` frames, advancing the presentation clock `step` seconds each.
    @discardableResult
    public func advance(frames count: Int = 1, step: Double = 1.0 / 60) async -> XUIFrame {
        var last: XUIFrame?
        for _ in 0..<max(1, count) {
            time += step
            last = await renderFrame(time)
        }
        frame = last
        return last!
    }

    /// Taps the control or tap region with `id`. Returns false if there is none.
    @discardableResult
    public func tap(_ id: String) async -> Bool {
        let current = await advance()
        guard let target = current.layout.tapGestures.first(where: { $0.id == id }) else { return false }
        return tap(at: Point(x: target.rect.midX, y: target.rect.midY))
    }

    @discardableResult
    public func tap(at point: Point) -> Bool {
        let p = RenderPoint(x: Float(point.x), y: Float(point.y))
        let began = pointerEvent(PointerEvent(phase: .began, position: p, timestamp: time))
        _ = pointerEvent(PointerEvent(phase: .ended, position: p, timestamp: time))
        return began
    }

    /// Puts a finger down and leaves it there (a held key, a press in progress).
    @discardableResult
    public func press(at point: Point, id: Int = 1) -> Bool {
        pointerEvent(PointerEvent(id: id, phase: .began, position: RenderPoint(x: Float(point.x), y: Float(point.y)), timestamp: time))
    }

    /// Moves a finger that is down (see `press(at:)`).
    @discardableResult
    public func move(to point: Point, id: Int = 1) -> Bool {
        pointerEvent(PointerEvent(id: id, phase: .moved, position: RenderPoint(x: Float(point.x), y: Float(point.y)), timestamp: time))
    }

    /// Lifts a finger that is down.
    @discardableResult
    public func release(at point: Point, id: Int = 1) -> Bool {
        pointerEvent(PointerEvent(id: id, phase: .ended, position: RenderPoint(x: Float(point.x), y: Float(point.y)), timestamp: time))
    }

    /// Drags from one point to another in `steps` moves.
    public func drag(from a: Point, to b: Point, steps: Int = 6) {
        func rp(_ p: Point) -> RenderPoint { RenderPoint(x: Float(p.x), y: Float(p.y)) }
        _ = pointerEvent(PointerEvent(phase: .began, position: rp(a), timestamp: time))
        for i in 1...max(1, steps) {
            let t = Double(i) / Double(max(1, steps))
            _ = pointerEvent(PointerEvent(phase: .moved, position: rp(Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)), timestamp: time))
        }
        _ = pointerEvent(PointerEvent(phase: .ended, position: rp(b), timestamp: time))
    }

    @discardableResult
    public func key(_ event: KeyEvent) -> Bool { keyEvent(event) }

    /// Types text into the focused field.
    @discardableResult
    public func type(_ text: String) -> Bool { host.textInput(.insert(text)) }
}

/// Renders an `XView` the way the app would, headlessly, to a PNG plus a cost report.
///
///     let result = try await XPreview(fonts: fonts).render(.phonePortrait) { MyView() }
///     try result.png.write(to: url)
///
/// The same code path as the app (`XAppSession`, the scene compiler and the WebGPU
/// renderer), so what you see is what ships. Pass `script` to drive the view first:
/// tap controls, scroll, type, then settle.
public struct XPreview: Sendable {
    public var fonts: [FontRole: Data]
    public var background: RenderColor
    /// Frames rendered after the script, to measure cost. 0 skips measuring.
    public var measuredFrames: Int
    public var settleFrames: Int

    public init(fonts: [FontRole: Data] = [:], background: RenderColor = RenderColor(0.06, 0.07, 0.09, 1),
                measuredFrames: Int = 120, settleFrames: Int = 20) {
        self.fonts = fonts
        self.background = background
        self.measuredFrames = measuredFrames
        self.settleFrames = settleFrames
    }

    @XUIActor
    public func render<V: XView>(
        _ shape: PreviewShape,
        script: (@XUIActor (PreviewDriver) async -> Void)? = nil,
        @XViewBuilder content: @escaping @XUIActor () -> V
    ) async throws -> PreviewResult {
        let app = PreviewApp(content: content, configuration: XAppConfiguration(
            size: RenderSize(width: Float(shape.width), height: Float(shape.height)),
            background: background, fonts: fonts))
        let session = XApplication.session(app)
        let size = RenderSize(width: Float(shape.width), height: Float(shape.height))
        session.host.size = size
        let scale = shape.scale
        let driver = PreviewDriver(
            host: session.host,
            render: { time in await session.render(time: time, pixelScale: scale) },
            pointer: { session.pointer($0) },
            key: { session.key($0) })
        await driver.advance(frames: 3)
        if let script { await script(driver) }
        var last = await driver.advance(frames: max(1, settleFrames))

        // Cost of the final state, frame after frame.
        var samples: [Double] = []
        if measuredFrames > 0 {
            samples.reserveCapacity(measuredFrames)
            for _ in 0..<measuredFrames {
                let start = DispatchTime.now().uptimeNanoseconds
                last = await driver.advance()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
        }
        samples.sort()
        let stats = PreviewStats(
            frames: samples.count,
            meanMilliseconds: samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count),
            p95Milliseconds: samples.isEmpty ? 0 : samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))],
            maxMilliseconds: samples.last ?? 0,
            commands: last.scene.commands.count,
            measureCalls: last.stats.measureCalls,
            tapRegions: last.layout.tapGestures.count)

        guard let renderer = WGPURenderer(headless: ()) else { throw PreviewError.noRenderer }
        let pixels = RenderSize(width: size.width * scale, height: size.height * scale)
        for update in session.takeFontTextureUpdates() { update.apply(to: renderer) }
        let compiled = SceneCompiler.compile(last.scene, canvas: size, framebuffer: pixels, fonts: session.host.fonts)
        renderer.configure(width: UInt32(pixels.width), height: UInt32(pixels.height))
        guard let rgba = renderer.renderToImage(compiled, width: Int(pixels.width), height: Int(pixels.height)) else {
            throw PreviewError.renderFailed
        }
        let png = try XUIMCPImage(width: Int(pixels.width), height: Int(pixels.height), rgba: rgba).png()
        return PreviewResult(shape: shape, png: png, stats: stats)
    }
}

private struct PreviewApp<Content: XView>: XApp {
    let content: @XUIActor () -> Content
    let configuration: XAppConfiguration
    let delegate = PreviewDelegate()
    var body: Content { content() }
}

private final class PreviewDelegate: XAppDelegate, Sendable {
    init() {}
}
