import Foundation
import CryptoKit

enum HostServiceInstaller {
    struct Status: Decodable, Equatable, Sendable {
        let installed: Bool
        let running: Bool
        let disabled: Bool
        let version: String
        let metrics: Bool?
        let updates: Bool?
        let agents: Bool?
        let error: String?
        let manifest: [String: String]?
        /// Per-component versions reported by the host agent (service, metrics,
        /// updater protocol, and content digests for the remaining scripts).
        /// Absent from agents older than 1.1.0.
        let components: [String: String]?

        var setupState: HostAgentUpdaterSetup {
            installed && running && !disabled && updates == true ? .ready : .unchecked
        }
    }

    static let resources = ["msam-host-agent.py", "msam-metrics.py", "msam-agent-updater.sh",
        "msam-agent-updater-windows.py", "msam-metrics.ps1", "msam-host-service-windows.py",
        "msam-metrics-manage.py", "msam-host-agent-install.py", "msam-host-launcher.c.txt"]

    static func resource(_ filename: String) throws -> Data {
        let path = filename as NSString
        guard let url = Bundle.main.url(forResource: path.deletingPathExtension, withExtension: path.pathExtension) else {
            throw MSAMMetricsInstaller.Failure.scriptNotFound
        }
        return try Data(contentsOf: url)
    }

    static func powershell(_ script: String) -> String {
        WindowsShell.command(script)
    }

    static func python(_ script: String, arguments: [String], isWindows: Bool) -> String {
        if isWindows {
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
            // Windows PowerShell 5 strips embedded quotes when invoking native
            // programs. Base64 keeps Python source intact across that boundary.
            let encoded = Data(script.utf8).base64EncodedString()
            let bootstrap = "import base64;exec(base64.b64decode('\(encoded)'))"
            let args = (["-c", bootstrap] + arguments).map(quote).joined(separator: " ")
            return powershell("$ErrorActionPreference='Stop'; $py=Get-Command py.exe -ErrorAction SilentlyContinue; if ($py) { & $py.Source -3 \(args) } else { & python.exe \(args) }; exit $LASTEXITCODE")
        }
        return (["python3", "-c", script] + arguments).map(POSIXShell.quote).joined(separator: " ")
    }

    static func run(_ command: String, using service: SSHService, timeout: Duration = .seconds(45)) async throws -> SSHCommandResult {
        let result = try await service.run(command, timeout: timeout, outputLimit: 128 * 1024)
        guard result.exitStatus == 0 else {
            let detail = diagnostic(stdout: result.stdoutString, stderr: result.stderrString)
            throw MSAMMetricsInstaller.Failure.uploadFailed("Command exited with status \(result.exitStatus). \(detail)")
        }
        return result
    }

    static func parseStatus(_ text: String, stderr: String = "") throws -> Status {
        let prefix = "MSAM_HOST_STATUS="
        guard let line = text.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(prefix) }) else {
            throw MSAMMetricsInstaller.Failure.uploadFailed("The host service did not return its status. \(diagnostic(stdout: text, stderr: stderr))")
        }
        return try JSONDecoder().decode(Status.self, from: Data(line.dropFirst(prefix.count).utf8))
    }

    private static func diagnostic(stdout: String, stderr: String) -> String {
        let output = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty
            ? "No command output was received. Check that Python 3 is available and the SSH login shell runs non-interactive commands."
            : String(output.suffix(4096))
    }

    static func management(_ action: String, stage: String? = nil, using service: SSHService) async throws -> Status {
        let script: String
        if service.isWindows {
            // Keep the Windows process command line below its size limit;
            // execute the verified installer already present in the bundle.
            script = """
            import json,runpy,sys
            from pathlib import Path
            home=Path.home()
            target=(Path(sys.argv[2]) if sys.argv[1]=='install' else home/'.local/libexec/msam-host-agent/current')/'msam-host-agent-install.py'
            if not target.is_file() and sys.argv[1]=='status':
                print('MSAM_HOST_STATUS='+json.dumps(dict(installed=False,running=False,disabled=(home/'.local/state/msam-host-agent/disabled').exists(),version='')))
            else:
                sys.argv[0]=str(target)
                runpy.run_path(str(target),run_name='__main__')
            """
        } else {
            script = String(decoding: try resource("msam-host-agent-install.py"), as: UTF8.self)
        }
        let result = try await run(python(script, arguments: [action] + (stage.map { [$0] } ?? []), isWindows: service.isWindows),
                                   using: service, timeout: .seconds(120))
        return try parseStatus(result.stdoutString, stderr: result.stderrString)
    }

    static func status(using service: SSHService) async throws -> Status {
        try await management("status", using: service)
    }

    static func install(using service: SSHService) async throws -> Status {
        let probe = try await run(python("from pathlib import Path; print('MSAM_HOME=' + str(Path.home()))", arguments: [], isWindows: service.isWindows), using: service)
        guard let line = probe.stdoutString.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("MSAM_HOME=") }) else {
            throw MSAMMetricsInstaller.Failure.uploadFailed("The host did not report its home directory.")
        }
        let home = String(line.dropFirst(10)).replacingOccurrences(of: "\\", with: "/")
        guard !home.isEmpty, !home.contains("\r"), !home.contains("\n"), home.hasPrefix("/") || service.isWindows else {
            throw MSAMMetricsInstaller.Failure.uploadFailed("Invalid home directory.")
        }
        let stage = home + "/.local/libexec/.msam-host-stage-" + UUID().uuidString
        let prepare = "from pathlib import Path; import sys; Path(sys.argv[1]).mkdir(mode=0o700, parents=True)"
        _ = try await run(python(prepare, arguments: [stage], isWindows: service.isWindows), using: service)
        var manifest: [String: String] = [:]
        var activationStarted = false
        do {
            for filename in resources {
                try Task.checkCancellation()
                let data = try resource(filename)
                manifest[filename] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                try await service.writeSetupFile(data, to: stage + "/" + filename, permissions: 0o700)
            }
            try await service.writeSetupFile(try JSONEncoder().encode(manifest), to: stage + "/manifest.json", permissions: 0o600)
            try Task.checkCancellation()
            activationStarted = true
            let result = try await management("install", stage: stage, using: service)
            await cleanup(stage, using: service)
            return result
        } catch {
            let failure = error as? SSHCommandExecutionError
            if activationStarted && (failure == .ambiguousDisconnect || failure == .timedOut
                                      || failure == .cancelled || error is CancellationError) {
                // A timed-out SSH exec may still be installing. Verify the
                // exact bundle before claiming success; retain its staging
                // files while the remote outcome remains indeterminate.
                if let verified = try? await status(using: service),
                   verified.installed, verified.running, verified.metrics == true,
                   verified.manifest == manifest {
                    await cleanup(stage, using: service)
                    return verified
                }
                throw error
            }
            await cleanup(stage, using: service)
            throw error
        }
    }

    private static func cleanup(_ stage: String, using service: SSHService) async {
        let script = "import shutil,sys; from pathlib import Path; p=Path(sys.argv[1]); assert p.name.startswith('.msam-host-stage-'); shutil.rmtree(p, ignore_errors=True)"
        _ = try? await run(python(script, arguments: [stage], isWindows: service.isWindows), using: service)
    }

    static func metricsCommand(isWindows: Bool) -> String {
        if isWindows {
            return powershell("& \"$env:USERPROFILE/.local/bin/msam-host-agent.cmd\" metrics --loop; exit $LASTEXITCODE")
        }
        return "\"$HOME/.local/bin/msam-host-agent\" metrics --loop"
    }
}
