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
