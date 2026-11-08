// MARK: - Single-input operators

/// Shared plumbing for operators that sit between one upstream and one downstream: they
/// forward the subscription, completion and cancellation, and subclasses only decide what to
/// do with each value. The subclass is `final`, so the per-value call stays statically
/// dispatched once the pipeline is specialized.
@usableFromInline class _Relay<Input, S: XSubscriber>: XSubscription {
    @usableFromInline @exclusivity(unchecked) var downstream: S?
    @usableFromInline @exclusivity(unchecked) var upstream: (any XSubscription)?

    @inlinable init(_ downstream: S) { self.downstream = downstream }

    @inlinable final func receive(subscription: any XSubscription) {
        guard downstream != nil else { subscription.cancel(); return }
        upstream = subscription
        downstream?.receive(subscription: self)
    }

    @inlinable final func receive(completion: XSubscribers.Completion<S.Failure>) {
        guard let d = downstream else { return }
        downstream = nil
        upstream = nil
        d.receive(completion: completion)
    }

    @inlinable final func cancel() {
        downstream = nil
        let u = upstream
        upstream = nil
        u?.cancel()
    }
}

public extension XPublishers {
    struct Map<Upstream: XPublisher, Output>: XPublisher {
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let transform: (Upstream.Output) -> Output

        @inlinable public init(upstream: Upstream, transform: @escaping (Upstream.Output) -> Output) {
            self.upstream = upstream
            self.transform = transform
        }

        @inlinable public func receive<S: XSubscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            upstream.receive(subscriber: _MapInner<Upstream.Output, S>(subscriber, transform))
        }
    }

    struct CompactMap<Upstream: XPublisher, Output>: XPublisher {
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let transform: (Upstream.Output) -> Output?

        @inlinable public init(upstream: Upstream, transform: @escaping (Upstream.Output) -> Output?) {
            self.upstream = upstream
            self.transform = transform
        }

        @inlinable public func receive<S: XSubscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            upstream.receive(subscriber: _CompactMapInner<Upstream.Output, S>(subscriber, transform))
        }
    }

    struct Filter<Upstream: XPublisher>: XPublisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let isIncluded: (Output) -> Bool

        @inlinable public init(upstream: Upstream, isIncluded: @escaping (Output) -> Bool) {
            self.upstream = upstream
            self.isIncluded = isIncluded
        }

        @inlinable public func receive<S: XSubscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            upstream.receive(subscriber: _FilterInner<S>(subscriber, isIncluded))
        }
    }

    struct RemoveDuplicates<Upstream: XPublisher>: XPublisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let predicate: (Output, Output) -> Bool

        @inlinable public init(upstream: Upstream, predicate: @escaping (Output, Output) -> Bool) {
            self.upstream = upstream
            self.predicate = predicate
        }

        @inlinable public func receive<S: XSubscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            upstream.receive(subscriber: _RemoveDuplicatesInner<S>(subscriber, predicate))
        }
    }

    struct DropFirst<Upstream: XPublisher>: XPublisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let count: Int

        @inlinable public init(upstream: Upstream, count: Int) {
            self.upstream = upstream
            self.count = count
        }

        @inlinable public func receive<S: XSubscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            upstream.receive(subscriber: _DropFirstInner<S>(subscriber, count))
        }
    }
}

@usableFromInline final class _MapInner<Input, S: XSubscriber>: _Relay<Input, S>, XSubscriber {
    @usableFromInline typealias Failure = S.Failure
    @usableFromInline let transform: (Input) -> S.Input
    @inlinable init(_ downstream: S, _ transform: @escaping (Input) -> S.Input) {
        self.transform = transform
        super.init(downstream)
    }
    @inlinable func receive(_ input: Input) { downstream?.receive(transform(input)) }
}

