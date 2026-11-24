import Foundation

/// A site asking for a user name and password before it shows a page: an
/// internal console that wants a Windows account, a tool behind HTTP Basic.
struct HostBrowserSignInRequest: Equatable, Identifiable {
    /// How the site wants the sign-in made, which decides what happens to the password.
    enum Kind: Equatable {
        /// A Windows account (NTLM). The password is used to answer a challenge
        /// and is never sent itself.
        case windows
        /// HTTP Digest: likewise answered, not sent.
        case digest
        /// HTTP Basic: the password is sent as typed, and only HTTPS hides it.
        case basic
    }

    let id: Int
    /// The site as its address names it: the host, and the port when it is not
    /// the usual one.
    let site: String
    let kind: Kind
    /// The password would cross the network for anyone on the way to read.
    let isSentUnprotected: Bool
    /// The site turned down the name and password it was given last.
    let wasRefused: Bool
    /// The name that was turned down, to be corrected rather than typed again.
    let user: String

    var title: String { "Sign in to \(site)" }

    var message: String {
        switch kind {
        case .windows:
            "This site asks for a Windows account. Write a domain account as DOMAIN\\name."
        case .digest, .basic:
            isSentUnprotected
                ? "This site asks for a user name and password. It does not use HTTPS, so the password is sent without encryption."
                : "This site asks for a user name and password."
        }
    }

    /// - Parameters:
    ///   - usesTLS: whether the page is fetched over HTTPS.
    init(id: Int, host: String, port: Int, usesTLS: Bool, kind: Kind, wasRefused: Bool = false, user: String = "") {
        self.id = id
        self.site = port == (usesTLS ? 443 : 80) || port == 0 ? host : "\(host):\(port)"
        self.kind = kind
        self.isSentUnprotected = kind == .basic && !usesTLS
        self.wasRefused = wasRefused
        self.user = user
    }
}

/// What the browser does with one authentication challenge.
enum HostBrowserChallenge: Equatable {
    /// Only the user can answer: ask for a name and password.
    case ask(HostBrowserSignInRequest.Kind)
    /// Pass over this way of signing in, so the site's next offer is asked about.
    case tryTheNextOffer
    /// Nothing the browser has a say in: the system does what it would have done.
    case leaveAlone
    /// End it here, with no answer and no further try.
    case giveUp

    /// - Parameters:
    ///   - method: `URLProtectionSpace.authenticationMethod`.
    ///   - isProxy: the challenge comes from a proxy, not from the site. The only
    ///     proxy is the app's own, which the browser already has a password for.
    ///   - failures: how often the site has already said no to this request.
    static func of(method: String, isProxy: Bool, failures: Int) -> HostBrowserChallenge {
        // A certificate is the system's to judge, unless the user said otherwise
        // for that site, which is decided before this is asked.
        if method == NSURLAuthenticationMethodServerTrust { return .leaveAlone }
        if !isProxy {
            switch method {
            case NSURLAuthenticationMethodNTLM:
                return .ask(.windows)
            case NSURLAuthenticationMethodHTTPDigest:
                return .ask(.digest)
            case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodDefault:
                return .ask(.basic)
            case NSURLAuthenticationMethodNegotiate where failures == 0:
                // "Negotiate" means Kerberos here, and this device has no ticket
                // for the site. A Windows server offers NTLM next to it; passing
                // over Negotiate is what brings that offer up.
                return .tryTheNextOffer
            default:
                break
            }
        }
        // Once a site has said no, the system's own next move is to send the
        // same answer again, and again when that is refused: a refused sign-in
        // a thousand times a minute, which locks a Windows account out. Seen on
        // 2026-11-20 against a test site. So after a no there is no next move
        // unless the user makes it.
        return failures == 0 ? .leaveAlone : .giveUp
    }
}

/// The answer to a site that asked for a sign-in.
enum HostBrowserSignInReply: Equatable, Sendable {
    case credentials(user: String, password: String)
    /// No sign-in: the user would rather not, or the page was left or its tab
    /// closed. The site shows whatever it shows to a stranger.
    case nothing
}

/// One sign-in a site is waiting for, and the way to answer it.
///
/// It is answered exactly once. WebKit raises an exception when a challenge is
/// let go without an answer, so a question that is dropped unanswered (its tab
/// closed while it was on screen, say) answers `nothing` on its way out.
@MainActor
final class HostBrowserSignInQuestion {
    let request: HostBrowserSignInRequest
    private let reply: @MainActor @Sendable (HostBrowserSignInReply) -> Void
    private var isAnswered = false

    init(request: HostBrowserSignInRequest, reply: @escaping @MainActor @Sendable (HostBrowserSignInReply) -> Void) {
        self.request = request
        self.reply = reply
    }

    func answer(_ answer: HostBrowserSignInReply) {
        guard !isAnswered else { return }
        isAnswered = true
        reply(answer)
    }

    deinit {
        guard !isAnswered else { return }
        let reply = reply
        Task { @MainActor in reply(.nothing) }
    }
}

/// The sign-ins the sites of one page are waiting for. One is shown at a time,
/// in the order they were asked.
@MainActor
struct HostBrowserSignIns {
    private var waiting: [HostBrowserSignInQuestion] = []
    private var asked = 0

    /// The one to show, if any.
    var current: HostBrowserSignInRequest? { waiting.first?.request }

    /// - Parameters:
    ///   - failures: how often the site has already said no to this request.
    ///   - user: the name it said no to.
    mutating func ask(host: String, port: Int, usesTLS: Bool, kind: HostBrowserSignInRequest.Kind,
                      failures: Int = 0, user: String = "",
                      reply: @escaping @MainActor @Sendable (HostBrowserSignInReply) -> Void) {
        asked += 1
        let request = HostBrowserSignInRequest(id: asked, host: host, port: port, usesTLS: usesTLS, kind: kind,
                                               wasRefused: failures > 0, user: failures > 0 ? user : "")
        waiting.append(HostBrowserSignInQuestion(request: request, reply: reply))
    }

    /// Answers the one that is shown. The next one, if any, is shown after it.
    mutating func answer(_ answer: HostBrowserSignInReply) {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().answer(answer)
    }

    /// The page they were asked for is gone: none of them will be signed in to.
    mutating func abandonAll() {
        let abandoned = waiting
        waiting = []
        abandoned.forEach { $0.answer(.nothing) }
    }
}
