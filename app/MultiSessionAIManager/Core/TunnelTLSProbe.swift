import Foundation
import NIOCore
import NIOPosix

/// Answers one question about a forwarded port: does the service behind it speak TLS?
///
/// A forward carries any TCP protocol and stores no scheme. Only the two browser
/// shortcuts need one, and they ask at the moment they open: `https://` for a
/// service that answers a TLS greeting in kind, `http://` for everything else.
protocol TunnelTLSProbing: Sendable {
    func speaksTLS(localPort: Int) async -> Bool
}

enum TunnelTLSHello {
    /// A TLS 1.2 ClientHello with no server name. A TLS server answers it with a
    /// ServerHello, or with an alert if it only accepts something newer or wants a
    /// name; both are TLS records. Anything else answers in its own protocol
    /// ("HTTP/1.1 400", "SSH-2.0…") or hangs up.
    static let clientHello: [UInt8] = {
        func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xff), UInt8(value & 0xff)] }
        func ext(_ type: Int, _ body: [UInt8]) -> [UInt8] { u16(type) + u16(body.count) + body }

        let random = (0..<32).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 0x21) }
        let cipherSuites: [UInt8] = [
            0xc0, 0x2b, 0xc0, 0x2f,  // ECDHE-ECDSA / ECDHE-RSA with AES-128-GCM
            0xc0, 0x2c, 0xc0, 0x30,  // … with AES-256-GCM
            0xcc, 0xa9, 0xcc, 0xa8,  // … with ChaCha20-Poly1305
            0x00, 0x9c, 0x00, 0x9d,  // RSA with AES-GCM
            0x00, 0x2f, 0x00, 0x35,  // RSA with AES-CBC
        ]
        let groups: [UInt8] = [0x00, 0x1d, 0x00, 0x17, 0x00, 0x18]  // x25519, secp256r1, secp384r1
        let signatures: [UInt8] = [
            0x04, 0x03, 0x08, 0x04, 0x04, 0x01,
            0x05, 0x03, 0x08, 0x05, 0x05, 0x01,
            0x02, 0x01,
        ]
        let extensions = ext(0x000a, u16(groups.count) + groups)
            + ext(0x000b, [0x01, 0x00])
            + ext(0x000d, u16(signatures.count) + signatures)

        let body: [UInt8] = [0x03, 0x03] + random
            + [0x00]                                   // no session to resume
            + u16(cipherSuites.count) + cipherSuites
            + [0x01, 0x00]                             // no compression
            + u16(extensions.count) + extensions
        let handshake: [UInt8] = [0x01, UInt8(body.count >> 16 & 0xff)] + u16(body.count) + body
        return [0x16, 0x03, 0x01] + u16(handshake.count) + handshake
    }()

    /// True when the first bytes a service sent are the header of a TLS handshake or
    /// alert record.
    static func looksLikeTLS(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 2 && (bytes[0] == 0x16 || bytes[0] == 0x15) && bytes[1] == 0x03
    }
}

/// Greets the app's own loopback listener and reads how the service at the far end
/// of the tunnel answers. No certificate is checked and nothing but the greeting is
/// sent: the browser makes its own connection, and its own trust decision, afterwards.
struct NIOTunnelTLSProbe: TunnelTLSProbing {
    var group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    /// How long a silent service is waited for. Web servers answer within a round
    /// trip; a service that waits for the client to speak a protocol it did not get
    /// says nothing at all.
    var timeout: TimeAmount = .seconds(3)

    func speaksTLS(localPort: Int) async -> Bool {
        let answer = group.next().makePromise(of: Bool.self)
        let timeout = self.timeout
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(3))
            .channelInitializer { channel in
                channel.pipeline.addHandler(TLSGreetingHandler(answer: answer, timeout: timeout))
            }
        do {
            let channel = try await bootstrap.connect(host: "127.0.0.1", port: localPort).get()
            let speaksTLS = (try? await answer.futureResult.get()) ?? false
            channel.close(promise: nil)
            return speaksTLS
        } catch {
            answer.succeed(false)
            return false
        }
    }
}

private final class TLSGreetingHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let answer: EventLoopPromise<Bool>
    private let timeout: TimeAmount
    private var received: [UInt8] = []
    private var answered = false
    private var deadline: Scheduled<Void>?

    init(answer: EventLoopPromise<Bool>, timeout: TimeAmount) {
        self.answer = answer
        self.timeout = timeout
    }

    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: TunnelTLSHello.clientHello.count)
        buffer.writeBytes(TunnelTLSHello.clientHello)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        deadline = context.eventLoop.scheduleTask(in: timeout) { [weak self] in
            self?.finish(false)
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        received += buffer.readBytes(length: buffer.readableBytes) ?? []
        if received.count >= 2 {
            finish(TunnelTLSHello.looksLikeTLS(received))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(TunnelTLSHello.looksLikeTLS(received))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(false)
        context.close(promise: nil)
    }

    private func finish(_ speaksTLS: Bool) {
        guard !answered else { return }
        answered = true
        deadline?.cancel()
        answer.succeed(speaksTLS)
    }
}