@usableFromInline final class _CompactMapInner<Input, S: XSubscriber>: _Relay<Input, S>, XSubscriber {
    @usableFromInline typealias Failure = S.Failure
    @usableFromInline let transform: (Input) -> S.Input?
    @inlinable init(_ downstream: S, _ transform: @escaping (Input) -> S.Input?) {
        self.transform = transform
        super.init(downstream)
    }
    @inlinable func receive(_ input: Input) {
        if let output = transform(input) { downstream?.receive(output) }
    }
}

@usableFromInline final class _FilterInner<S: XSubscriber>: _Relay<S.Input, S>, XSubscriber {
    @usableFromInline typealias Input = S.Input
    @usableFromInline typealias Failure = S.Failure
    @usableFromInline let isIncluded: (S.Input) -> Bool
    @inlinable init(_ downstream: S, _ isIncluded: @escaping (S.Input) -> Bool) {
        self.isIncluded = isIncluded
        super.init(downstream)
    }
    @inlinable func receive(_ input: S.Input) {
        if isIncluded(input) { downstream?.receive(input) }
    }
}

@usableFromInline final class _RemoveDuplicatesInner<S: XSubscriber>: _Relay<S.Input, S>, XSubscriber {
    @usableFromInline typealias Input = S.Input
    @usableFromInline typealias Failure = S.Failure
    @usableFromInline let predicate: (S.Input, S.Input) -> Bool
    @usableFromInline @exclusivity(unchecked) var last: S.Input?
    @inlinable init(_ downstream: S, _ predicate: @escaping (S.Input, S.Input) -> Bool) {
        self.predicate = predicate
        super.init(downstream)
    }
    @inlinable func receive(_ input: S.Input) {
        if let last, predicate(last, input) { return }
        last = input
        downstream?.receive(input)
    }
}

@usableFromInline final class _DropFirstInner<S: XSubscriber>: _Relay<S.Input, S>, XSubscriber {
    @usableFromInline typealias Input = S.Input
    @usableFromInline typealias Failure = S.Failure
    @usableFromInline @exclusivity(unchecked) var remaining: Int
    @inlinable init(_ downstream: S, _ count: Int) {
        remaining = count
        super.init(downstream)
    }
    @inlinable func receive(_ input: S.Input) {
        if remaining > 0 { remaining -= 1; return }
        downstream?.receive(input)
    }
}

public extension XPublisher {
    @inlinable func map<T>(_ transform: @escaping (Output) -> T) -> XPublishers.Map<Self, T> {
        .init(upstream: self, transform: transform)
    }
    @inlinable func compactMap<T>(_ transform: @escaping (Output) -> T?) -> XPublishers.CompactMap<Self, T> {
        .init(upstream: self, transform: transform)
    }
    @inlinable func filter(_ isIncluded: @escaping (Output) -> Bool) -> XPublishers.Filter<Self> {
        .init(upstream: self, isIncluded: isIncluded)
    }
    @inlinable func removeDuplicates(by predicate: @escaping (Output, Output) -> Bool) -> XPublishers.RemoveDuplicates<Self> {
        .init(upstream: self, predicate: predicate)
    }
    @inlinable func dropFirst(_ count: Int = 1) -> XPublishers.DropFirst<Self> {
        .init(upstream: self, count: count)
    }
}

public extension XPublisher where Output: Equatable {
    @inlinable func removeDuplicates() -> XPublishers.RemoveDuplicates<Self> {
        .init(upstream: self, predicate: { $0 == $1 })
    }
}

// MARK: - Merge

/// Fan-in for `merge`: every child forwards values straight through; the stream finishes when
/// all children have, and fails (cancelling the rest) as soon as one does.
@usableFromInline final class _MergeInner<S: XSubscriber>: XSubscription {
    @usableFromInline @exclusivity(unchecked) var downstream: S?
    @usableFromInline @exclusivity(unchecked) var subscriptions: [(any XSubscription)?]
    @usableFromInline @exclusivity(unchecked) var remaining: Int

    @inlinable init(_ downstream: S, count: Int) {
        self.downstream = downstream
        subscriptions = Array(repeating: nil, count: count)
        remaining = count
    }

