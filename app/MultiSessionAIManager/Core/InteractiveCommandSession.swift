import Foundation
import Observation

/// Runs ONE command on a host in a real PTY, with the terminal wired for input.
///
/// Exists for the commands the app cannot run for the user: anything that may
/// prompt. A `sudo` password, an installer's confirmation, an SSH passphrase —
/// none of these can be answered on an exec channel, where stdin is not a
/// terminal, so those installs hang rather than fail. Handing the user a live
/// terminal lets them answer, on the same authenticated connection.
@MainActor
@Observable
final class InteractiveCommandSession {
    enum Status: Equatable {
        case idle
        case running
        case finished
        case failed(String)
    }

    let connection: HostConnection
    let command: String
    let terminal: TerminalEmulator

    private(set) var status: Status = .idle
    private var channel: PTYChannel?

    init(connection: HostConnection, command: String, terminal: TerminalEmulator = TerminalEmulator()) {
        self.connection = connection
        self.command = command
        self.terminal = terminal
    }

    /// A login shell, so the command sees the same PATH and profile a person
    /// would — including anything an installer has just added.
    var remoteCommand: String {
        "$SHELL -lc \(POSIXShell.quote(command))"
    }

    func start() async {
        guard status != .running else { return }
        guard let service = connection.provisioningCommandRunner else {
            status = .failed("Not connected to this host.")
            return
        }
        status = .running
        let terminal = self.terminal
        do {
            let channel = try await service.openPTY(
                command: remoteCommand,
                cols: max(terminal.cols, 1),
                rows: max(terminal.rows, 1),
                onOutput: { data in
                    // `feed` is lock-backed and nonisolated, so PTY chunks can
                    // coalesce before the terminal requests one main-actor frame.
                    terminal.feed(data)
                }
            )
            self.channel = channel
            terminal.pty = channel
        } catch {
            status = .failed("\(error)")
        }
    }

    func resize(cols: Int, rows: Int) {
        terminal.resize(cols: cols, rows: rows)
    }

    func stop() async {
        channel?.close()
        channel = nil
        terminal.pty = nil
        // Permanently shut down frame scheduling. Ordinary visibility changes
        // only retire temporary frames and remain reversible.
        terminal.stop()
        if status == .running { status = .finished }
    }
}
