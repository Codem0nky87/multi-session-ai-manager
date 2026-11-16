import Foundation
import CryptoKit

/// A Python helper bundled with the app that a host runs when the app asks.
///
/// Content-addressed: the script is uploaded under its own SHA-256 the first time a
/// host needs that exact version and reused from then on. A new app build therefore
/// takes effect on its next call without replacing or restarting the installed host
/// service, and two devices on different builds never overwrite each other's copy.
///
/// A helper answers with one line, `<prefix><json>`; anything else it or the login
/// shell prints is ignored. `{"error": "…"}` is the helper saying why it could not.
struct HostHelperScript: Sendable {
    enum Failure: LocalizedError, Equatable {
        case failed(String)
        var errorDescription: String? { if case .failed(let reason) = self { reason } else { nil } }
    }

    /// The bundled file, e.g. `msam-disk-usage.py`.
    let resource: String
    /// Its folder under `~/.local/libexec` on the host.
    let folder: String
    /// The name it is stored under there.
    let filename: String
    /// What its answer line starts with, e.g. `MSAM_DISK_USAGE=`.
    let prefix: String

    func decode<T: Decodable>(_ type: T.Type, from output: String, missing: String) throws -> T {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(prefix) }) else {
            throw Failure.failed(HerdrPluginManagement.tail(of: output, fallback: missing))
        }
        let data = Data(line.dropFirst(prefix.count).utf8)
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let error = object["error"] as? String {
            throw Failure.failed(error)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    /// The command that runs this helper with `arguments`, after making sure the host
    /// has this version of it.
    func command(_ arguments: [String], using service: SSHService) async throws -> String {
        let data = try HostServiceInstaller.resource(resource)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let locate = """
        from pathlib import Path
        import hashlib,json,sys
        p=Path.home()/'.local/libexec'/sys.argv[2]/sys.argv[1]/sys.argv[3]
        p.parent.mkdir(parents=True,exist_ok=True)
        print(sys.argv[4]+json.dumps(dict(path=str(p),present=p.is_file() and hashlib.sha256(p.read_bytes()).hexdigest()==sys.argv[1])))
        """
        struct Location: Decodable { let path: String; let present: Bool }
        let result = try await service.run(
            HostServiceInstaller.python(locate, arguments: [hash, folder, filename, prefix], isWindows: service.isWindows),
            timeout: .seconds(30), outputLimit: 16 * 1024)
        let location = try decode(Location.self, from: result.stdoutString + result.stderrString,
                                  missing: "The host did not say where its helper script is.")
        if !location.present {
            try await service.writeSetupFile(data, to: location.path.replacingOccurrences(of: "\\", with: "/"), permissions: 0o700)
        }
        let execute = "import runpy,sys; p=sys.argv.pop(1); sys.argv[0]=p; runpy.run_path(p,run_name='__main__')"
        return HostServiceInstaller.python(execute, arguments: [location.path] + arguments, isWindows: service.isWindows)
    }

    /// - Parameters:
    ///   - missing: what to say when the helper printed no answer line at all.
    ///   - failure: what to say when it answered but exited with an error status.
    func execute<T: Decodable>(_ type: T.Type, _ arguments: [String], using service: SSHService,
                               timeout: Duration = .seconds(120), outputLimit: Int = 256 * 1024,
                               missing: String, failure: String) async throws -> T {
        let command = try await command(arguments, using: service)
        let result = try await service.run(command, timeout: timeout, outputLimit: outputLimit)
        let value = try decode(type, from: result.stdoutString + result.stderrString, missing: missing)
        guard result.exitStatus == 0 else { throw Failure.failed(failure) }
        return value
    }
}
