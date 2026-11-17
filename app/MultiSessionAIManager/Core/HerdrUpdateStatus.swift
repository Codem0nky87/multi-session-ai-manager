import Foundation

/// What `herdr status --json` says about the Herdr install on a host.
struct HerdrUpdateStatus: Equatable, Sendable {
    let clientVersion: String
    /// nil when no server is running: a stopped server has no version to claim.
    let serverVersion: String?
    let serverRunning: Bool
    /// A newer binary is installed than the running server — Herdr's session
    /// menu shows this as "update ready". Applied by restart or live handoff.
    let updateReady: Bool
}

/// Herdr's dotted version numbers.
enum HerdrVersion {
    /// The numbers of "0.9.5", "v0.9.5" or "0.9.5-preview.3"; nil for anything else.
    static func numbers(_ version: String) -> [Int]? {
        var text = Substring(version.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("v") || text.hasPrefix("V") { text = text.dropFirst() }
        let core = text.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }

    /// How `lhs` relates to `rhs`, number by number, so "0.9.10" follows "0.9.9".
    /// Nil when either is not a version.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = numbers(lhs), let right = numbers(rhs) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// What the Herdr row in Manage Plugins offers: which versions are involved and
/// whether pressing its button would change anything.
enum HerdrUpdateOffer: Equatable {
    /// The release list has a newer version than the installed binary.
    case available(installed: String, latest: String)
    /// A newer binary is already installed than the server is running.
    case restartNeeded(running: String?, installed: String)
    case current(String)
    /// The release list could not be read or compared: an unreachable host, or the
    /// preview channel. The update stays possible, because `herdr update` may
    /// still know better.
    case unknown(String)

    /// - Parameter latestVersion: from `HostSoftwareProvisioning.herdrRelease`, or nil
    ///   when that check gave no version.
    init(status: HerdrUpdateStatus, latestVersion: String?) {
        let installed = status.clientVersion
        let order = latestVersion.flatMap { HerdrVersion.compare($0, installed) }
        if let latestVersion, order == .orderedDescending {
            self = .available(installed: installed, latest: latestVersion)
        } else if status.updateReady {
            self = .restartNeeded(running: status.serverVersion, installed: installed)
        } else if order != nil {
            self = .current(installed)
        } else {
            self = .unknown(installed)
        }
    }

    var canUpdate: Bool {
        if case .current = self { return false }
        return true
    }

    var versionText: String {
        switch self {
        case .available(let installed, let latest):
            return "\(installed) → \(latest)"
        case .restartNeeded(let running, let installed):
            guard let running, running != installed else { return "\(installed) installed" }
            return "\(running) running → \(installed) installed"
        case .current(let version), .unknown(let version):
            return version
        }
    }

    var statusText: String {
        switch self {
        case .available: return "Update available"
        case .restartNeeded: return "Update ready"
        case .current: return "Up to date"
        case .unknown: return "Could not check for a newer version"
        }
    }

    var buttonTitle: String {
        if case .restartNeeded = self { return "Apply update" }
        return "Update Herdr"
    }
}

/// Probes and applies Herdr's own updates on a host over SSH.
enum HerdrUpdate {

    static let statusCommand = "herdr status --json"
    /// --handoff lets a running server pick the new binary up without killing
    /// the session; without a server it is a plain install.
    static let updateCommand = "herdr update --handoff"

    static let statusTimeout = Duration.seconds(30)
    /// Generous: the update downloads a release before installing it.
    static let updateTimeout = Duration.seconds(300)
    static let outputLimit = 1024 * 1024

    enum Failure: Error, Equatable {
        case statusFailed(String)
        case updateFailed(String)
    }

    static func parseStatus(_ output: String) throws -> HerdrUpdateStatus {
        guard let start = output.firstIndex(of: "{") else {
            throw Failure.statusFailed("no JSON in `herdr status` output")
        }
        let candidate = String(output[start...])
        guard let data = candidate.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let client = root["client"] as? [String: Any],
              let clientVersion = client["version"] as? String
        else {
            throw Failure.statusFailed("could not read `herdr status` output")
        }
        let server = root["server"] as? [String: Any] ?? [:]
        let update = root["update"] as? [String: Any] ?? [:]
        let running = server["running"] as? Bool ?? false
        return HerdrUpdateStatus(
            clientVersion: clientVersion,
            serverVersion: running ? server["version"] as? String : nil,
            serverRunning: running,
            // Either flag means the running server is older than the binary.
            updateReady: (update["restart_needed"] as? Bool ?? false)
                || (server["restart_needed"] as? Bool ?? false)
        )
    }

    static func probe(using service: SSHService) async throws -> HerdrUpdateStatus {
        let output: String
        do {
            let result = try await service.run(
                statusCommand, timeout: statusTimeout, outputLimit: outputLimit
            )
            output = result.stdoutString
        } catch {
            throw Failure.statusFailed("\(error)")
        }
        return try parseStatus(output)
    }

    /// Runs the update, then re-probes so the caller reports the NEW state.
    /// The re-probe is best-effort: mid-handoff the server can be briefly
    /// unreachable, and the update's own output is still the useful part.
    static func update(
        using service: SSHService
    ) async throws -> (output: String, refreshed: HerdrUpdateStatus?) {
        let output: String
        do {
            let result = try await service.run(
                updateCommand, timeout: updateTimeout, outputLimit: outputLimit
            )
            output = result.stdoutString + result.stderrString
        } catch {
            throw Failure.updateFailed("\(error)")
        }
        let refreshed = try? await probe(using: service)
        return (HerdrPluginManagement.tail(of: output, fallback: "The update reported nothing."),
                refreshed)
    }
}
