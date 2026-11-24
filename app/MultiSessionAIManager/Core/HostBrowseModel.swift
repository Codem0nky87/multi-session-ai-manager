import Foundation
import Observation

/// "Browse through this host": the In App browser loads pages that the SSH host
/// fetches for it. Every connection the browser makes goes to a proxy on this
/// device (`HostBrowseProxyServing`), which has the host open it by the name the
/// browser gave. The host looks the name up, so an address that exists only on
/// the host's network works, and the page sees its own real address: links,
/// redirects, cookies and certificates behave as they do on the host.
///
/// The proxy runs only while the browser is open.
@MainActor
@Observable
final class HostBrowseModel {
    /// Where the browser must send its connections, and how it proves itself.
    struct Endpoint: Equatable, Sendable {
        let port: Int
        let credentials: HostBrowseProxyCredentials
    }

    enum State: Equatable {
        case idle
        case starting
        case ready(Endpoint)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The last destination the host did not open, so a failed page can say why.
    private(set) var lastRefusal: HostBrowseRefusal?

    @ObservationIgnored private let server: any HostBrowseProxyServing
    @ObservationIgnored private let connect: @MainActor () async -> String?
    @ObservationIgnored private let makeCredentials: () -> HostBrowseProxyCredentials
    @ObservationIgnored private var listener: (any HostBrowseProxyListener)?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var isLookingAtTheProxy = false
    @ObservationIgnored private let repairGap: Duration
    @ObservationIgnored private var lastReplacement: ContinuousClock.Instant?

    /// - Parameters:
    ///   - connect: makes sure the host's SSH connection is up. Returns nil when
    ///     it is, or what to tell the user when it is not.
    ///   - repairGap: the least time between two replacements of a dead proxy.
    init(server: any HostBrowseProxyServing,
         connect: @escaping @MainActor () async -> String?,
         makeCredentials: @escaping () -> HostBrowseProxyCredentials = HostBrowseProxyCredentials.random,
         repairGap: Duration = .seconds(5)) {
        self.server = server
        self.connect = connect
        self.makeCredentials = makeCredentials
        self.repairGap = repairGap
    }

    /// True from the moment browsing is asked for until it is stopped: the SSH
    /// connection underneath has to be kept alive for that long.
    var isActive: Bool {
        switch state {
        case .starting, .ready: true
        case .idle, .failed: false
        }
    }

    func start() async {
        guard !isActive else { return }
        generation &+= 1
        let mine = generation
        state = .starting
        lastRefusal = nil

        if let problem = await connect() {
            guard mine == generation else { return }
            state = .failed(problem)
            return
        }
        guard mine == generation else { return }
        // A new pair every time: a password that was once handed to a browser is
        // never the password of a later proxy.
        let credentials = makeCredentials()
        do {
            let started = try await server.start(credentials: credentials) { [weak self] refusal in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == mine else { return }
                    self.lastRefusal = refusal
                }
            }
            guard mine == generation else {
                // Stopped while it was starting.
                await started.stop()
                return
            }
            listener = started
            state = .ready(Endpoint(port: started.localPort, credentials: credentials))
        } catch {
            guard mine == generation else { return }
            state = .failed("Could not start browsing through this host: \(error.localizedDescription)")
        }
    }

    func stop() async {
        generation &+= 1
        let stopping = listener
        listener = nil
        state = .idle
        lastRefusal = nil
        await stopping?.stop()
    }

    /// Forgets the last refusal once the page that failed has been left behind.
    func clearRefusal() {
        lastRefusal = nil
    }

