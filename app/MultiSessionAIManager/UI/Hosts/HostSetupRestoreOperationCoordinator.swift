import Foundation

/// Owns the one host-mutating or host-probing restore operation started by the
/// Host Setup sheet.
///
/// Keeping the task here gives sheet teardown something concrete to cancel and
/// drain before its shared SSH connection is closed. New taps are ignored while
/// work is active, so probe and install commands never overlap.
@MainActor
final class HostSetupRestoreOperationCoordinator {
    private struct ActiveOperation {
        let id: UInt64
        let task: Task<Void, Never>
    }

    private var nextID: UInt64 = 0
    private var activeOperation: ActiveOperation?
    private var isCancelling = false

    var hasActiveOperation: Bool { activeOperation != nil }

    @discardableResult
    func start(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Bool {
        guard !Task.isCancelled, activeOperation == nil, !isCancelling else { return false }

        nextID &+= 1
        let id = nextID
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.finish(id: id)
        }
        activeOperation = ActiveOperation(id: id, task: task)
        return true
    }

    /// Prevent new work, cancel the active operation, and wait for its
    /// cancellation path to finish before allowing a caller to close SSH.
    func cancelAndWait() async {
        isCancelling = true
        defer { isCancelling = false }
        guard let operation = activeOperation else { return }

        operation.task.cancel()
        await operation.task.value
        if activeOperation?.id == operation.id {
            activeOperation = nil
        }
    }

    private func finish(id: UInt64) {
        guard activeOperation?.id == id else { return }
        activeOperation = nil
    }
}
