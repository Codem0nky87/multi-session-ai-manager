import Foundation

enum MSAMMetricsInstaller {
    static let scriptRelativePath = ".local/bin/msam-metrics"
    static let commandName = "msam-metrics"
    static let timeout = Duration.seconds(30)
    static let outputLimit = 64 * 1024

    enum Failure: Error, Equatable {
        case notConnected
        case scriptNotFound
        case uploadFailed(String)
    }

    static func install(using service: SSHService) async throws {
        // Find the script in the bundle
        guard let scriptURL = Bundle.main.url(forResource: "msam-metrics", withExtension: "py") else {
            throw Failure.scriptNotFound
        }
        
        let scriptData: Data
        do {
            scriptData = try Data(contentsOf: scriptURL)
        } catch {
            throw Failure.uploadFailed("Could not read msam-metrics.py from bundle: \(error)")
        }

        let home: String
        do {
            let probe = try await service.run(
                "mkdir -p \"$HOME/.local/bin\" && printf %s \"$HOME\"",
                timeout: timeout,
                outputLimit: outputLimit
            )
            home = probe.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw Failure.uploadFailed("could not prepare ~/.local/bin: \(error)")
        }
        
        guard home.hasPrefix("/") else {
            throw Failure.uploadFailed("the host did not report a home directory")
        }

        do {
            try await service.writeFile(scriptData, to: "\(home)/\(scriptRelativePath)")
        } catch {
            throw Failure.uploadFailed("\(error)")
        }

        do {
            _ = try await service.run("chmod 0755 \"$HOME/\(scriptRelativePath)\"", timeout: timeout, outputLimit: outputLimit)
        } catch {
            throw Failure.uploadFailed("could not make script executable: \(error)")
        }
    }
}
