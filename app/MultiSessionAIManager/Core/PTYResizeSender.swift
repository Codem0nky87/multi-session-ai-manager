import Foundation

/// A terminal grid, in character cells.
struct TerminalGridSize: Equatable, Sendable {
    let cols: Int
    let rows: Int
}

/// Delivers a PTY's size to the remote one request at a time, in the order asked
/// for, and always ends on the newest size.
///
/// Each resize used to be sent from its own unstructured task, so two sizes
/// computed a few milliseconds apart (a terminal opening, a text-size change, a
/// rotation, a pinch) could reach the host in either order. When the older one
/// landed last the host kept a stale grid while the app, which only resends a
/// size that differs from its own, believed the right one was in force: the text
/// size shown in Settings was not the one the remote was laid out for until it
/// was changed again.
///
/// A burst also collapses here: while one size is in flight, later requests only
/// replace the size waiting to go next.
final class PTYResizeSender: @unchecked Sendable {
    private let lock = NSLock()
    private var wanted: TerminalGridSize?
    private var delivered: TerminalGridSize?
    private var isSending = false
    private let deliver: @Sendable (TerminalGridSize) async throws -> Void

    /// - Parameter opened: the size the PTY was opened with, which the remote
    ///   already has.
    init(opened: TerminalGridSize? = nil,
         deliver: @escaping @Sendable (TerminalGridSize) async throws -> Void) {
        self.delivered = opened
        self.deliver = deliver
    }

    func request(cols: Int, rows: Int) {
        let startsSending = lock.withLock { () -> Bool in
            wanted = TerminalGridSize(cols: cols, rows: rows)
            guard !isSending else { return false }
            isSending = true
            return true
        }
        guard startsSending else { return }
        Task { await self.sendUntilCurrent() }
    }

    /// True once nothing is in flight or waiting. For tests.
    var isIdle: Bool { lock.withLock { !isSending } }

    private func sendUntilCurrent() async {
        while true {
            let next = lock.withLock { () -> TerminalGridSize? in
                guard let wanted, wanted != delivered else {
                    isSending = false
                    return nil
                }
                return wanted
            }
            guard let next else { return }
            do {
                try await deliver(next)
                lock.withLock { delivered = next }
            } catch {
                // The channel is gone. Stop; whatever opens next starts from its own size.
                lock.withLock { isSending = false }
                return
            }
        }
    }
}
