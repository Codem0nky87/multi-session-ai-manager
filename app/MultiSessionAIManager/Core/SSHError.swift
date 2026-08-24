import Foundation

enum SSHFailure: Equatable {
    case unreachable, authRejected, hostKeyMismatch, unknown

    static func classify(message: String) -> SSHFailure {
        let m = message.lowercased()
        if m.contains("timed out") || m.contains("refused") || m.contains("no route")
            || m.contains("not reachable") { return .unreachable }
        if (m.contains("host key") && (m.contains("mismatch") || m.contains("verification failed")
            || m.contains("changed"))) || m.contains("identification has changed") {
            return .hostKeyMismatch
        }
        if m.contains("auth") || m.contains("permission denied") || m.contains("publickey")
            { return .authRejected }
        return .unknown
    }
    var userMessage: String {
        switch self {
        case .unreachable: return "Can't reach this host. Is the WARP (Cloudflare One) client connected?"
        case .authRejected: return "Authentication failed. Make sure this key's public half is in the host's ~/.ssh/authorized_keys."
        case .hostKeyMismatch: return "Host key changed since last connect. This could be a security issue — verify the host before continuing."
        case .unknown: return "SSH connection failed."
        }
    }
}
