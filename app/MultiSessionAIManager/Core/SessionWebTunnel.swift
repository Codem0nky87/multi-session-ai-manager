import Foundation
import Observation

enum SessionWebTunnelScheme: String, Codable, CaseIterable, Identifiable {
    case https
    case http

    var id: String { rawValue }
}

enum SessionWebTunnelLocalPortMode: String, CaseIterable, Identifiable {
    case automatic
    case fixed

    var id: String { rawValue }
}

struct SessionWebTunnelHop: Codable, Equatable {
    var username: String
    var host: String
    var port: Int

    init(username: String, host: String, port: Int = 22) {
        self.username = username
        self.host = host
        self.port = port
    }
}

/// Persisted definition for a web service reached from the SSH host.
struct SessionWebTunnel: Identifiable, Codable, Equatable {
    static let hopCredentialExplanation =
        "The SSH hop uses the key, SSH config, or agent available on the connected "
        + "first host. If you enter a password, it is kept only while this SSH Web "
        + "Tunnels sheet is open and is never saved. AI Manager sends it to a "
        + "temporary SSH_ASKPASS helper on the connected first host; the helper is "
        + "removed after tunnel startup. Stopping the tunnel or closing this sheet "
        + "requires password re-entry. The final web service login is separate."

    var id: UUID
    var label: String
    var scheme: SessionWebTunnelScheme
    var targetHost: String
    var targetPort: Int
    /// `nil` requests an ephemeral loopback port for each listener.
    var localPort: Int?
    /// `nil` preserves the original direct-tcpip behavior.
    var hop: SessionWebTunnelHop?

    init(
        id: UUID = UUID(),
        label: String,
        scheme: SessionWebTunnelScheme,
        targetHost: String,
        targetPort: Int,
        localPort: Int? = nil,
        hop: SessionWebTunnelHop? = nil
    ) {
        self.id = id
        self.label = label
        self.scheme = scheme
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.localPort = localPort
        self.hop = hop
    }

    var validationError: String? {
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a label."
        }
        if targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a target host."
        }
        if !(1...65_535).contains(targetPort) {
            return "Target port must be between 1 and 65535."
        }
        if let localPort, !(1...65_535).contains(localPort) {
            return "Fixed local port must be between 1 and 65535."
        }
        if let hop {
            if hop.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter an SSH hop username."
            }
            if hop.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter an SSH hop host."
            }
            if !(1...65_535).contains(hop.port) {
                return "SSH hop port must be between 1 and 65535."
            }
        }
        return nil
    }

    func loopbackURL(localPort: Int) -> URL? {
        guard (1...65_535).contains(localPort) else { return nil }
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = "127.0.0.1"
        components.port = localPort
        return components.url
    }

    func localhostURL(localPort: Int) -> URL? {
        guard (1...65_535).contains(localPort) else { return nil }
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = "localhost"
        components.port = localPort
        return components.url
    }
}

/// Pure policy used only by the Session Web Tunnel `WKNavigationDelegate`.
///
/// An untrusted/mismatched service certificate is accepted only when WebKit's
/// challenge is server trust for the exact HTTPS loopback origin created for this
/// listener. It cannot authorize a remote target URL, a different local port, an
/// HTTP tunnel, SSH host keys, or any existing/general WebView.
struct TunnelCertificatePolicy {
    let loopbackURL: URL

    func allows(
        authenticationMethod: String,
        host: String,
        port: Int,
        hasServerTrust: Bool
    ) -> Bool {
        guard authenticationMethod == NSURLAuthenticationMethodServerTrust,
              hasServerTrust,
              loopbackURL.scheme?.lowercased() == "https",
              let expectedHost = loopbackURL.host?.lowercased(),
              ["127.0.0.1", "::1", "localhost"].contains(expectedHost),
              host.lowercased() == expectedHost,
              port == effectivePort(for: loopbackURL) else {
            return false
        }
        return true
    }