    @inlinable func cancel() {
        downstream = nil
        let all = subscriptions
        for index in subscriptions.indices { subscriptions[index] = nil }
        for subscription in all { subscription?.cancel() }
    }

    @usableFromInline struct Child: XSubscriber {
        @usableFromInline typealias Input = S.Input
        @usableFromInline typealias Failure = S.Failure
        @usableFromInline let parent: _MergeInner<S>
        @usableFromInline let index: Int

        @inlinable init(parent: _MergeInner<S>, index: Int) { self.parent = parent; self.index = index }

        @inlinable func receive(subscription: any XSubscription) {
            guard parent.downstream != nil else { subscription.cancel(); return }
            parent.subscriptions[index] = subscription
        }
        @inlinable func receive(_ input: S.Input) { parent.downstream?.receive(input) }
        @inlinable func receive(completion: XSubscribers.Completion<S.Failure>) {
            parent.subscriptions[index] = nil
            switch completion {
            case .finished:
                parent.remaining -= 1
                guard parent.remaining == 0, let d = parent.downstream else { return }
                parent.downstream = nil
                d.receive(completion: .finished)
            case .failure:
                guard let d = parent.downstream else { return }
                parent.cancel()
                d.receive(completion: completion)
            }
        }
    }
}

public extension XPublishers {
    struct Merge<A: XPublisher, B: XPublisher>: XPublisher where A.Output == B.Output, A.Failure == B.Failure {
        public typealias Output = A.Output
        public typealias Failure = A.Failure
        public let a: A
        public let b: B

        @inlinable public init(_ a: A, _ b: B) { self.a = a; self.b = b }

        @inlinable public func receive<S: XSubscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let inner = _MergeInner(subscriber, count: 2)
            subscriber.receive(subscription: inner)
            a.receive(subscriber: _MergeInner<S>.Child(parent: inner, index: 0))
            b.receive(subscriber: _MergeInner<S>.Child(parent: inner, index: 1))
        }
    }

    struct MergeMany<P: XPublisher>: XPublisher {
        public typealias Output = P.Output
        public typealias Failure = P.Failure
        public let publishers: [P]

        @inlinable public init(_ publishers: [P]) { self.publishers = publishers }
        @inlinable public init(_ publishers: P...) { self.publishers = publishers }

        @inlinable public func receive<S: XSubscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            guard !publishers.isEmpty else {
                subscriber.receive(subscription: _InertSubscription.shared)
                subscriber.receive(completion: .finished)
                return
            }
            let inner = _MergeInner(subscriber, count: publishers.count)
            subscriber.receive(subscription: inner)
            for (index, publisher) in publishers.enumerated() {
                publisher.receive(subscriber: _MergeInner<S>.Child(parent: inner, index: index))
            }
        }
    }
}

public extension XPublisher {
    @inlinable func merge<P: XPublisher>(with other: P) -> XPublishers.Merge<Self, P>
    where P.Output == Output, P.Failure == Failure {
        .init(self, other)
    }
}

// MARK: - CombineLatest

@usableFromInline final class _CombineLatestInner<A, B, S: XSubscriber>: XSubscription where S.Input == (A, B) {
    @usableFromInline @exclusivity(unchecked) var downstream: S?
    @usableFromInline @exclusivity(unchecked) var latestA: A?
    @usableFromInline @exclusivity(unchecked) var latestB: B?
    @usableFromInline @exclusivity(unchecked) var subscriptionA: (any XSubscription)?
    @usableFromInline @exclusivity(unchecked) var subscriptionB: (any XSubscription)?
    @usableFromInline @exclusivity(unchecked) var doneA = false
    @usableFromInline @exclusivity(unchecked) var doneB = false

    @inlinable init(_ downstream: S) { self.downstream = downstream }

    @inlinable func cancel() {
        downstream = nil
        let sa = subscriptionA, sb = subscriptionB
        subscriptionA = nil
        subscriptionB = nil
        sa?.cancel()
        sb?.cancel()
    }

