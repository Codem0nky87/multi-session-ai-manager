import Foundation
import Observation

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

/// Persisted definition of one port forward: a TCP service reached from the SSH host
/// (or from a second hop) and served on a loopback port of this device.
///
/// It carries no scheme. The forward moves bytes for any protocol — a web page,
/// RDP, VNC, a database — and only the two browser shortcuts need to know whether
/// to say `http` or `https`; they ask the port (`TunnelTLSProbing`). Definitions
/// saved by builds that stored a scheme still decode: the extra key is ignored.
struct SessionWebTunnel: Identifiable, Codable, Equatable {
    static let hopCredentialExplanation =
        "The SSH hop uses the key, SSH config, or agent available on the connected "
        + "first host. If you enter a password, it is kept only in memory while AI "
        + "Manager is running — never saved — and is reused when you restart this "
        + "tunnel until you quit the app or delete the tunnel. The final web "
        + "service login is separate."

    var id: UUID
    var label: String
    var targetHost: String
    var targetPort: Int
    /// `nil` requests an ephemeral loopback port for each listener.
    var localPort: Int?
    /// `nil` preserves the original direct-tcpip behavior.
    var hop: SessionWebTunnelHop?

    init(
        id: UUID = UUID(),
        label: String,
        targetHost: String,
        targetPort: Int,
        localPort: Int? = nil,
        hop: SessionWebTunnelHop? = nil
    ) {
        self.id = id
        self.label = label
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.localPort = localPort
        self.hop = hop
    }

    /// "10.0.0.8:3000", as plain text. A port interpolated straight into a SwiftUI
    /// `Text` is formatted as a quantity and comes out as "3 000" or "3,000".
    var targetAddress: String { "\(targetHost):\(targetPort)" }

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
}

/// Where a browser finds a running forward that carries a web page.
struct TunnelWebAddress: Equatable, Sendable {
    /// The origin the in-app browser loads, and the only one it will stay on.
    let loopbackURL: URL
    /// The same listener by name, for Safari.
    let localhostURL: URL

