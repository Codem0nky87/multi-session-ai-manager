import Foundation
import Observation

struct HostSetupEndpoint: Equatable, Sendable {
    let host: String
    let port: Int

    var displayName: String { "\(host):\(port)" }
}

enum HostSetupState: Equatable, Sendable {
    case idle
    case checking
    case reachable
    case failure(HostReadinessIssue)
}

/// Tests whether this iPad can open a TCP connection to a host's SSH port.
///
/// Deliberately knows nothing about HOW the iPad reaches the host. WARP,
/// Tailscale, a corporate VPN and a plain LAN are all the same to it -- that is
/// the user's own infrastructure choice, and baking one vendor's setup flow into
/// the app is what this used to do.
@MainActor @Observable
final class HostSetupModel {
    private(set) var host: Host
    private(set) var endpoint: HostSetupEndpoint
    private(set) var state: HostSetupState = .idle

    @ObservationIgnored private let reachability: any TCPReachabilityChecking
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var operationGeneration: UInt = 0

    init(
        host: Host,
        reachability: any TCPReachabilityChecking = TCPReachability()
    ) {
        self.host = host
        endpoint = .init(host: host.address, port: host.port)
        self.reachability = reachability
    }

    var statusTitle: String {
        switch state {
        case .idle: "Ready to test"
        case .checking: "Testing…"
        case .reachable: "Reachable"
        case .failure(let issue): issue.title
        }
    }

    var statusMessage: String {
        switch state {
        case .idle:
            "Check that this iPad can open an SSH connection to \(endpoint.displayName)."
        case .checking:
            "Opening a TCP connection to \(endpoint.displayName)…"
        case .reachable:
            "\(endpoint.displayName) accepted a TCP connection. SSH key and host-key verification are next."
        case .failure(let issue):
            issue.message
        }
    }

    var issueAction: String? {
        guard case .failure(let issue) = state else { return nil }
        return issue.action
    }

    func update(host: Host) {
        let newEndpoint = HostSetupEndpoint(host: host.address, port: host.port)
        guard newEndpoint != endpoint || host != self.host else { return }
        beginNewOperation()
        self.host = host
        endpoint = newEndpoint
        state = .idle
    }

    func checkRoute(timeout: Duration = .seconds(5)) {
        beginNewOperation()

        guard !endpoint.host.isEmpty,
              !endpoint.host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (1...65_535).contains(endpoint.port) else {
            state = .failure(.routeUnavailable)
            return
        }

        state = .checking
        let generation = operationGeneration
        let reachability = reachability
        let endpoint = endpoint
        checkTask = Task { [weak self] in
            let result = await reachability.check(
                host: endpoint.host,
                port: endpoint.port,
                timeout: timeout
            )
            guard let self,
                  !Task.isCancelled,
                  self.operationGeneration == generation else {
                return
            }
            self.checkTask = nil
            if result == .reachable {
                self.state = .reachable
            } else if result == .cancelled {
                self.state = .idle
            } else if let issue = HostReadiness.issue(for: result) {
                self.state = .failure(issue)
            }
        }
    }

    func cancelRouteCheck() {
        operationGeneration &+= 1
        checkTask?.cancel()
        checkTask = nil
        if state == .checking { state = .idle }
    }

    func waitForCurrentCheck() async {
        let task = checkTask
        await task?.value
    }

    private func beginNewOperation() {
        operationGeneration &+= 1
        checkTask?.cancel()
        checkTask = nil
    }
}
