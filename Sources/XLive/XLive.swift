import XUI

/// An immutable snapshot shared by components during one host update.
public struct LiveUpdateContext: Sendable {
    public let deltaTime: Double
    public let tempo: LiveTempo?
    public init(deltaTime: Double, tempo: LiveTempo? = nil) {
        self.deltaTime = deltaTime; self.tempo = tempo
    }
}

/// Beat position is continuous and measured in beats, not bars.
public struct LiveTempo: Sendable {
    public let bpm: Double
    public let beatPosition: Double
    public init(bpm: Double, beatPosition: Double) {
        self.bpm = bpm; self.beatPosition = beatPosition
    }
}

/// A live performance component with an XUI representation and time-driven state.
/// The host serially updates and retains the mutated value; this is not an audio callback.
///
/// A component is `Codable`: what it encodes is the state a saved session needs to bring it
/// back (its parameters and where they are), not caches or handles it can rebuild.
public protocol XLive: XView, Codable, Sendable {
    mutating func update(context: LiveUpdateContext) async
}
