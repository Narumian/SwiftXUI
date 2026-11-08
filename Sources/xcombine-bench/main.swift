// XCombine vs Apple's Combine, same scenarios on both.
//
//   swift build -c release --product xcombine-bench && .build/release/xcombine-bench
//
// Each scenario builds its own graph, drives it, and folds every delivered value into a
// checksum so the optimizer cannot discard the work. Times are the median of several runs,
// reported per operation (a send, a delivery, or a subscribe+cancel cycle).

import Foundation
import XCombine
#if canImport(Combine)
import Combine
#endif

final class Sum: @unchecked Sendable { var n = 0 }

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) }

func median(_ body: () -> Void, runs: Int = 7) -> Double {
    body() // warm-up
    var samples: [Double] = []
    for _ in 0..<runs {
        let t0 = now()
        body()
        samples.append(now() - t0)
    }
    samples.sort()
    return samples[samples.count / 2]
}

struct Scenario {
    let name: String
    let ops: Int
    let x: (Sum) -> Void
    let c: ((Sum) -> Void)?
}

#if canImport(Combine)
func combine(_ body: @escaping (Sum) -> Void) -> ((Sum) -> Void)? { body }
#else
func combine(_ body: @escaping (Sum) -> Void) -> ((Sum) -> Void)? { nil }
#endif

let N = Int(ProcessInfo.processInfo.environment["XB_N"] ?? "") ?? 1_000_000

var scenarios: [Scenario] = []

scenarios.append(Scenario(name: "passthrough → 1 sink", ops: N, x: { s in
    let subject = XPassthroughSubject<Int, Never>()
    let t = subject.sink { s.n &+= $0 }
    for i in 0..<N { subject.send(i) }
    t.cancel()
}, c: combine { s in
    #if canImport(Combine)
    let subject = PassthroughSubject<Int, Never>()
    let t = subject.sink { s.n &+= $0 }
    for i in 0..<N { subject.send(i) }
    t.cancel()
    #endif
}))

scenarios.append(Scenario(name: "passthrough → 16 sinks (per delivery)", ops: N / 4 * 16, x: { s in
    let subject = XPassthroughSubject<Int, Never>()
    let ts = (0..<16).map { _ in subject.sink { s.n &+= $0 } }
    for i in 0..<(N / 4) { subject.send(i) }
    ts.forEach { $0.cancel() }
}, c: combine { s in
    #if canImport(Combine)
    let subject = PassthroughSubject<Int, Never>()
    let ts = (0..<16).map { _ in subject.sink { s.n &+= $0 } }
    for i in 0..<(N / 4) { subject.send(i) }
    ts.forEach { $0.cancel() }
    #endif
}))

scenarios.append(Scenario(name: "map → filter → map → sink", ops: N, x: { s in
    let subject = XPassthroughSubject<Int, Never>()
    let t = subject.map { $0 &+ 1 }.filter { $0 & 1 == 0 }.map { $0 &* 2 }.sink { s.n &+= $0 }
    for i in 0..<N { subject.send(i) }
    t.cancel()
}, c: combine { s in
    #if canImport(Combine)
    let subject = PassthroughSubject<Int, Never>()
    let t = subject.map { $0 &+ 1 }.filter { $0 & 1 == 0 }.map { $0 &* 2 }.sink { s.n &+= $0 }
    for i in 0..<N { subject.send(i) }
    t.cancel()
    #endif
}))

scenarios.append(Scenario(name: "removeDuplicates → sink", ops: N, x: { s in
    let subject = XPassthroughSubject<Int, Never>()
    let t = subject.removeDuplicates().sink { s.n &+= $0 }
    for i in 0..<N { subject.send(i / 3) }
    t.cancel()
}, c: combine { s in
    #if canImport(Combine)
    let subject = PassthroughSubject<Int, Never>()
    let t = subject.removeDuplicates().sink { s.n &+= $0 }
    for i in 0..<N { subject.send(i / 3) }
    t.cancel()
    #endif
}))

scenarios.append(Scenario(name: "currentValue.value = … → sink", ops: N, x: { s in
    let subject = XCurrentValueSubject<Int, Never>(0)
    let t = subject.sink { s.n &+= $0 }
    for i in 0..<N { subject.value = i }
    t.cancel()
}, c: combine { s in
    #if canImport(Combine)
    let subject = CurrentValueSubject<Int, Never>(0)
    let t = subject.sink { s.n &+= $0 }
    for i in 0..<N { subject.value = i }
    t.cancel()
    #endif
}))