    @inlinable func emit() {
        if let a = latestA, let b = latestB { downstream?.receive((a, b)) }
    }

    @inlinable func fail(_ completion: XSubscribers.Completion<S.Failure>) {
        guard let d = downstream else { return }
        cancel()
        d.receive(completion: completion)
    }

    @inlinable func finishIfDone() {
        guard doneA, doneB, let d = downstream else { return }
        downstream = nil
        d.receive(completion: .finished)
    }

    @usableFromInline struct SideA: XSubscriber {
        @usableFromInline typealias Input = A
        @usableFromInline typealias Failure = S.Failure
        @usableFromInline let parent: _CombineLatestInner
        @inlinable init(_ parent: _CombineLatestInner) { self.parent = parent }
        @inlinable func receive(subscription: any XSubscription) {
            guard parent.downstream != nil else { subscription.cancel(); return }
            parent.subscriptionA = subscription
        }
        @inlinable func receive(_ input: A) {
            guard parent.downstream != nil else { return }
            parent.latestA = input
            parent.emit()
        }
        @inlinable func receive(completion: XSubscribers.Completion<S.Failure>) {
            parent.subscriptionA = nil
            switch completion {
            case .finished: parent.doneA = true; parent.finishIfDone()
            case .failure: parent.fail(completion)
            }
        }
    }

    @usableFromInline struct SideB: XSubscriber {
        @usableFromInline typealias Input = B
        @usableFromInline typealias Failure = S.Failure
        @usableFromInline let parent: _CombineLatestInner
        @inlinable init(_ parent: _CombineLatestInner) { self.parent = parent }
        @inlinable func receive(subscription: any XSubscription) {
            guard parent.downstream != nil else { subscription.cancel(); return }
            parent.subscriptionB = subscription
        }
        @inlinable func receive(_ input: B) {
            guard parent.downstream != nil else { return }
            parent.latestB = input
            parent.emit()
        }
        @inlinable func receive(completion: XSubscribers.Completion<S.Failure>) {
            parent.subscriptionB = nil
            switch completion {
            case .finished: parent.doneB = true; parent.finishIfDone()
            case .failure: parent.fail(completion)
            }
        }
    }
}

public extension XPublishers {
    struct CombineLatest<A: XPublisher, B: XPublisher>: XPublisher where A.Failure == B.Failure {
        public typealias Output = (A.Output, B.Output)
        public typealias Failure = A.Failure
        public let a: A
        public let b: B

        @inlinable public init(_ a: A, _ b: B) { self.a = a; self.b = b }

        @inlinable public func receive<S: XSubscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let inner = _CombineLatestInner<A.Output, B.Output, S>(subscriber)
            subscriber.receive(subscription: inner)
            a.receive(subscriber: _CombineLatestInner<A.Output, B.Output, S>.SideA(inner))
            b.receive(subscriber: _CombineLatestInner<A.Output, B.Output, S>.SideB(inner))
        }
    }
}

public extension XPublisher {
    @inlinable func combineLatest<P: XPublisher>(_ other: P) -> XPublishers.CombineLatest<Self, P>
    where P.Failure == Failure {
        .init(self, other)
    }

    @inlinable func combineLatest<P: XPublisher, T>(_ other: P, _ transform: @escaping (Output, P.Output) -> T)
    -> XPublishers.Map<XPublishers.CombineLatest<Self, P>, T> where P.Failure == Failure {
        XPublishers.CombineLatest(self, other).map { transform($0.0, $0.1) }
    }
}

// MARK: - SwitchToLatest

