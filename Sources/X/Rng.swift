private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &+ 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

/// Seeded, reproducible random state for the game simulation.
public struct Rng: Equatable, Hashable, Sendable, Codable {
    private var s0: UInt64
    private var s1: UInt64
    private var s2: UInt64
    private var s3: UInt64

    public init(seed: UInt64) {
        var mixer = SplitMix64(state: seed)
        s0 = mixer.next()
        s1 = mixer.next()
        s2 = mixer.next()
        s3 = mixer.next()
        if s0 | s1 | s2 | s3 == 0 {
            s0 = 0x9e37_79b9_7f4a_7c15
        }
    }

    public mutating func next() -> UInt64 {
        let result = rotl(s1 &* 5, 7) &* 9
        let t = s1 &<< 17

        s2 ^= s0
        s3 ^= s1
        s1 ^= s2
        s0 ^= s3
        s2 ^= t
        s3 = rotl(s3, 45)

        return result
    }

    private func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 {
        (x &<< k) | (x >> (64 &- k))
    }

    public func stream(_ label: UInt64) -> Rng {
        var mixer = SplitMix64(state: label)
        var seed = mixer.next()
        for word in [s0, s1, s2, s3] {
            mixer = SplitMix64(state: seed ^ word)
            seed = mixer.next()
        }
        return Rng(seed: seed)
    }

    public mutating func next(upperBound bound: UInt64) -> UInt64 {
        precondition(bound > 0, "upperBound must be positive")
        var product = next().multipliedFullWidth(by: bound)
        if product.low < bound {
            let threshold = (0 &- bound) % bound
            while product.low < threshold {
                product = next().multipliedFullWidth(by: bound)
            }
        }
        return product.high
    }

    public mutating func next(in range: Range<Int>) -> Int? {
        guard !range.isEmpty else { return nil }
        let span = UInt64(bitPattern: Int64(range.upperBound))
            &- UInt64(bitPattern: Int64(range.lowerBound))
        return range.lowerBound + Int(next(upperBound: span))
    }

    public mutating func nextDouble() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    public mutating func nextBool() -> Bool {
        next() >> 63 == 1
    }

    public mutating func shuffle<T>(_ elements: inout [T]) {
        guard elements.count > 1 else { return }
        for i in stride(from: elements.count - 1, to: 0, by: -1) {
            let j = Int(next(upperBound: UInt64(i + 1)))
            elements.swapAt(i, j)
        }
    }

    public mutating func pick<T>(_ elements: [T]) -> T? {
        guard !elements.isEmpty else { return nil }
        return elements[Int(next(upperBound: UInt64(elements.count)))]
    }
}
