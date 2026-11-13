import Foundation

/// A Zone turned into the stream of points an output plays: each frame is rendered, run through the scanner chain
/// and handed on. Frames are of any length.
public struct ZoneSampleStream: AsyncSequence, Sendable {
    public typealias Element = [LaserPoint]

    let source: any ZoneSource
    let settings: LaserLive<LaserScannerSettings>
    let projection: LaserProjection
    let sampleRate: UInt32

    public init(_ delivery: ZoneDelivery) {
        self.init(source: delivery.source, settings: delivery.scanner, projection: delivery.projection,
                  sampleRate: delivery.sampleRate)
    }

    public init(source: any ZoneSource, settings: LaserLive<LaserScannerSettings>, projection: LaserProjection,
                sampleRate: UInt32) {
        self.source = source
        self.settings = settings
        self.projection = projection
        self.sampleRate = Swift.max(1, sampleRate)
    }

    public func makeAsyncIterator() -> Iterator {
        let shapes = source.shapes
        let chain = LaserScannerChain(shapes, projection: projection, live: settings,
                                      mastering: source.mastering, rate: sampleRate)
        return Iterator(source: source, shapes: shapes, chain: chain, sampleRate: sampleRate)
    }

    public struct Iterator: AsyncIteratorProtocol {
        let source: any ZoneSource
        let shapes: LaserLive<Laser3DBuffer>
        var chain: LaserScannerChain
        let sampleRate: UInt32
        var frameSamples = 0

        public mutating func next() async -> [LaserPoint]? {
            guard !Task.isCancelled else { return nil }
            let frame = await source.renderNextFrame(afterSamples: frameSamples, sampleRate: sampleRate)
            shapes.value = frame
            let points = chain.read().flatMap(\.points)
            let result = points.isEmpty ? LaserPoint.blackCenter(count: 512) : points
            frameSamples = result.count
            return result
        }
    }
}
