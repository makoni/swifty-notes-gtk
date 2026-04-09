import Foundation
import GObjectSupport

@MainActor
public final class AutosaveCoordinator {
    private var cancelCurrentTask: (() -> Void)?
    private let taskScheduler: (Duration, @escaping @MainActor () -> Void) -> (() -> Void)

    public init(
        taskScheduler: @escaping (Duration, @escaping @MainActor () -> Void) -> (() -> Void) = { delay, operation in
            let task = MainContext.task(after: delay) {
                operation()
            }
            return { task.cancel() }
        }
    ) {
        self.taskScheduler = taskScheduler
    }

    public func scheduleSave(
        after delay: Duration = .milliseconds(400),
        operation: @escaping @MainActor () -> Void
    ) {
        cancel()
        cancelCurrentTask = taskScheduler(delay) { [weak self] in
            self?.cancelCurrentTask = nil
            operation()
        }
    }

    public func cancel() {
        cancelCurrentTask?()
        cancelCurrentTask = nil
    }
}
