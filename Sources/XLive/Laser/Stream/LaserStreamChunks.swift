import Foundation

/// A scanner stream as the async sequence of sample chunks that
/// `LaserOutputStreams.play(source:sampleRate:for:)` takes. It reads the stream in
/// blocks of up to `chunkSize` and, when the stream has nothing for the moment,
/// waits `idleMilliseconds` and asks again. It ends when its task is cancelled.
///
/// This is where a stream's "never waits" rule meets the pump's bounded ring: the
/// stream is read on the source's own task, at the pace the ring accepts samples.
public struct LaserStreamChunks<Stream: Laser2DStream>: AsyncSequence, Sendable {
    public typealias Element = [LaserPoint]

    private let stream: Stream
    private let chunkSize: Int
    private let idleNanoseconds: UInt64

    public init(_ stream: Stream, chunkSize: Int = 512, idleMilliseconds: Int = 2) {
        self.stream = stream
        self.chunkSize = Swift.max(1, chunkSize)
        idleNanoseconds = UInt64(Swift.max(1, idleMilliseconds)) * 1_000_000
    }

    public func makeAsyncIterator() -> Iterator { Iterator(reader: LaserReader(stream), chunkSize: chunkSize, idleNanoseconds: idleNanoseconds) }

    public struct Iterator: AsyncIteratorProtocol {
        fileprivate var reader: LaserReader<Stream>
        fileprivate let chunkSize: Int
        fileprivate let idleNanoseconds: UInt64

        public mutating func next() async -> [LaserPoint]? {
            while !Task.isCancelled {
                let chunk = reader.take(chunkSize)
                if !chunk.isEmpty { return chunk }
                try? await Task.sleep(nanoseconds: idleNanoseconds)
            }
            return nil
        }
    }
}

extension LaserOutputStreams {
    /// Plays a scanner stream in a zone at the rate the stream declares, replacing any
    /// pattern on the zone's outputs and the zone's earlier source.
    public func play<Stream: Laser2DStream>(stream: Stream, chunkSize: Int = 512, zone: UUID = LaserOutputStreams.defaultZone) throws {
        guard let rate = stream.rate, rate > 0 else { throw LaserOutputError.unsupportedPointRate }
        try play(source: LaserStreamChunks(stream, chunkSize: chunkSize), sampleRate: rate, zone: zone)
    }
}
