import Foundation
import NIOConcurrencyHelpers
import Observation

/// Keeps the pill beside every open host tab current, including tabs that have not
/// been opened since the app started.
///
/// Each watched host gets one SSH connection of its own that runs one command,
/// `msam-host-agent attention --loop`: a line when what needs attention changes,
/// and a heartbeat. It carries no terminal and no metrics, and it never attaches to
/// Herdr, so watching a host does not take over the layout of anyone's session
/// there. A tab's own connection is left alone: this one exists so that a host is
/// watched whether or not its tab is live.
@MainActor
@Observable
final class HostAttentionCenter {
    struct Timing: Sendable {
        /// Waits between attempts after a failed connection, the last one repeating.
        var retryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(60)]
        /// Wait before asking again a host that cannot answer usefully: one whose
        /// service has no notification stream yet, or whose key has changed.
        var unsupportedRetry: Duration = .seconds(600)
        /// How often a host that has never been connected to is looked at again,
        /// to see whether the user has opened it since. A local check, no network.
        var unknownHostRecheck: Duration = .seconds(15)
        /// The host repeats its summary every 15 s. Hearing nothing for this long
        /// means the stream is dead, whatever the socket says.
        var silenceLimit: Duration = .seconds(45)
        var checkInterval: Duration = .seconds(2)
    }

    /// The last summary from each watched host, by host id. A host with no entry
    /// is one nothing is known about, which shows no pill.
    private(set) var summaries: [UUID: HostAttention] = [:]

    @ObservationIgnored private var watches: [UUID: HostAttentionWatch] = [:]
    @ObservationIgnored private let keyStore: KeyStore
    @ObservationIgnored private let knownHosts: KnownHostsStore
    @ObservationIgnored private let makeTransport: @MainActor () -> any SSHTransport
    @ObservationIgnored private let timing: Timing

    init(keyStore: KeyStore, knownHosts: KnownHostsStore,
         makeTransport: @escaping @MainActor () -> any SSHTransport = { NIOSSHTransport() },
         timing: Timing = Timing()) {
        self.keyStore = keyStore
        self.knownHosts = knownHosts
        self.makeTransport = makeTransport
        self.timing = timing
    }

    func attention(for tab: HostTab) -> HostAttention? {
        summaries[tab.hostID]?.scoped(to: tab.sessionName)
    }

    func pill(for tab: HostTab) -> HostAttentionPill? {
        attention(for: tab)?.pill
    }

    /// Watches exactly these hosts: starts the ones that are new, stops the ones
    /// that are gone or whose details changed, and leaves the rest running.
    func watch(_ hosts: [Host]) {
        var wanted: [UUID: Host] = [:]
        for host in hosts { wanted[host.id] = host }

        for (id, watch) in watches where wanted[id] != watch.host {
            watches[id] = nil
            summaries[id] = nil
            Task { await watch.stop() }
        }
        // In the order given, so which connection belongs to which host does not
        // depend on how a dictionary happens to iterate.
        for host in hosts where watches[host.id] == nil {
            let id = host.id
            let connection = HostConnection(host: host, keyStore: keyStore, knownHosts: knownHosts,
                                            transport: makeTransport())
            let watch = HostAttentionWatch(host: host, connection: connection, knownHosts: knownHosts,
                                           timing: timing) { [weak self] summary, source in
                // A watch that was replaced or stopped has nothing more to say.
                guard let self, self.watches[id] === source else { return }
                self.summaries[id] = summary
            }
            watches[id] = watch
            watch.start()
        }
    }

    /// Ends every watch and forgets what they said. For when the app leaves the
    /// foreground: iOS suspends it anyway, and a clean reconnect on return is
    /// better than connections that died unnoticed.
    func stopAll() async {
        let stopping = Array(watches.values)
        watches = [:]
        summaries = [:]
        for watch in stopping {
            await watch.stop()
        }
    }
}

/// One host's notification connection.
@MainActor
final class HostAttentionWatch {
    private enum Heard {
        /// The stream delivered at least one summary before it ended.
        case summaries
        /// It opened and ended without one: a service too old to have the command.
        case nothing
        /// It could not be opened: the connection is not what it seems.
        case notOpened
    }