    /// Replaces a proxy that no longer takes connections, and says whether it
    /// had to.
    ///
    /// The proxy listens on this device, and iOS takes the sockets of an app it
    /// has suspended. Back in front the app still called the proxy ready, the
    /// browser's every page failed with "Could not connect to the server", and
    /// went on failing, because nothing looked (user report, 2026-11-24). A
    /// dead SSH connection is a different matter and is mended underneath the
    /// proxy; this is the proxy itself.
    ///
    /// The new proxy has a new port and password, so the state changes and
    /// whoever shows the browser points its pages at it.
    ///
    /// A page that fails brings a look, and a new proxy opens that page again.
    /// Should the new proxy not stay up either, that would go round as fast as
    /// pages can fail, and every start asks something of the host. So a proxy
    /// is not replaced twice within `repairGap`; the next beat looks again.
    @discardableResult
    func repair() async -> Bool {
        guard case .ready = state, let listener, !isLookingAtTheProxy else { return false }
        if let lastReplacement, ContinuousClock.now - lastReplacement < repairGap { return false }
        isLookingAtTheProxy = true
        defer { isLookingAtTheProxy = false }
        let mine = generation
        // Stopped or restarted while it was looked at: no longer this look's to settle.
        guard await !listener.accepts(), mine == generation else { return false }
        lastReplacement = .now
        await stop()
        await start()
        return true
    }
}

/// What the user typed into the browser's address field, as an address to load.
enum HostBrowserAddress {
    /// `text` as a web address. Without a scheme it is taken as `http://`: an
    /// internal site that wants HTTPS redirects there itself, and one that
    /// speaks only HTTP would be unreachable the other way round. Anything that
    /// is not a web page (`file:`, `javascript:`) is not an address here.
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

/// What to tell the user about a page that did not load.
struct HostBrowserFailure: Equatable {
    let message: String
    /// The page's certificate is not trusted by this device: the one failure the
    /// user may choose to pass, for that site.
    let canVisitAnyway: Bool

    /// Nil for a load that was merely replaced by another one.
    static func describe(_ error: Error, url: URL?, refusal: HostBrowseRefusal?, hostName: String) -> HostBrowserFailure? {
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorCancelled { return nil }
        // "Frame load interrupted": the page handed the navigation to something else.
        if failure.domain == "WebKitErrorDomain", failure.code == 102 { return nil }

        if HostBrowseCertificateExceptions.isCertificateProblem(error), url?.scheme?.lowercased() == "https" {
            let site = url?.host ?? "this site"
            return HostBrowserFailure(
                message: "The certificate of \(site) is not trusted by this device. \(failure.localizedDescription)",
                canVisitAnyway: true)
        }
        // The host said why it would not open the address: more use than
        // WebKit's "could not connect to the proxy".
        if let refusal, let url, let host = url.host,
           refusal.destination.lowercased() == "\(host.lowercased()):\(url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))" {
            return HostBrowserFailure(message: "\(hostName) could not open \(refusal.destination). \(refusal.reason)",
                                      canVisitAnyway: false)
        }
        return HostBrowserFailure(message: failure.localizedDescription, canVisitAnyway: false)
    }
}

/// Sites whose certificate the user chose to accept, while this browser is open.
///
/// A site on an internal network often has a certificate from the company's own
/// authority, which this device does not know. The browser then refuses the page
/// and says so; only when the user answers "visit anyway" for that site is its
/// certificate accepted, for that site and port alone, and it is forgotten when
/// the browser closes.
struct HostBrowseCertificateExceptions: Equatable {
    private var accepted: Set<String> = []

    private static func key(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }

    mutating func accept(host: String, port: Int) {
        accepted.insert(Self.key(host: host, port: port))
    }

    /// The site of a page address, as an exception is keyed: host and effective port.
    mutating func accept(siteOf url: URL) {
        guard url.scheme?.lowercased() == "https", let host = url.host else { return }
        accept(host: host, port: url.port ?? 443)
    }

    func allows(authenticationMethod: String, host: String, port: Int, hasServerTrust: Bool) -> Bool {
        authenticationMethod == NSURLAuthenticationMethodServerTrust && hasServerTrust
            && accepted.contains(Self.key(host: host, port: port))
    }

    /// Whether a page failed because its certificate was not trusted, which is
    /// the one failure the user may choose to pass.
    static func isCertificateProblem(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid].contains(error.code)
    }
}
