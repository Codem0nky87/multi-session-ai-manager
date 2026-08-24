import Foundation

/// Repeats a hardware key while it remains pressed. The first send is immediate,
/// then repeats at a keyboard-like cadence until `stop()`.
@MainActor
final class RepeatKeyPressController {
    private let initialDelayNanoseconds: UInt64
    private let repeatIntervalNanoseconds: UInt64
    private var task: Task<Void, Never>?
    private var action: (() -> Void)?

    init(
        initialDelayNanoseconds: UInt64 = 350_000_000,
        repeatIntervalNanoseconds: UInt64 = 55_000_000
    ) {
        self.initialDelayNanoseconds = initialDelayNanoseconds
        self.repeatIntervalNanoseconds = repeatIntervalNanoseconds
    }

    func start(action: @escaping () -> Void) {
        guard task == nil else { return }
        self.action = action
        action()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: initialDelayNanoseconds)
                while !Task.isCancelled {
                    action()
                    try await Task.sleep(nanoseconds: repeatIntervalNanoseconds)
                }
            } catch {
                // Cancellation is the normal key-release path.
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        action = nil
    }

    deinit {
        task?.cancel()
    }
}
