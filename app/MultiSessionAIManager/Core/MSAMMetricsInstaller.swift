import Foundation

/// Compatibility entry point for onboarding. Collection is owned by the host
/// service; reconnects only attach to its shared snapshot stream.
enum MSAMMetricsInstaller {
    static let scriptRelativePath = ".local/bin/msam-metrics"
    static let commandName = "msam-metrics"
    enum Failure: Error, Equatable, LocalizedError {
        case notConnected
        case scriptNotFound
        case uploadFailed(String)
        var errorDescription: String? {
            switch self {
            case .notConnected: "Connect to the host first."
            case .scriptNotFound: "The app is missing a bundled host-service component."
            case .uploadFailed(let message): "Host service: \(message)"
            }
        }
    }
    static func install(using service: SSHService) async throws {
        _ = try await HostServiceInstaller.install(using: service)
    }
    static func ensureInstalled(using service: SSHService, host: Host? = nil, session: HerdrHostSession? = nil) async throws -> Bool {
        let status = try await HostServiceInstaller.status(using: service)
        guard !status.disabled else { return false }
        let needsInstall = !status.installed || !status.running
        let isOutdated = HostServiceInstaller.isOutdated(status)
        if needsInstall || isOutdated {
            guard let host else {
                _ = try await HostServiceInstaller.install(using: service)
                return true
            }
            if await HostMetricsLifecycle.shared.isUpdating(host) {
                return status.installed && status.running
            }
            if isOutdated, await HostMetricsLifecycle.shared.hasRecentFailure(host) {
                return status.installed && status.running
            }
            do {
                _ = try await HostMetricsLifecycle.shared.withUpdate(host, excluding: session) {
                    try await HostServiceInstaller.install(using: service)
                }
                await HostMetricsLifecycle.shared.clearRecentFailure(host)
                return true
            } catch {
                await HostMetricsLifecycle.shared.recordRecentFailure(host)
                if status.installed && status.running {
                    return true
                }
                throw error
            }
        }
        return true
    }
}