    private func effectivePort(for url: URL) -> Int {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }
}

enum SessionWebTunnelStatus: Equatable {
    case idle
    case connecting
    case listening(localPort: Int)
    case open(localPort: Int)
    case failed(message: String)
}

enum SessionWebTunnelError: Error, LocalizedError {
    case couldNotStart(String)

    var errorDescription: String? {
        switch self {
        case .couldNotStart(let message):
            return message
        }
    }
}

protocol SessionWebTunnelListener: AnyObject, Sendable {
    var localPort: Int { get }
    func stop() async
}

protocol SessionWebTunnelServing: Sendable {
    func start(
        tunnel: SessionWebTunnel,
        hopPassword: String?,
        onConnectionError: @escaping @Sendable (String) -> Void
    ) async throws -> any SessionWebTunnelListener
}

extension SessionWebTunnelServing {
    func start(
        tunnel: SessionWebTunnel,
        onConnectionError: @escaping @Sendable (String) -> Void
    ) async throws -> any SessionWebTunnelListener {
        try await start(
            tunnel: tunnel,
            hopPassword: nil,
            onConnectionError: onConnectionError
        )
    }
}

@MainActor
@Observable
final class SessionWebTunnelModel {
    private let server: any SessionWebTunnelServing
    private var listener: (any SessionWebTunnelListener)?
    private var startupTask: Task<any SessionWebTunnelListener, Error>?
    private var operationGeneration: UInt = 0

    private(set) var status: SessionWebTunnelStatus = .idle
    private(set) var loopbackURL: URL?
    private(set) var localhostURL: URL?
    private(set) var activeTunnel: SessionWebTunnel?

    init(server: any SessionWebTunnelServing) {
        self.server = server
    }

    func start(_ tunnel: SessionWebTunnel, hopPassword: String? = nil) async {
        operationGeneration &+= 1
        let generation = operationGeneration
        cancelPendingStartup()

        guard let validationError = tunnel.validationError else {
            await stopListener()
            guard generation == operationGeneration else { return }

            activeTunnel = tunnel
            loopbackURL = nil
            localhostURL = nil
            status = .connecting

            let connectionErrorHandler: @Sendable (String) -> Void = {
                [weak self] message in
                Task { @MainActor [weak self] in
                    guard self?.operationGeneration == generation else {
                        return
                    }
                    self?.status = .failed(message: message)
                }
            }
            let startupTask = Task {
                try await server.start(
                    tunnel: tunnel,
                    hopPassword: hopPassword,
                    onConnectionError: connectionErrorHandler
                )
            }
            self.startupTask = startupTask

            do {
                let listener = try await startupTask.value
                guard generation == operationGeneration else {
                    await listener.stop()
                    return
                }
                self.startupTask = nil
                self.listener = listener
                loopbackURL = tunnel.loopbackURL(localPort: listener.localPort)
                localhostURL = tunnel.localhostURL(localPort: listener.localPort)
                status = .listening(localPort: listener.localPort)
            } catch {
                guard generation == operationGeneration else { return }
                self.startupTask = nil
                activeTunnel = nil
                loopbackURL = nil
                localhostURL = nil
                status = .failed(message: Self.userMessage(for: error))
            }
            return
        }

        status = .failed(message: validationError)
    }

    func webViewDidFinish() {
        guard case .listening(let port) = status else { return }
        status = .open(localPort: port)
    }

    func webViewDidFail(_ message: String) {
        status = .failed(message: message)
    }

    func stop() async {
        operationGeneration &+= 1
        cancelPendingStartup()
        await stopListener()
        activeTunnel = nil
        loopbackURL = nil
        localhostURL = nil
        status = .idle
    }

    private func stopListener() async {
        let existing = listener
        listener = nil
        await existing?.stop()
    }

    private func cancelPendingStartup() {
        let pending = startupTask
        startupTask = nil
        pending?.cancel()
    }

    private static func userMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return String(describing: error)
    }
}
