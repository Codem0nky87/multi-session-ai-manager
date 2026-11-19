import Foundation
import Observation

/// Step 2's dependencies: verified Herdr, then metrics and the updater service.
/// On Windows, Python comes before the services: they are written in it and
/// Windows does not come with it.
/// Discovery is read-only; mutations are separate, explicit wizard actions.
@MainActor @Observable
final class AddHostProvisioningModel {
    enum MetricsState: Equatable {
        case idle
        case installing
        case ready
        case failed(String)
    }

    let connection: HostConnection
    let herdr: HerdrInstaller
    let updater: AgentUpdaterInstaller
    let integrations: HerdrIntegrationManager
    /// Python on a Windows host; nil for every other kind of host, which has it.
    private(set) var python: WindowsPythonInstaller?
    private(set) var metricsState: MetricsState = .idle
    private(set) var isBusy = false
    private var updaterSkipped = false

    init(connection: HostConnection) {
        self.connection = connection
        herdr = HerdrInstaller(connection: connection)
        updater = AgentUpdaterInstaller(connection: connection)
        integrations = HerdrIntegrationManager(connection: connection)
    }

    var herdrReady: Bool {
        guard connection.state == .connected else { return false }
        switch herdr.state {
        case .present(let version), .ready(let version):
            return HerdrInstaller.meetsMinimum(version)
        default:
            return false
        }
    }

    /// True while a Windows host has no Python for the services to run on.
    var needsPython: Bool {
        python.map { !$0.isReady } ?? false
    }

    var updaterSetup: HostAgentUpdaterSetup {
        if updaterSkipped { return .skipped }
        return switch updater.state {
        case .ready: .ready
        case .failed, .approvalRequired: .failed
        default: .unchecked
        }
    }

    var canContinue: Bool {
        !isBusy && herdrReady && metricsState == .ready
            && (updaterSetup == .ready || updaterSetup == .skipped)
    }

    var canSkipUpdater: Bool {
        guard !isBusy, herdrReady, metricsState == .ready, !updaterSkipped else { return false }
        switch updater.state {
        case .failed, .approvalRequired: return true
        default: return false
        }
    }

    func skipUpdater() {
        guard canSkipUpdater else { return }
        updaterSkipped = true
    }

    func discover() async {
        guard !isBusy, !Task.isCancelled else { return }
        isBusy = true
        defer { isBusy = false }
        if connection.state != .connected { await connection.connect() }
        guard connection.state == .connected, !Task.isCancelled else { return }
        await herdr.probe()
        guard !Task.isCancelled else { return }
        await probePython()
    }

    private func probePython() async {
        guard connection.provisioningCommandRunner?.isWindows == true else { return }
        let python = self.python ?? WindowsPythonInstaller(connection: connection)
        self.python = python
        await python.probe()
    }

    func installPython() async {
        guard !isBusy, !Task.isCancelled, connection.state == .connected,
              let python, python.canInstall else { return }
        isBusy = true
        defer { isBusy = false }
        await python.install()
    }

    func installHerdr() async {
        guard !isBusy, !Task.isCancelled, connection.state == .connected, !herdrReady else { return }
        guard herdr.canInstall || herdr.canUpdate else { return }
        isBusy = true
        defer { isBusy = false }
        if herdr.canInstall {
            await herdr.install()
        } else {
            await herdr.update()
        }
    }

    func installServices() async {
        guard !isBusy, !Task.isCancelled, herdrReady,
              let service = connection.provisioningCommandRunner else { return }
        isBusy = true
        defer { isBusy = false }

        updaterSkipped = false

        if service.isWindows, python?.isReady != true {
            // It may have been installed at the host itself since it was last looked for.
            await probePython()
            guard !needsPython, !Task.isCancelled else { return }
        }

        if metricsState != .ready {
            metricsState = .installing
            do {
                try await MSAMMetricsInstaller.install(using: service)
                try Task.checkCancellation()
                metricsState = .ready
            } catch {
                metricsState = .failed(error.localizedDescription)
                return
            }
        }
        guard !Task.isCancelled else { return }
        await updater.probe()
        guard !Task.isCancelled else { return }
        switch updater.state {
        case .absent, .failed:
            await updater.installOrRepair(policy: .manualApproval)
        default:
            break
        }
        // Readiness derives from the installer's verified state, never merely
        // from its async method returning (approval/failure also return).
    }
}
