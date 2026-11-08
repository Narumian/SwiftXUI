import Foundation

extension LaserChunk {
    /// A chunk of `elements` that carries over the runs and frame ends of `source`.
    /// `starts[i]` is where the output for source element `i` begins and
    /// `starts[source.count]` is the output's end, so a stage that adds or drops
    /// elements only has to say where each input landed.
    init<Source>(elements: [Element], carrying source: LaserChunk<Source>, starts: [Int]) {
        self.init(elements: elements)
        for run in source.runs {
            let range = starts[run.range.lowerBound]..<starts[run.range.upperBound]
            if !range.isEmpty { runs.append(LaserRun(id: run.id, range: range)) }
        }
        for end in source.frameEnds where end >= 1 && end <= source.count {
            let mapped = starts[end]
            if mapped > 0, mapped > (frameEnds.last ?? 0) { frameEnds.append(mapped) }
        }
    }
}

/// A step between two streams: takes the chunks of its upstream and returns the
/// chunks of its downstream. It may keep state from one chunk to the next, and it
/// may return more or fewer elements than it was given.
public protocol LaserStage: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable
    mutating func process(_ chunk: LaserChunk<Input>) -> LaserChunk<Output>
}

/// A stream read through a stage. The count asked for is passed upstream as it is:
/// a stage that adds or drops elements makes the answer a different size, which the
/// reader on the far end already allows for.
public struct LaserStagedStream<Upstream: LaserStream, Stage: LaserStage>: LaserStream where Upstream.Element == Stage.Input {
    public private(set) var upstream: Upstream
    public var stage: Stage
    public let format: LaserStreamFormat

    public init(_ upstream: Upstream, stage: Stage, format: LaserStreamFormat) {
        self.upstream = upstream; self.stage = stage; self.format = format
    }

    public mutating func read(wanting count: Int) -> LaserChunk<Stage.Output> {
        stage.process(upstream.read(wanting: count))
    }
}

extension LaserStagedStream: LaserOutputStream where Stage.Output == LaserPoint {}
