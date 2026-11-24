import CryptoKit
import Foundation
@testable import MultiSessionAIManager

/// A web site that wants a sign-in before it shows a page, for tests. It stands
/// where the SSH host's forwarded connections end, so a real web view reaches it
/// through the app's real proxy and nothing leaves this device.
///
/// A Windows sign-in (NTLM) is checked the way a Windows server checks it: the
/// site sends a challenge and works out what the right password would have made
/// of it. A page it hands out is therefore proof that the password arrived.
final class SignInTestSite: @unchecked Sendable {
    /// One way of signing in that the site offers, in a `WWW-Authenticate` line.
    enum Offer: Equatable, Sendable {
        /// What IIS offers first: Kerberos, or NTLM wrapped up. Never accepted here.
        case negotiate
        case ntlm
        case basic(realm: String)

        var header: String {
            switch self {
            case .negotiate: "Negotiate"
            case .ntlm: "NTLM"
            case .basic(let realm): "Basic realm=\"\(realm)\""
            }
        }
    }

    static let domain = "TESTDOM"
    static let user = "alice"
    static let password = "correct horse 9!"
    /// What the site shows when nobody has signed in.
    static let refusalText = "401 the site's own refusal"

    /// Only touched while the site's lock is held.
    private final class Connection: @unchecked Sendable {
        var buffer = Data()
        var challenge: Data?
        var signedIn = false
    }

    private let lock = NSLock()
    private var offers: [Offer]
    private var closesAfterEachPage: Bool
    private var noted: [String] = []
    private let answersAfter: TimeInterval
    private let answering = DispatchQueue(label: "sign-in-test-site.answers")

    /// - Parameters:
    ///   - offers: what the site accepts, in the order it says so.
    ///   - closesAfterEachPage: makes every page arrive on a connection of its
    ///     own. A Windows sign-in belongs to a connection, so this is how a test
    ///     makes the browser sign in again.
    ///   - answersAfter: how long the site takes over every answer, in seconds.
    init(offers: [Offer], closesAfterEachPage: Bool = false, answersAfter: TimeInterval = 0) {
        self.offers = offers
        self.closesAfterEachPage = closesAfterEachPage
        self.answersAfter = answersAfter
    }

    /// What happened at the site, in order: `asked /`, `ntlm hello`,
    /// `ntlm ok TESTDOM\alice /`, `ntlm wrong TESTDOM\alice`, `negotiate tried`,
    /// `basic ok alice /`, `basic wrong alice`, `page /next`.
    var events: [String] { lock.withLock { noted } }

    /// Plays the site on one forwarded connection.
    func serve(_ channel: FakeDirectTCPIPChannel) {
        let connection = Connection()
        channel.onSend = { [weak channel, self] data in
            let answers = lock.withLock { self.answers(to: data, on: connection) }
            guard answersAfter > 0 else {
                for answer in answers { channel?.emit(answer) }
                return
            }
            // One queue and one delay, so the answers keep their order.
            answering.asyncAfter(deadline: .now() + answersAfter) {
                for answer in answers { channel?.emit(answer) }
            }
        }
    }

    // MARK: HTTP

    private func answers(to data: Data, on connection: Connection) -> [Data] {
        connection.buffer.append(data)
        var answers: [Data] = []
        while let end = connection.buffer.range(of: Data("\r\n\r\n".utf8)) {
            let head = String(decoding: connection.buffer.subdata(in: 0..<end.lowerBound), as: UTF8.self)
            connection.buffer = connection.buffer.subdata(in: end.upperBound..<connection.buffer.count)
            answers.append(answer(to: head, on: connection))
        }
        return answers
    }