scenarios.append(Scenario(name: "combineLatest(2) → sink", ops: N, x: { s in
    let a = XPassthroughSubject<Int, Never>(), b = XPassthroughSubject<Int, Never>()
    let t = a.combineLatest(b).sink { s.n &+= $0.0 &+ $0.1 }
    b.send(1)
    for i in 0..<N { a.send(i) }
    t.cancel()
}, c: combine { s in
    #if canImport(Combine)
    let a = PassthroughSubject<Int, Never>(), b = PassthroughSubject<Int, Never>()
    let t = a.combineLatest(b).sink { s.n &+= $0.0 &+ $0.1 }
    b.send(1)
    for i in 0..<N { a.send(i) }
    t.cancel()
    #endif
}))

scenarios.append(Scenario(name: "merge(2) → sink", ops: N, x: { s in
    let a = XPassthroughSubject<Int, Never>(), b = XPassthroughSubject<Int, Never>()
    let t = a.merge(with: b).sink { s.n &+= $0 }
    for i in 0..<N { if i & 1 == 0 { a.send(i) } else { b.send(i) } }
    t.cancel()
}, c: combine { s in
    #if canImport(Combine)
    let a = PassthroughSubject<Int, Never>(), b = PassthroughSubject<Int, Never>()
    let t = a.merge(with: b).sink { s.n &+= $0 }
    for i in 0..<N { if i & 1 == 0 { a.send(i) } else { b.send(i) } }
    t.cancel()
    #endif
}))

scenarios.append(Scenario(name: "switchToLatest (switch every 10 values)", ops: N, x: { s in
    let outer = XCurrentValueSubject<XCurrentValueSubject<Int, Never>, Never>(XCurrentValueSubject(0))
    let inners = [XCurrentValueSubject<Int, Never>(1), XCurrentValueSubject<Int, Never>(2)]
    let t = outer.switchToLatest().sink { s.n &+= $0 }
    for i in 0..<N {
        if i % 10 == 0 { outer.send(inners[(i / 10) & 1]) }
        inners[(i / 10) & 1].send(i)
    }
    t.cancel()
}, c: combine { s in
    #if canImport(Combine)
    let outer = CurrentValueSubject<CurrentValueSubject<Int, Never>, Never>(CurrentValueSubject(0))
    let inners = [CurrentValueSubject<Int, Never>(1), CurrentValueSubject<Int, Never>(2)]
    let t = outer.switchToLatest().sink { s.n &+= $0 }
    for i in 0..<N {
        if i % 10 == 0 { outer.send(inners[(i / 10) & 1]) }
        inners[(i / 10) & 1].send(i)
    }
    t.cancel()
    #endif
}))

scenarios.append(Scenario(name: "eraseToAnyPublisher chain (map ×2)", ops: N, x: { s in
    let subject = XPassthroughSubject<Int, Never>()
    let t = subject.map { $0 &+ 1 }.eraseToAnyPublisher().map { $0 &* 2 }.eraseToAnyPublisher().sink { s.n &+= $0 }
    for i in 0..<N { subject.send(i) }
    t.cancel()
}, c: combine { s in
    #if canImport(Combine)
    let subject = PassthroughSubject<Int, Never>()
    let t = subject.map { $0 &+ 1 }.eraseToAnyPublisher().map { $0 &* 2 }.eraseToAnyPublisher().sink { s.n &+= $0 }
    for i in 0..<N { subject.send(i) }
    t.cancel()
    #endif
}))

let churn = N / 5

scenarios.append(Scenario(name: "subscribe + send + cancel (shared subject)", ops: churn, x: { s in
    let subject = XPassthroughSubject<Int, Never>()
    for i in 0..<churn {
        let t = subject.sink { s.n &+= $0 }
        subject.send(i)
        t.cancel()
    }
}, c: combine { s in
    #if canImport(Combine)
    let subject = PassthroughSubject<Int, Never>()
    for i in 0..<churn {
        let t = subject.sink { s.n &+= $0 }
        subject.send(i)
        t.cancel()
    }
    #endif
}))

