import Foundation
import Observation

/// Coordinates maintenance with every tab for the same SSH account. Closing
/// only metrics channels leaves terminal sessions and file watchers intact.
@MainActor
final class HostMetricsLifecycle {
    static let shared = HostMetricsLifecycle()
    private struct Entry { weak var session: HerdrHostSession? }
    private var sessions: [Entry] = []
    private var updating: Set<String> = []

    private func key(_ host: Host) -> String {
        "\(host.username)@\(host.address):\(host.port)"
    }

    func register(_ session: HerdrHostSession) {
        sessions.removeAll { $0.session == nil }
        sessions.append(Entry(session: session))
    }

    func isUpdating(_ host: Host) -> Bool { updating.contains(key(host)) }

    func begin(_ host: Host) async throws {
        let key = key(host)
        guard updating.insert(key).inserted else {
            throw MSAMMetricsInstaller.Failure.uploadFailed("Another metrics operation is already in progress.")
        }
        for session in matching(host) { await session.pauseMetricsStream() }
    }

    func finish(_ host: Host) async {
        updating.remove(key(host))
        for session in matching(host) { await session.ensureMetricsStream() }
    }

    private func matching(_ host: Host) -> [HerdrHostSession] {
        sessions.removeAll { $0.session == nil }
        return sessions.compactMap(\.session).filter { key($0.connection.host) == key(host) }
    }
}

@MainActor @Observable
final class HostServiceManager {
    let connection: HostConnection
    private let onVerifiedStatus: (HostServiceInstaller.Status) -> Void
    private(set) var installation: HostServiceInstaller.Status?
    private(set) var isBusy = false
    private(set) var message: String?
    private(set) var error: String?

    init(connection: HostConnection, onVerifiedStatus: @escaping (HostServiceInstaller.Status) -> Void = { _ in }) {
        self.connection = connection
        self.onVerifiedStatus = onVerifiedStatus
    }

    private func record(_ status: HostServiceInstaller.Status) {
        installation = status
        onVerifiedStatus(status)
    }

    func refresh() async {
        guard !isBusy, let service = connection.provisioningCommandRunner else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do { record(try await HostServiceInstaller.status(using: service)) }
        catch {
            installation = nil
            self.error = error.localizedDescription
        }
    }

    func perform(_ action: String) async {
        guard !isBusy, let service = connection.provisioningCommandRunner else { return }
        isBusy = true
        error = nil
        message = nil
        defer { isBusy = false }
        do {
            try await HostMetricsLifecycle.shared.begin(connection.host)
            do {
                if action == "install" {
                    record(try await HostServiceInstaller.install(using: service))
                } else {
                    record(try await HostServiceInstaller.management(action, using: service))
                }
                message = action == "install"
                    ? "Host service updated. The old updater service and metrics collectors were removed."
                    : "Host service: \(action) completed."
            } catch {
                await HostMetricsLifecycle.shared.finish(connection.host)
                throw error
            }
            await HostMetricsLifecycle.shared.finish(connection.host)
        } catch {
            installation = nil
            self.error = error.localizedDescription
        }
    }
}