    private func answer(to head: String, on connection: Connection) -> Data {
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        // A Windows sign-in covers the connection it was made on.
        if connection.signedIn {
            noted.append("page \(path)")
            return page(path)
        }
        let sent = lines.dropFirst().first { $0.lowercased().hasPrefix("authorization:") }
            .map { $0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces) }
        guard let sent else {
            noted.append("asked \(path)")
            return refusal()
        }
        let parts = sent.split(separator: " ", maxSplits: 1).map(String.init)
        let token = parts.count > 1 ? Data(base64Encoded: parts[1]) : nil
        switch parts[0].lowercased() {
        case "ntlm" where offers.contains(.ntlm):
            guard let token, token.count > 12, token.prefix(8) == Data("NTLMSSP\0".utf8) else { break }
            if token[8] == 1 {
                let challenge = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
                connection.challenge = challenge
                noted.append("ntlm hello")
                return response("401 Unauthorized", ["WWW-Authenticate: NTLM \(Self.challengeMessage(challenge).base64EncodedString())"],
                                body: Self.refusalText)
            }
            if token[8] == 3, let challenge = connection.challenge {
                connection.challenge = nil
                guard let (domain, user, isRight) = check(token, against: challenge) else {
                    noted.append("ntlm not understood")
                    break
                }
                guard isRight else {
                    noted.append("ntlm wrong \(domain)\\\(user)")
                    break
                }
                connection.signedIn = true
                noted.append("ntlm ok \(domain)\\\(user) \(path)")
                return page(path)
            }
        case "negotiate":
            noted.append("negotiate tried")
        case "basic":
            guard offers.contains(where: { if case .basic = $0 { true } else { false } }), let token else { break }
            let pair = String(decoding: token, as: UTF8.self).split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2, pair[0] == Self.user, pair[1] == Self.password else {
                noted.append("basic wrong \(pair.first ?? "")")
                break
            }
            noted.append("basic ok \(pair[0]) \(path)")
            return page(path)
        default:
            break
        }
        return refusal()
    }

    private func refusal() -> Data {
        response("401 Unauthorized", offers.map { "WWW-Authenticate: \($0.header)" }, body: Self.refusalText)
    }

    private func page(_ path: String) -> Data {
        response("200 OK", closesAfterEachPage ? ["Connection: close"] : [],
                 body: "<html><head><title>Console</title></head><body>signed in at \(path)</body></html>")
    }

    private func response(_ status: String, _ headers: [String], body: String) -> Data {
        let payload = Data(body.utf8)
        var head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\n"
        for header in headers { head += header + "\r\n" }
        return Data((head + "\r\n").utf8) + payload
    }

    // MARK: NTLM, as in [MS-NLMP]

    private static func little(_ value: UInt16) -> Data { Data([UInt8(value & 0xff), UInt8(value >> 8)]) }
    private static func little(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }) }
    private static func wide(_ text: String) -> Data { text.data(using: .utf16LittleEndian) ?? Data() }

    /// The server's second message: its challenge and its names.
    private static func challengeMessage(_ challenge: Data) -> Data {
        let target = wide(domain)
        var names = Data()
        for (kind, name) in [(2, domain), (1, "WEB01"), (4, "testdom.example"), (3, "web01.testdom.example")] {
            let value = wide(name)
            names += little(UInt16(kind)) + little(UInt16(value.count)) + value
        }
        names += little(UInt16(0)) + little(UInt16(0))
        let headerLength = 56
        // Unicode, a target, NTLM, always sign, target is a domain, extended
        // session security, target names, a version, 128 and 56 bit.
        var message = Data("NTLMSSP\0".utf8) + little(UInt32(2))
        message += little(UInt16(target.count)) + little(UInt16(target.count)) + little(UInt32(headerLength))
        message += little(UInt32(0xA289_8205))
        message += challenge + Data(count: 8)
        message += little(UInt16(names.count)) + little(UInt16(names.count)) + little(UInt32(headerLength + target.count))
        message += Data([10, 0, 0x63, 0x45, 0, 0, 0, 15])
        return message + target + names
    }

    private static func field(_ message: Data, at offset: Int) -> Data? {
        guard message.count >= offset + 8 else { return nil }
        let length = Int(message[offset]) | Int(message[offset + 1]) << 8
        let start = (0..<4).reduce(0) { $0 | Int(message[offset + 4 + $1]) << (8 * $1) }
        guard start + length <= message.count else { return nil }
        return message.subdata(in: start..<(start + length))
    }

    /// Who the browser's third message says it is, and whether it proved it.
    private func check(_ message: Data, against challenge: Data) -> (domain: String, user: String, isRight: Bool)? {
        guard message.count >= 64,
              let proof = Self.field(message, at: 20),
              let domainBytes = Self.field(message, at: 28),
              let userBytes = Self.field(message, at: 36) else { return nil }
        let isWide = message[60] & 1 == 1
        let domain = isWide ? String(decoding: Self.sixteen(domainBytes), as: UTF16.self) : String(decoding: domainBytes, as: UTF8.self)
        let user = isWide ? String(decoding: Self.sixteen(userBytes), as: UTF16.self) : String(decoding: userBytes, as: UTF8.self)
        // Only the answer every current client gives (NTLMv2): 16 bytes of
        // proof, then what the proof was made over.
        guard proof.count > 24 else { return (domain, user, false) }
        let expected = Self.mac(key: Self.secret(user: user, domain: domain, password: Self.password),
                                challenge + proof.subdata(in: 16..<proof.count))
        return (domain, user, user.lowercased() == Self.user && expected == proof.subdata(in: 0..<16))
    }

    private static func sixteen(_ bytes: Data) -> [UInt16] {
        stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
    }

    private static func mac(key: Data, _ data: Data) -> Data {
        Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// What a server keeps instead of the password, for one user in one domain
    /// (`NTOWFv2`). The user's name counts in capitals, the domain as written.
    static func secret(user: String, domain: String, password: String) -> Data {
        mac(key: md4(wide(password)), wide(user.uppercased() + domain))
    }

    /// MD4 (RFC 1320). Windows keeps passwords as this, and no Apple library
    /// offers it any more.
    static func md4(_ message: Data) -> Data {
        var bytes = [UInt8](message)
        let bits = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: bits >> (8 * UInt64($0))) }

        func turn(_ value: UInt32, _ by: UInt32) -> UInt32 { (value << by) | (value >> (32 - by)) }
        func f(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (~x & z) }
        func g(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (x & z) | (y & z) }
        func h(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ y ^ z }

        var a: UInt32 = 0x6745_2301, b: UInt32 = 0xefcd_ab89, c: UInt32 = 0x98ba_dcfe, d: UInt32 = 0x1032_5476
        for start in stride(from: 0, to: bytes.count, by: 64) {
            let x = (0..<16).map { word -> UInt32 in
                (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[start + word * 4 + $1]) << (8 * UInt32($1)) }
            }
            let (a0, b0, c0, d0) = (a, b, c, d)
            for i in [0, 4, 8, 12] {
                a = turn(a &+ f(b, c, d) &+ x[i], 3)
                d = turn(d &+ f(a, b, c) &+ x[i + 1], 7)
                c = turn(c &+ f(d, a, b) &+ x[i + 2], 11)
                b = turn(b &+ f(c, d, a) &+ x[i + 3], 19)
            }
            for i in 0..<4 {
                a = turn(a &+ g(b, c, d) &+ x[i] &+ 0x5a82_7999, 3)
                d = turn(d &+ g(a, b, c) &+ x[i + 4] &+ 0x5a82_7999, 5)
                c = turn(c &+ g(d, a, b) &+ x[i + 8] &+ 0x5a82_7999, 9)
                b = turn(b &+ g(c, d, a) &+ x[i + 12] &+ 0x5a82_7999, 13)
            }
            for i in [0, 2, 1, 3] {
                a = turn(a &+ h(b, c, d) &+ x[i] &+ 0x6ed9_eba1, 3)
                d = turn(d &+ h(a, b, c) &+ x[i + 8] &+ 0x6ed9_eba1, 9)
                c = turn(c &+ h(d, a, b) &+ x[i + 4] &+ 0x6ed9_eba1, 11)
                b = turn(b &+ h(c, d, a) &+ x[i + 12] &+ 0x6ed9_eba1, 15)
            }
            a = a &+ a0
            b = b &+ b0
            c = c &+ c0
            d = d &+ d0
        }
        return [a, b, c, d].reduce(into: Data()) { $0 += little($1) }
    }
}

extension SignInTestSite {
    /// The app's real proxy for a browser, with this site at the far end of
    /// every connection whatever address the browser asks for.
    func proxy() async throws -> (listener: any HostBrowseProxyListener, endpoint: HostBrowseModel.Endpoint) {
        let transport = FakeSSHTransport()
        transport.onDirectTCPIPOpened = { [self] _, channel in serve(channel) }
        let host = Host(name: "first-hop", address: "192.0.2.24", port: 22, username: "operator",
                        keyID: "test-key", defaultWorkdir: "/")
        let defaults = UserDefaults(suiteName: "sign-in-site-\(UUID().uuidString)") ?? .standard
        let service = SSHService(host: host, transport: transport, knownHosts: KnownHostsStore(defaults: defaults))
        try await service.connect(key: SSHKeyMaterial(ed25519Seed: Data(repeating: 7, count: 32))) { _, _ in true }
        let credentials = HostBrowseProxyCredentials(username: "browser", password: "only-the-browser-knows")
        let listener = try await NIOHostBrowseProxyServer(service: service).start(credentials: credentials) { _ in }
        return (listener, HostBrowseModel.Endpoint(port: listener.localPort, credentials: credentials))
    }
}