@usableFromInline final class _SwitchInner<Inner: XPublisher, S: XSubscriber>: XSubscription
where S.Input == Inner.Output, S.Failure == Inner.Failure {
    @usableFromInline @exclusivity(unchecked) var downstream: S?
    @usableFromInline @exclusivity(unchecked) var outerSubscription: (any XSubscription)?
    @usableFromInline @exclusivity(unchecked) var innerSubscription: (any XSubscription)?
    @usableFromInline @exclusivity(unchecked) var generation = 0
    @usableFromInline @exclusivity(unchecked) var innerActive = false
    @usableFromInline @exclusivity(unchecked) var outerDone = false

    @inlinable init(_ downstream: S) { self.downstream = downstream }

    @inlinable func cancel() {
        downstream = nil
        generation &+= 1
        let outer = outerSubscription, inner = innerSubscription
        outerSubscription = nil
        innerSubscription = nil
        outer?.cancel()
        inner?.cancel()
    }

    @inlinable func fail(_ completion: XSubscribers.Completion<S.Failure>) {
        guard let d = downstream else { return }
        cancel()
        d.receive(completion: completion)
    }

    @inlinable func finishIfDone() {
        guard outerDone, !innerActive, let d = downstream else { return }
        downstream = nil
        d.receive(completion: .finished)
    }

    @inlinable func switchTo(_ publisher: Inner) {
        guard downstream != nil else { return }
        generation &+= 1
        let old = innerSubscription
        innerSubscription = nil
        old?.cancel()
        innerActive = true
        publisher.receive(subscriber: InnerSide(parent: self, generation: generation))
    }

    @usableFromInline struct InnerSide: XSubscriber {
        @usableFromInline typealias Input = Inner.Output
        @usableFromInline typealias Failure = S.Failure
        @usableFromInline let parent: _SwitchInner
        @usableFromInline let generation: Int
        @inlinable init(parent: _SwitchInner, generation: Int) { self.parent = parent; self.generation = generation }

        @inlinable func receive(subscription: any XSubscription) {
            guard parent.generation == generation, parent.downstream != nil else { subscription.cancel(); return }
            parent.innerSubscription = subscription
        }
        @inlinable func receive(_ input: Inner.Output) {
            guard parent.generation == generation else { return }
            parent.downstream?.receive(input)
        }
        @inlinable func receive(completion: XSubscribers.Completion<S.Failure>) {
            guard parent.generation == generation else { return }
            parent.innerSubscription = nil
            switch completion {
            case .finished: parent.innerActive = false; parent.finishIfDone()
            case .failure: parent.fail(completion)
            }
        }
    }

    @usableFromInline struct OuterSide: XSubscriber {
        @usableFromInline typealias Input = Inner
        @usableFromInline typealias Failure = S.Failure
        @usableFromInline let parent: _SwitchInner
        @inlinable init(_ parent: _SwitchInner) { self.parent = parent }

        @inlinable func receive(subscription: any XSubscription) {
            guard parent.downstream != nil else { subscription.cancel(); return }
            parent.outerSubscription = subscription
        }
        @inlinable func receive(_ input: Inner) { parent.switchTo(input) }
        @inlinable func receive(completion: XSubscribers.Completion<S.Failure>) {
            parent.outerSubscription = nil
            switch completion {
            case .finished: parent.outerDone = true; parent.finishIfDone()
            case .failure: parent.fail(completion)
            }
        }
    }
}

public extension XPublishers {
    /// Follows the most recent inner publisher, cancelling the previous one on each switch.
    struct SwitchToLatest<Inner: XPublisher, Upstream: XPublisher>: XPublisher
    where Upstream.Output == Inner, Upstream.Failure == Inner.Failure {
        public typealias Output = Inner.Output
        public typealias Failure = Inner.Failure
        public let upstream: Upstream

        @inlinable public init(upstream: Upstream) { self.upstream = upstream }

        @inlinable public func receive<S: XSubscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let inner = _SwitchInner<Inner, S>(subscriber)
            subscriber.receive(subscription: inner)
            upstream.receive(subscriber: _SwitchInner<Inner, S>.OuterSide(inner))
        }
    }
}

public extension XPublisher where Output: XPublisher, Output.Failure == Failure {
    @inlinable func switchToLatest() -> XPublishers.SwitchToLatest<Output, Self> {
        .init(upstream: self)
    }
}
