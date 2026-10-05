import Foundation

/// Timing and outcome for one resource preparation job.
public struct ResourceLoadSample<ID: Hashable & Sendable>: Sendable {
    public let id: ID
    public let durationMilliseconds: Double
    public let succeeded: Bool

    public init(id: ID, durationMilliseconds: Double, succeeded: Bool) {
        self.id = id
        self.durationMilliseconds = durationMilliseconds
        self.succeeded = succeeded
    }
}

/// Results and per-job measurements from one bounded loading pass.
public struct ResourceLoadReport<ID: Hashable & Sendable, Value: Sendable>: Sendable {
    public let values: [Value?]
    public let samples: [ResourceLoadSample<ID>]

    public init(values: [Value?], samples: [ResourceLoadSample<ID>]) {
        self.values = values
        self.samples = samples
    }

    public var failedCount: Int {
        samples.count(where: { !$0.succeeded })
    }

    public var totalDurationMilliseconds: Double {
        samples.reduce(0) { $0 + $1.durationMilliseconds }
    }
}

/// Runs independent resource preparation jobs in bounded parallel batches.
///
/// XRender does not know whether a job is PNG, JSON, audio, or something else;
/// the caller supplies the decoder. Keeping the batch boundary here avoids
/// loading an entire art catalog into memory while still using the available
/// CPU cores. Results retain the input order and failed jobs remain `nil`.
public enum ParallelResourceLoader {
    public static func load<Job: Sendable, Value: Sendable>(
        _ jobs: [Job],
        maxConcurrent: Int? = nil,
        operation: @escaping @Sendable (Job) -> Value?
    ) async -> [Value?] {
        await loadWithReport(
            jobs,
            maxConcurrent: maxConcurrent,
            identifier: { _ in 0 },
            operation: operation
        ).values
    }

    /// Loads jobs while recording one timing sample per input item.
    ///
    /// `samples` and `values` preserve the input order. `maxConcurrent` is a
    /// bounded batch size, not an unbounded task fan-out, so callers can tune
    /// CPU and memory pressure independently for each resource group.
    public static func loadWithReport<Job: Sendable, ID: Hashable & Sendable, Value: Sendable>(
        _ jobs: [Job],
        maxConcurrent: Int? = nil,
        identifier: @escaping @Sendable (Job) -> ID,
        operation: @escaping @Sendable (Job) -> Value?
    ) async -> ResourceLoadReport<ID, Value> {
        guard !jobs.isEmpty else {
            return ResourceLoadReport(values: [], samples: [])
        }

        let batchSize = max(
            1,
            maxConcurrent ?? ProcessInfo.processInfo.activeProcessorCount * 2
        )
        var results = [Value?](repeating: nil, count: jobs.count)
        var samples = [ResourceLoadSample<ID>?](repeating: nil, count: jobs.count)
        var start = 0

        while start < jobs.count {
            let end = min(start + batchSize, jobs.count)
            let batch = Array(jobs[start..<end])
            let loaded: [(
                offset: Int,
                value: Value?,
                sample: ResourceLoadSample<ID>
            )] = await withTaskGroup(
                of: (offset: Int, value: Value?, sample: ResourceLoadSample<ID>).self
            ) { group in
                for (offset, job) in batch.enumerated() {
                    group.addTask {
                        let startedAt = DispatchTime.now().uptimeNanoseconds
                        let value = operation(job)
                        let elapsed = Double(
                            DispatchTime.now().uptimeNanoseconds - startedAt
                        ) / 1_000_000
                        return (
                            offset: offset,
                            value: value,
                            sample: ResourceLoadSample(
                                id: identifier(job),
                                durationMilliseconds: elapsed,
                                succeeded: value != nil
                            )
                        )
                    }
                }

                var values: [(
                    offset: Int,
                    value: Value?,
                    sample: ResourceLoadSample<ID>
                )] = []
                values.reserveCapacity(batch.count)
                for await value in group {
                    values.append(value)
                }
                return values
            }

            for item in loaded {
                results[start + item.offset] = item.value
                samples[start + item.offset] = item.sample
            }
            start = end
        }

        return ResourceLoadReport(
            values: results,
            samples: samples.compactMap { $0 }
        )
    }
}
