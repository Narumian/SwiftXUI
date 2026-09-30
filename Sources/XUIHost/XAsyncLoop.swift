import Foundation
import XRender
import XUI

/// An event-driven frame loop. It sleeps while the app is clean and coalesces
/// invalidations into one best-effort frame, capped by the device's FPS limit.
@XUIActor
final class XAsyncLoop<App: XApp> {
    private let driver: XAppDriver<App>
    private let framebuffer: RenderSize?
    private let fit: Bool
    private let interval: Duration
    private let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    private var task: Task<Void, Never>?
    private var needsDraw = false
    private var lastDraw: ContinuousClock.Instant?
    private let clock = ContinuousClock()
    private let startedAt = Date.timeIntervalSinceReferenceDate

    init(
        driver: XAppDriver<App>,
        maxFPS: Double,
        framebuffer: RenderSize? = nil,
        fit: Bool = true
    ) {
        self.driver = driver
        self.framebuffer = framebuffer
        self.fit = fit
        self.interval = .nanoseconds(Int64(1_000_000_000 / max(1, maxFPS)))

        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.events = stream.stream
        self.continuation = stream.continuation
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
        }
        setNeedsDisplay()
    }

    func setNeedsDisplay() {
        needsDraw = true
        continuation.yield(())
    }

    func stop() {
        task?.cancel()
        task = nil
        continuation.yield(())
    }

    private func run() async {
        for await _ in events {
            guard !Task.isCancelled, needsDraw else { continue }

            if let lastDraw {
                try? await clock.sleep(until: lastDraw.advanced(by: interval))
            }
            guard !Task.isCancelled else { return }

            needsDraw = false
            let now = clock.now
            lastDraw = now
            let time = Date.timeIntervalSinceReferenceDate - startedAt
            _ = await driver.frame(at: time, framebuffer: framebuffer, fit: fit)

            if needsDraw {
                continuation.yield(())
            }
        }
    }
}
