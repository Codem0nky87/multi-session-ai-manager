import Foundation
import Observation

/// The largest-files lists of one host's volumes, for the storage detail.
///
/// A list is fetched when its volume is first expanded and then kept for as long as
/// the host's session lives, so collapsing a volume, or closing the popover, does not
/// cost another walk of the disk. Only Rescan asks the host again.
@MainActor @Observable
final class VolumeUsageModel {
    enum State: Equatable {
        case scanning(since: Date)
        case loaded(VolumeUsageReport, at: Date)
        case failed(String)
    }

    let connection: HostConnection
    @ObservationIgnored private let now: () -> Date
    private var states: [String: State] = [:]

    init(connection: HostConnection, now: @escaping () -> Date = Date.init) {
        self.connection = connection
        self.now = now
    }

    /// Nil until the volume has been expanded once.
    func state(for mountPoint: String) -> State? { states[mountPoint] }

    /// The volume was expanded: scan it unless there is a list already or one is on
    /// its way. A failed attempt is tried again.
    func load(_ mountPoint: String) async {
        switch states[mountPoint] {
        case .loaded, .scanning: return
        case .failed, nil: await scan(mountPoint)
        }
    }

    func rescan(_ mountPoint: String) async {
        if case .scanning = states[mountPoint] { return }
        await scan(mountPoint)
    }

    private func scan(_ mountPoint: String) async {
        guard let service = connection.provisioningCommandRunner else {
            states[mountPoint] = .failed("Not connected to this host.")
            return
        }
        states[mountPoint] = .scanning(since: now())
        do {
            let report = try await VolumeUsageScan.largestFiles(on: mountPoint, using: service)
            states[mountPoint] = .loaded(report, at: now())
        } catch {
            states[mountPoint] = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
