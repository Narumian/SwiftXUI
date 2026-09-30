import Foundation

/// The visible state of an asynchronous view's operation.
public enum AsyncViewPhase<Value: Sendable>: Sendable {
    case loading
    case success(Value)
    case failure(String)
}

private enum _AsyncViewUpdate<Value: Sendable>: Sendable {
    case success(Value)
    case failure(String)
}

private final class _AsyncViewState<Value: Sendable> {
    var phase: AsyncViewPhase<Value> = .loading
    let updates = BufferedSignal<_AsyncViewUpdate<Value>>()
    var task: Task<Void, Never>?
}

/// Runs one asynchronous operation for the lifetime of this view identity.
///
/// The operation is started when the node first appears. Its `Sendable`
/// result is buffered until the next XUI walk, so state changes never happen
/// in the middle of layout or painting. When the node disappears,
/// `StateStore` cancels the task through its removal hook.
public struct AsyncView<
    Value: Sendable,
    Content: XView,
    Placeholder: XView,
    Failure: XView
>: XView, _PrimitiveXView {
    public typealias Body = Never

    private let operation: @Sendable () async throws -> Value
    private let content: (Value) -> Content
    private let placeholder: () -> Placeholder
    private let failure: (String) -> Failure

    public init(
        operation: @escaping @Sendable () async throws -> Value,
        @XViewBuilder content: @escaping (Value) -> Content,
        @XViewBuilder placeholder: @escaping () -> Placeholder,
        @XViewBuilder failure: @escaping (String) -> Failure
    ) {
        self.operation = operation
        self.content = content
        self.placeholder = placeholder
        self.failure = failure
    }

    func _lower(id: StateIdentity, store: StateStore) -> [LayoutNode] {
        let box: StateStore.Box<_AsyncViewState<Value>> = store.box(for: id.child(type: Self.self)) {
            _AsyncViewState()
        }

        box.value.updates.drain { update in
            switch update {
            case .success(let value): box.value.phase = .success(value)
            case .failure(let message): box.value.phase = .failure(message)
            }
        }

        if box.value.task == nil {
            let operation = operation
            let updates = box.value.updates
            box.value.task = Task {
                do {
                    updates.send(.success(try await operation()))
                } catch is CancellationError {
                    // Disappearing from the tree is a normal cancellation.
                } catch {
                    updates.send(.failure(String(describing: error)))
                }
            }
        }

        box.onRemove = { state in
            state.task?.cancel()
        }

        switch box.value.phase {
        case .loading:
            return lower(placeholder(), id: id.child(name: "loading"), store: store)
        case .success(let value):
            return lower(content(value), id: id.child(name: "success"), store: store)
        case .failure(let message):
            return lower(failure(message), id: id.child(name: "failure"), store: store)
        }
    }
}