    /// - Parameter secure: whether the service answered a TLS greeting.
    init?(localPort: Int, secure: Bool) {
        guard (1...65_535).contains(localPort) else { return nil }
        var components = URLComponents()
        components.scheme = secure ? "https" : "http"
        components.port = localPort
        components.host = "127.0.0.1"
        guard let loopbackURL = components.url else { return nil }
        components.host = "localhost"
        guard let localhostURL = components.url else { return nil }
        self.loopbackURL = loopbackURL
        self.localhostURL = localhostURL
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
    /// The tunnel could not be started. It holds no port and takes no slot.
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

/// The port forwards running on one host's SSH connection.
///
/// Each forward is its own loopback listener and is started, stopped and reported on
/// by its tunnel's id; they share nothing but the connection. Up to `runningLimit`
/// run at once.
@MainActor
@Observable
final class SessionWebTunnelModel {
    static let runningLimit = 5

    private struct Run {
        var tunnel: SessionWebTunnel
        var status: SessionWebTunnelStatus
        var listener: (any SessionWebTunnelListener)?
        var startupTask: Task<any SessionWebTunnelListener, Error>?
        /// What the last connection through the listener ran into, if anything.
        var connectionProblem: String?
        /// Asked once per run, the first time a browser shortcut needs it.
        var speaksTLS: Bool?
    }

    private let server: any SessionWebTunnelServing
    private let probe: any TunnelTLSProbing
    private var runs: [UUID: Run] = [:]
    /// Ids of connecting and listening tunnels, oldest first.
    private var order: [UUID] = []
    /// Bumped by every start and stop of a tunnel, so the late result of a start that
    /// was since stopped or restarted cannot overwrite what replaced it.
    private var generations: [UUID: UInt] = [:]
    /// Called when a connection through a listening tunnel fails. A dead SSH link
    /// shows up this way first, so whoever keeps the link alive checks it now
    /// rather than at its next beat.
    @ObservationIgnored var onConnectionProblem: (() -> Void)?

    init(server: any SessionWebTunnelServing, probe: any TunnelTLSProbing = NIOTunnelTLSProbe()) {
        self.server = server
        self.probe = probe
    }

    func status(for id: UUID) -> SessionWebTunnelStatus {
        runs[id]?.status ?? .idle
    }

    /// Why the last connection through a listening tunnel failed, for example a
    /// target that refused it. The tunnel keeps listening: the service may yet start.
    func connectionProblem(for id: UUID) -> String? {
        runs[id]?.connectionProblem
    }

    /// Drops what earlier connections ran into: the link they failed on has been
    /// replaced, so the next connection starts with a clean slate.
    func clearConnectionProblems() {
        for id in runs.keys {
            runs[id]?.connectionProblem = nil
        }
    }

    /// Tunnels that are connecting or listening, in the order they were started.
    var running: [SessionWebTunnel] {
        order.compactMap { runs[$0]?.tunnel }
    }

    var runningCount: Int { order.count }

    var canStartAnother: Bool { runningCount < Self.runningLimit }

    /// Starts `tunnel`, or restarts it if it is already running. Other tunnels are
    /// left alone.
    func start(_ tunnel: SessionWebTunnel, hopPassword: String? = nil) async {
        let id = tunnel.id
        let generation = advanceGeneration(of: id)
        await retire(id)
        guard generation == generations[id] else { return }

        if let validationError = tunnel.validationError {
            runs[id] = Run(tunnel: tunnel, status: .failed(message: validationError))
            return
        }
        guard canStartAnother else {
            runs[id] = Run(tunnel: tunnel, status: .failed(
                message: "\(Self.runningLimit) forwards are already running. Stop one to start another."))
            return
        }

        let connectionErrorHandler: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.generations[id] == generation, self.runs[id]?.listener != nil else { return }
                self.runs[id]?.connectionProblem = message
                self.onConnectionProblem?()
            }
        }
        let server = self.server
        let startupTask = Task {
            try await server.start(
                tunnel: tunnel,
                hopPassword: hopPassword,
                onConnectionError: connectionErrorHandler
            )
        }
        runs[id] = Run(tunnel: tunnel, status: .connecting, startupTask: startupTask)
        order.append(id)

        do {
            let listener = try await startupTask.value
            guard generation == generations[id] else {
                await listener.stop()
                return
            }
            runs[id]?.startupTask = nil
            runs[id]?.listener = listener
            runs[id]?.status = .listening(localPort: listener.localPort)
        } catch {
            guard generation == generations[id] else { return }
            order.removeAll { $0 == id }
            runs[id] = Run(tunnel: tunnel, status: .failed(message: Self.userMessage(for: error)))
        }
    }

    /// Stops one tunnel, or clears its failure. The rest keep running.
    func stop(_ id: UUID) async {
        advanceGeneration(of: id)
        await retire(id)
    }

    func stopAll() async {
        for id in Array(runs.keys) {
            await stop(id)
        }
    }

    /// The `http://` or `https://` address of a listening tunnel, for the browser
    /// shortcuts. Nil for a tunnel that is not listening.
    func webAddress(for id: UUID) async -> TunnelWebAddress? {
        guard case .listening(let port) = status(for: id) else { return nil }
        if let known = runs[id]?.speaksTLS {
            return TunnelWebAddress(localPort: port, secure: known)
        }
        let generation = generations[id]
        let secure = await probe.speaksTLS(localPort: port)
        if generation == generations[id] {
            runs[id]?.speaksTLS = secure
        }
        return TunnelWebAddress(localPort: port, secure: secure)
    }

    @discardableResult
    private func advanceGeneration(of id: UUID) -> UInt {
        let next = (generations[id] ?? 0) &+ 1
        generations[id] = next
        return next
    }

    /// Forgets a tunnel's run: cancels a start in flight and closes its listener.
    private func retire(_ id: UUID) async {
        guard let run = runs.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        run.startupTask?.cancel()
        await run.listener?.stop()
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
