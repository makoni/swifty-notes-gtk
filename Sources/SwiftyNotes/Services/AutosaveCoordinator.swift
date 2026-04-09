import Foundation
import GObjectSupport

@MainActor
public final class AutosaveCoordinator {
    private var currentTask: MainContext.Task?

    public init() {}

    public func scheduleSave(
        after delay: Duration = .milliseconds(400),
        operation: @escaping @MainActor () -> Void
    ) {
        cancel()
        currentTask = MainContext.task(after: delay) { [weak self] in
            self?.currentTask = nil
            operation()
        }
    }

    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }
}
