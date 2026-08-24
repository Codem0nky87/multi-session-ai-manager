import Foundation

enum TCPReachabilityResult: Equatable, Sendable {
    case reachable
    case dnsFailure
    case networkUnavailable
    case refused
    case timedOut
    case cancelled
    case failed
}

protocol TCPReachabilityChecking: Sendable {
    func check(host: String, port: Int, timeout: Duration) async -> TCPReachabilityResult
}

enum HostReadinessIssue: Equatable, Sendable {
    /// The endpoint did not resolve or the connection failed outright. Named for
    /// the symptom rather than a transport: how the iPad reaches the host is the
    /// user's own business (WARP, Tailscale, a VPN, plain LAN), so this must not
    /// name one.
    case routeUnavailable
    case networkUnavailable
    case sshPortRefused
    case reachabilityTimedOut
    case sshAuthenticationRequired
    case herdrConfigurationMissing

    var title: String {
        switch self {
        case .routeUnavailable:
            "Host unreachable"
        case .networkUnavailable:
            "Network unavailable"
        case .sshPortRefused:
            "SSH port refused"
        case .reachabilityTimedOut:
            "Route check timed out"
        case .sshAuthenticationRequired:
            "SSH authentication required"
        case .herdrConfigurationMissing:
            "Herdr is not configured"
        }
    }

    var message: String {
        switch self {
        case .routeUnavailable:
            "The address did not resolve or refused the connection. Check the address, and that whatever carries this iPad to the host — VPN, tunnel, or local network — is connected."
        case .networkUnavailable:
            "Connect this iPad to a network, then retry."
        case .sshPortRefused:
            "The private destination answered but is not accepting TCP on the configured SSH port."
        case .reachabilityTimedOut:
            "The configured SSH endpoint did not answer before the route-check timeout."
        case .sshAuthenticationRequired:
            "The TCP route is ready; SSH key and host-key verification are the next step."
        case .herdrConfigurationMissing:
            "Install or repair Herdr after private SSH authentication succeeds."
        }
    }

    var action: String? {
        switch self {
        case .routeUnavailable:
            "Check the address and your connection"
        case .networkUnavailable:
            "Check network"
        case .sshPortRefused:
            "Check SSH service and port"
        case .reachabilityTimedOut:
            "Retry route check"
        case .sshAuthenticationRequired:
            "Authenticate with SSH"
        case .herdrConfigurationMissing:
            "Install Herdr"
        }
    }
}

enum HostReadiness {
    static func issue(for result: TCPReachabilityResult) -> HostReadinessIssue? {
        switch result {
        case .reachable, .cancelled:
            nil
        case .dnsFailure, .failed:
            .routeUnavailable
        case .networkUnavailable:
            .networkUnavailable
        case .refused:
            .sshPortRefused
        case .timedOut:
            .reachabilityTimedOut
        }
    }
}
