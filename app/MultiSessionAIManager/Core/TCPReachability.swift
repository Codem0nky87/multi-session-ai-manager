import Foundation
import Network

/// A transport-only reachability check. It opens exactly one TCP connection and
/// sends no application, HTTP, TLS, or SSH data.
final class TCPReachability: TCPReachabilityChecking, @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.codem0nky87.MultiSessionAIManager.tcp-reachability"
    )

    func check(host: String, port: Int, timeout: Duration) async -> TCPReachabilityResult {
        guard !host.isEmpty,
              !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (1...65_535).contains(port),
              timeout > .zero,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return .failed
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: .tcp
        )
        let attempt = TCPReachabilityAttempt(queue: queue)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                attempt.begin(
                    connection: connection,
                    timeout: timeout,
                    continuation: continuation
                )
            }
        } onCancel: {
            attempt.finish(.cancelled)
        }
    }

    static func classify(error: NWError) -> TCPReachabilityResult {
        switch error {
        case .dns:
            .dnsFailure
        case .posix(let code):
            switch code {
            case .ECONNREFUSED:
                .refused
            case .ETIMEDOUT:
                .timedOut
            case .ENETDOWN, .ENETUNREACH, .ENETRESET, .EHOSTDOWN, .EHOSTUNREACH:
                .networkUnavailable
            default:
                .failed
            }
        case .tls:
            .failed
        case .wifiAware:
            .failed
        @unknown default:
            .failed
        }
    }
}

private final class TCPReachabilityAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var continuation: CheckedContinuation<TCPReachabilityResult, Never>?
    private var connection: NWConnection?
    private var timeoutTask: Task<Void, Never>?
    private var lastWaitingError: NWError?
    private var completedResult: TCPReachabilityResult?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func begin(
        connection: NWConnection,
        timeout: Duration,
        continuation: CheckedContinuation<TCPReachabilityResult, Never>
    ) {
        lock.lock()
        if let completedResult {
            lock.unlock()
            connection.cancel()
            continuation.resume(returning: completedResult)
            return
        }

        self.connection = connection
        self.continuation = continuation
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state)
        }
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.timeoutReached()
        }

        // Start while the attempt lock still owns the lifecycle transition, so
        // cancellation can only observe start-then-cancel—not cancel-then-start.
        connection.start(queue: queue)
        lock.unlock()
    }

    func finish(_ result: TCPReachabilityResult) {
        let resources: (
            CheckedContinuation<TCPReachabilityResult, Never>?,
            NWConnection?,
            Task<Void, Never>?
        )

        lock.lock()
        guard completedResult == nil else {
            lock.unlock()
            return
        }
        completedResult = result
        resources = (continuation, connection, timeoutTask)
        continuation = nil
        connection = nil
        timeoutTask = nil
        lock.unlock()

        resources.1?.stateUpdateHandler = nil
        resources.1?.cancel()
        resources.2?.cancel()
        resources.0?.resume(returning: result)
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            finish(.reachable)
        case .waiting(let error):
            lock.lock()
            if completedResult == nil { lastWaitingError = error }
            lock.unlock()
        case .failed(let error):
            finish(TCPReachability.classify(error: error))
        case .cancelled:
            finish(.cancelled)
        case .setup, .preparing:
            break
        @unknown default:
            finish(.failed)
        }
    }

    private func timeoutReached() {
        lock.lock()
        let error = lastWaitingError
        lock.unlock()
        finish(error.map(TCPReachability.classify(error:)) ?? .timedOut)
    }
}
