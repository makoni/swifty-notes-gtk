import Foundation

@MainActor
public final class AutosaveCoordinator {
    private var currentTask: Task<Void, Never>?

    public init() {}

    public func scheduleSave(
        after delay: Duration = .milliseconds(400),
        operation: @escaping @Sendable () async -> Void
    ) {
        currentTask?.cancel()
        currentTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }
}
