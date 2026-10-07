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
    static func ensureInstalled(using service: SSHService) async throws -> Bool {
        let status = try await HostServiceInstaller.status(using: service)
        return status.installed && status.running && !status.disabled
    }
}
