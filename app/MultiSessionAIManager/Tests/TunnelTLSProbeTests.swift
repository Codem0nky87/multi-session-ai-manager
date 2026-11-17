import Darwin
import Foundation
import Testing
@testable import MultiSessionAIManager

/// How the app tells an HTTPS service from a plain one on a forwarded port, now that
/// a tunnel no longer stores a scheme.
@Suite(.serialized) struct TunnelTLSProbeTests {
    private func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: - Reading the answer

    @Test func aTLSRecordHeaderIsRecognised() {
        #expect(TunnelTLSHello.looksLikeTLS([0x16, 0x03, 0x03, 0x00, 0x5a]), "ServerHello")
        #expect(TunnelTLSHello.looksLikeTLS([0x15, 0x03, 0x01, 0x00, 0x02, 0x02, 0x46]), "alert: wrong version, still TLS")
    }

    @Test func otherProtocolsAreNotMistakenForTLS() {
        #expect(!TunnelTLSHello.looksLikeTLS(ascii("HTTP/1.1 400 Bad Request\r\n")))
        #expect(!TunnelTLSHello.looksLikeTLS(ascii("SSH-2.0-OpenSSH_9.6\r\n")))
        #expect(!TunnelTLSHello.looksLikeTLS(ascii("RFB 003.008\n")))
        #expect(!TunnelTLSHello.looksLikeTLS([0x03, 0x00, 0x00, 0x13]), "RDP's TPKT header")
        #expect(!TunnelTLSHello.looksLikeTLS([0x16]), "one byte is not a header")
        #expect(!TunnelTLSHello.looksLikeTLS([]))
    }

    // MARK: - What is sent

    @Test func theGreetingIsAWellFormedClientHello() {
        let hello = TunnelTLSHello.clientHello
        #expect(Array(hello.prefix(3)) == [0x16, 0x03, 0x01], "handshake record, TLS 1.0 record version")
        let recordLength = Int(hello[3]) << 8 | Int(hello[4])
        #expect(recordLength == hello.count - 5)
        #expect(hello[5] == 0x01, "ClientHello")
        let handshakeLength = Int(hello[6]) << 16 | Int(hello[7]) << 8 | Int(hello[8])
        #expect(handshakeLength == hello.count - 9)
        #expect(Array(hello[9...10]) == [0x03, 0x03], "offers TLS 1.2")
    }

    // MARK: - Against a listening port

    @Test func aPortThatAnswersInTLSIsHTTPS() async throws {
        let server = try LoopbackResponder(reply: [0x16, 0x03, 0x03, 0x00, 0x04, 0x02, 0x00, 0x00, 0x00])
        #expect(await NIOTunnelTLSProbe().speaksTLS(localPort: server.port))
        #expect(server.received == TunnelTLSHello.clientHello, "The service is sent exactly the ClientHello")
    }

    @Test func aPortThatAnswersInPlainHTTPIsNotHTTPS() async throws {
        let server = try LoopbackResponder(reply: ascii("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"))
        #expect(await NIOTunnelTLSProbe().speaksTLS(localPort: server.port) == false)
    }

    @Test func aPortThatHangsUpIsNotHTTPS() async throws {
        let server = try LoopbackResponder(reply: [])
        #expect(await NIOTunnelTLSProbe().speaksTLS(localPort: server.port) == false)
    }

    @Test func aPortThatSaysNothingIsGivenUpOn() async throws {
        let server = try LoopbackResponder(reply: nil)
        let started = Date()
        #expect(await NIOTunnelTLSProbe(timeout: .milliseconds(300)).speaksTLS(localPort: server.port) == false)
        #expect(Date().timeIntervalSince(started) < 2, "A silent service must not hold the browser back")
    }

    @Test func aPortNobodyListensOnIsNotHTTPS() async throws {
        let server = try LoopbackResponder(reply: [])
        let port = server.port
        server.shutDown()
        #expect(await NIOTunnelTLSProbe(timeout: .milliseconds(500)).speaksTLS(localPort: port) == false)
    }
}

/// A one-connection TCP server on 127.0.0.1: records what it is sent, answers with
/// `reply`, and closes. A nil reply stays silent; an empty one hangs up at once.
private final class LoopbackResponder: @unchecked Sendable {
    let port: Int
    private let descriptor: Int32
    private let lock = NSLock()
    private var _received: [UInt8] = []
    private var closed = false

    init(reply: [UInt8]?) throws {
        // Locals until every stored property is set: the socket calls take closures.
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.ENOTSOCK) }
        var reuse: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(socket, 4) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE
            Darwin.close(socket)
            throw POSIXError(code)
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(socket, $0, &length)
            }
        }
        descriptor = socket
        port = Int(in_port_t(bigEndian: assigned.sin_port))

        let listening = descriptor
        Thread.detachNewThread { [weak self] in
            let client = Darwin.accept(listening, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            guard let reply else {
                // Silent: hold the connection open well past any probe timeout.
                usleep(3_000_000)
                return
            }
            guard !reply.isEmpty else { return }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(client, &buffer, buffer.count)
            if count > 0 {
                self?.lock.withLock { self?._received = Array(buffer[0..<count]) }
            }
            _ = reply.withUnsafeBytes { Darwin.write(client, $0.baseAddress, reply.count) }
            usleep(200_000)
        }
    }

    var received: [UInt8] {
        lock.withLock { _received }
    }

    func shutDown() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            Darwin.close(descriptor)
        }
    }

    deinit {
        shutDown()
    }
}