    let host: Host
    private let connection: HostConnection
    private let knownHosts: KnownHostsStore
    private let timing: HostAttentionCenter.Timing
    private let publish: (HostAttention?, HostAttentionWatch) -> Void
    private var task: Task<Void, Never>?
    private var stream: PTYChannel?
    private var stopped = false
    private var heardSummary = false
    private var lastHeard = ContinuousClock.now
    /// Which `listen` is current. Output is handed over on a later main-actor
    /// turn, so a line can arrive before its stream is stored or after it ended.
    private var listening: UInt64 = 0

    init(host: Host, connection: HostConnection, knownHosts: KnownHostsStore,
         timing: HostAttentionCenter.Timing,
         publish: @escaping (HostAttention?, HostAttentionWatch) -> Void) {
        self.host = host
        self.connection = connection
        self.knownHosts = knownHosts
        self.timing = timing
        self.publish = publish
    }

    func start() {
        guard task == nil, !stopped else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() async {
        stopped = true
        task?.cancel()
        stream?.close()
        stream = nil
        await task?.value
        task = nil
        await connection.disconnect()
    }

    private func run() async {
        var failures = 0
        var reconnect = false
        while !Task.isCancelled, !stopped {
            // The first time a host's key is trusted is when the user opens the
            // host. A background watch must not be what accepts it.
            guard knownHosts.isPinned(host: host.knownHostsKey) else {
                guard await pause(timing.unknownHostRecheck) else { return }
                continue
            }
            if reconnect || connection.state != .connected {
                await connection.connect()
                reconnect = false
            }
            guard !Task.isCancelled, !stopped else { return }
            guard connection.state == .connected, let service = connection.provisioningCommandRunner else {
                let delay: Duration
                if case .hostKeyChanged = connection.state {
                    // The user's to look at, in the host's own tab. Never trusted here.
                    delay = timing.unsupportedRetry
                } else {
                    delay = timing.retryDelays[min(failures, timing.retryDelays.count - 1)]
                    failures += 1
                }
                guard await pause(delay) else { return }
                continue
            }
            failures = 0

            let heard = await listen(using: service)
            publish(nil, self)
            switch heard {
            case .summaries:
                // The stream worked and then ended: try it again on this connection.
                guard await pause(timing.retryDelays[0]) else { return }
            case .nothing:
                reconnect = true
                guard await pause(timing.unsupportedRetry) else { return }
            case .notOpened:
                reconnect = true
                let delay = timing.retryDelays[min(failures, timing.retryDelays.count - 1)]
                failures += 1
                guard await pause(delay) else { return }
            }
        }
    }

    /// Runs the notification stream until it ends, goes silent, or the watch stops.
    private func listen(using service: SSHService) async -> Heard {
        let accumulator = NIOLockedValueBox(RemoteFileDownload.LineAccumulator())
        heardSummary = false
        lastHeard = ContinuousClock.now
        listening &+= 1
        let current = listening
        defer { listening &+= 1 }
        let channel: PTYChannel
        do {
            channel = try await service.openExecStream(
                command: HostServiceInstaller.attentionCommand(isWindows: service.isWindows),
                onOutput: { [weak self] data in
                    let lines = accumulator.withLockedValue { $0.consume(data) }
                    guard !lines.isEmpty else { return }
                    Task { @MainActor [weak self] in self?.receive(lines, from: current) }
                }
            )
        } catch {
            return .notOpened
        }
        guard !Task.isCancelled, !stopped else {
            channel.close()
            return .summaries
        }
        stream = channel
        while !Task.isCancelled, !stopped, channel.isOpen,
              ContinuousClock.now - lastHeard <= timing.silenceLimit {
            try? await Task.sleep(for: timing.checkInterval)
        }
        channel.close()
        if stream === channel { stream = nil }
        return heardSummary ? .summaries : .nothing
    }

    private func receive(_ lines: [String], from listen: UInt64) {
        guard !stopped, listen == listening else { return }
        for line in lines {
            guard let summary = HostAttention.parse(line: line) else { continue }
            heardSummary = true
            lastHeard = ContinuousClock.now
            publish(summary, self)
        }
    }

    /// False when the watch was stopped while waiting.
    private func pause(_ duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
        } catch {
            return false
        }
        return !Task.isCancelled && !stopped
    }
}