scenarios.append(Scenario(name: "build map→filter→sink graph + cancel", ops: churn, x: { s in
    let subject = XPassthroughSubject<Int, Never>()
    for i in 0..<churn {
        let t = subject.map { $0 &+ 1 }.filter { $0 & 1 == 0 }.sink { s.n &+= $0 }
        subject.send(i)
        t.cancel()
    }
}, c: combine { s in
    #if canImport(Combine)
    let subject = PassthroughSubject<Int, Never>()
    for i in 0..<churn {
        let t = subject.map { $0 &+ 1 }.filter { $0 & 1 == 0 }.sink { s.n &+= $0 }
        subject.send(i)
        t.cancel()
    }
    #endif
}))


// AsyncStream consumers run in nonisolated functions so the numbers are not inflated by
// hopping on and off the main actor at every `next()`.
nonisolated func streamSameThread(_ sum: Sum, _ bursts: Int) async {
    let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .unbounded)
    var iterator = stream.makeAsyncIterator()
    for burst in 0..<bursts {
        for i in 0..<64 { continuation.yield(burst &+ i) }
        for _ in 0..<64 { sum.n &+= await iterator.next() ?? 0 }
    }
    continuation.finish()
}

nonisolated func streamCrossThread(_ sum: Sum, _ count: Int) async {
    let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .unbounded)
    let producer = Thread { for i in 0..<count { continuation.yield(i) }; continuation.finish() }
    producer.start()
    for await value in stream { sum.n &+= value }
}

let filter = CommandLine.arguments.dropFirst().first
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func num(_ v: Double) -> String { String(format: "%8.1f", v) }

print(pad("scenario", 46), "   XCombine   Combine    Combine/X")
print(String(repeating: "-", count: 46 + 36))
let checksum = Sum()
for scenario in scenarios where filter == nil || scenario.name.contains(filter!) {
    let x = median({ scenario.x(checksum) }) / Double(scenario.ops)
    var line = pad(scenario.name, 46) + " " + num(x) + " ns"
    if let c = scenario.c {
        let cm = median({ c(checksum) }) / Double(scenario.ops)
        line += " " + num(cm) + " ns  " + String(format: "%6.2fx", cm / x)
    }
    print(line)
}

// MARK: - Crossing threads: XInbox vs AsyncStream (the path MIDI input used before XInbox)

if filter == nil || "inbox".contains(filter!) || filter!.contains("inbox") || filter!.contains("thread") {
    func medianAsync(_ body: () async -> Void, runs: Int = 5) async -> Double {
        await body()
        var samples: [Double] = []
        for _ in 0..<runs {
            let t0 = now()
            await body()
            samples.append(now() - t0)
        }
        samples.sort()
        return samples[samples.count / 2]
    }
    func row(_ name: String, _ x: Double, _ a: Double, ops: Int) {
        let xs = x / Double(ops), asy = a / Double(ops)
        print(pad(name, 46) + " " + num(xs) + " ns " + num(asy) + " ns  " + String(format: "%6.2fx", asy / xs))
    }
    print()
    print(pad("thread crossing (per value)", 46), "   XInbox  AsyncStream  Stream/X")
    print(String(repeating: "-", count: 46 + 36))
    let M = N

    // Same thread: a burst of 64, then the owner takes it — the per-frame shape.
    let sameX = median({
        let inbox = XInbox<Int>()
        let t = inbox.sink { checksum.n &+= $0 }
        for burst in 0..<(M / 64) {
            for i in 0..<64 { inbox.send(burst &+ i) }
            inbox.drain()
        }
        t.cancel()
    })
    let sameA = await medianAsync({ await streamSameThread(checksum, M / 64) })
    row("same thread, bursts of 64", sameX, sameA, ops: M / 64 * 64)

    // Another thread produces while this one consumes: end to end, all values delivered.
    let crossX = median({
        let inbox = XInbox<Int>()
        let t = inbox.sink { checksum.n &+= $0 }
        let producer = Thread { for i in 0..<M { inbox.send(i) } }
        producer.start()
        var got = 0
        while got < M { got += inbox.drain() }
        t.cancel()
    })
    let crossA = await medianAsync({ await streamCrossThread(checksum, M) })
    row("producer thread → consumer thread", crossX, crossA, ops: M)
}
print("(checksum \(checksum.n))")
