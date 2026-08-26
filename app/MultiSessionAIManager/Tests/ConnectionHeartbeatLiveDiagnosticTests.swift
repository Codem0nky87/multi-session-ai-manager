import Darwin
import Foundation
import Testing
@testable import MultiSessionAIManager

/// DIAGNOSTIC ONLY — reproduces issue #1 (idle connection dies, tab freezes as
/// "live") against the REAL `NIOSSHTransport` and this Mac's sshd, through a
/// local TCP relay that can turn into a black hole: an evicted NAT/firewall
/// flow delivers no FIN and no RST, it simply never answers again. The fake
/// transport cannot reproduce that, because `FakePTYChannel.isOpen` is under
/// the test's control; here the claim is about Citadel/NIO's own behavior.
///
/// Requires `/tmp/msam-diag-seed.hex` (a raw ed25519 seed whose public key is
/// in this Mac's `authorized_keys`). Skips cleanly when absent, so it is inert
/// on any other machine and in CI.
@Suite(.serialized) @MainActor
struct ConnectionHeartbeatLiveDiagnosticTests {
    private static var seed: Data? {
        guard let hex = try? String(contentsOfFile: "/tmp/msam-diag-seed.hex", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            hex.count == 64
        else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// `NSUserName()` is EMPTY inside the iOS simulator, which turns this
    /// diagnostic's ssh into an authentication failure as user "". The
    /// simulator's sandbox home still lives under the Mac account's real
    /// `/Users/<name>/...` path, so recover the name from there.
    private static var localUsername: String? {
        let name = NSUserName()
        if !name.isEmpty { return name }
        let parts = NSHomeDirectory().split(separator: "/")
        guard parts.count >= 2, parts.first == "Users" else { return nil }
        return String(parts[1])
    }

    @Test func halfOpenConnectionIsInvisibleToIsOpenButCaughtByTheProbe() async throws {
        guard let seed = Self.seed else {
            print("SKIP: no /tmp/msam-diag-seed.hex")
            return
        }
        guard let username = Self.localUsername else {
            print("SKIP: cannot determine the Mac username from this environment")
            return
        }
        let proxy = BlackholeProxy()
        try proxy.start(targetPort: 22)
        defer { proxy.stopListening() }

        let host = Host(
            name: "proxied-localhost",
            address: "127.0.0.1",
            port: Int(proxy.port),
            username: username,
            keyID: "diagnostic",
            defaultWorkdir: NSHomeDirectory()
        )
        let transport = NIOSSHTransport()
        let knownHosts = KnownHostsStore(defaults: UserDefaults(suiteName: "msam.diag.\(UUID())")!)
        let service = SSHService(host: host, transport: transport, knownHosts: knownHosts)
        do {
            try await service.connect(key: SSHKeyMaterial(ed25519Seed: seed)) { _, _ in true }
        } catch {
            print("SKIP: /tmp/msam-diag-seed.hex is present but not authorized here (\(error))")
            return
        }

        // A quiet interactive PTY through the proxy -- a live tab whose agent
        // has gone idle.
        let pty = try await service.openPTY(command: "cat", cols: 80, rows: 24) { _ in }
        try await Task.sleep(for: .seconds(1))
        #expect(pty.isOpen)

        // The probe round-trips while the link is healthy.
        try await service.ping(timeout: .seconds(10))

        // The NAT evicts the idle flow: nothing announces it.
        proxy.blackhole()
        try await Task.sleep(for: .seconds(2))

        // ROOT CAUSE, on the real stack: no EOF ever arrives, so the channel
        // still claims to be open over a corpse...
        #expect(pty.isOpen)
        // ...and a keystroke lands in kernel buffers without an error, so even
        // a send cannot expose the death here. Only a round trip can.
        pty.send(Data("echo DIAG\n".utf8))
        try await Task.sleep(for: .seconds(1))
        #expect(pty.isOpen)

        // THE FIX: the probe's deadline catches what isOpen cannot.
        var probeFailed = false
        do {
            try await service.ping(timeout: .seconds(4))
        } catch {
            probeFailed = true
            print("DIAG: probe failed as expected on the dead link: \(error)")
        }
        #expect(probeFailed)

        // RECOVERY, as `HerdrHostSession.recoverLostConnection` + `start()` do
        // it: tear the corpse down and redial -- a fresh TCP flow through the
        // same proxy, which (like a real NAT) carries new connections fine.
        await service.disconnect()
        try await service.connect(key: SSHKeyMaterial(ed25519Seed: seed)) { _, _ in true }
        try await service.ping(timeout: .seconds(10))
        await service.disconnect()
    }
}

/// A TCP relay to a local port that can BLACKHOLE its established flows:
/// blackholed flows keep being read (so neither side ever sees an EOF or an
/// RST -- reads even keep getting TCP ACKs) but nothing is forwarded, which is
/// exactly what a NAT/firewall eviction looks like from the SSH layer.
/// Connections accepted AFTER `blackhole()` relay normally, the way a real NAT
/// treats a fresh flow.
private final class BlackholeProxy: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var listenFD: Int32 = -1
    private(set) var port: UInt16 = 0

    /// Kill every currently-established flow, silently.
    func blackhole() {
        lock.withLock { generation += 1 }
    }

    private func currentGeneration() -> Int {
        lock.withLock { generation }
    }

    func start(targetPort: UInt16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyError.socket }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0   // ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw ProxyError.bind
        }

        var bod = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bod) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        port = UInt16(bigEndian: bod.sin_port)
        listenFD = fd

        Thread.detachNewThread { [self] in acceptLoop(targetPort: targetPort) }
    }

    func stopListening() {
        let fd = lock.withLock { () -> Int32 in
            let fd = listenFD
            listenFD = -1
            return fd
        }
        if fd >= 0 { close(fd) }
        // Relay threads for still-open flows are left to die with the process:
        // this is a test-lifetime diagnostic, not a server.
    }

    private func acceptLoop(targetPort: UInt16) {
        while true {
            let fd = lock.withLock { listenFD }
            guard fd >= 0 else { return }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }

            let upstream = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = targetPort.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else {
                close(client)
                close(upstream)
                continue
            }

            let bornAt = currentGeneration()
            relay(from: client, to: upstream, bornAt: bornAt)
            relay(from: upstream, to: client, bornAt: bornAt)
        }
    }

    private func relay(from: Int32, to: Int32, bornAt: Int) {
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = read(from, &buffer, buffer.count)
                guard n > 0 else { break }
                // A blackholed flow still READS -- no EOF, no RST, the kernel
                // even ACKs -- but forwards nothing. From the SSH layer this is
                // indistinguishable from a NAT eviction.
                guard currentGeneration() == bornAt else { continue }
                var offset = 0
                while offset < n {
                    let written = buffer.withUnsafeBytes { raw -> Int in
                        write(to, raw.baseAddress!.advanced(by: offset), n - offset)
                    }
                    guard written > 0 else { return }
                    offset += written
                }
            }
            // The far side closed. Propagating that with a real close would
            // hand the client the EOF a blackholed flow must never see.
            if currentGeneration() == bornAt {
                shutdown(to, SHUT_WR)
            }
        }
    }

    private enum ProxyError: Error {
        case socket, bind
    }
}
