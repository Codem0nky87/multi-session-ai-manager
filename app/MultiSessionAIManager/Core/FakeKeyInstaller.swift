import Foundation

final class FakeKeyInstaller: KeyInstaller, @unchecked Sendable {
    var connectError: Error?
    var commandError: Error?
    private(set) var connected = false
    private(set) var commandsRun: [String] = []
    var hostKeyToPresent = "FAKEFP"
    var responses: [String: String] = [:]

    func connect(host: Host, username: String, password: String,
                 hostKeyValidator: @escaping @Sendable (String) -> Bool) async throws {
        if let e = connectError { throw e }
        _ = hostKeyValidator(hostKeyToPresent)
        connected = true
    }
    func runCommand(_ cmd: String) async throws -> String {
        if let e = commandError { throw e }
        commandsRun.append(cmd)
        return responses[cmd] ?? ""
    }
    func disconnect() async { connected = false }
}
