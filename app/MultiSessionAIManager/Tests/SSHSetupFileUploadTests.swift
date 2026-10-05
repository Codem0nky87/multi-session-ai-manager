import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor
struct SSHSetupFileUploadTests {
    @Test func missingAcknowledgementNeverReportsSuccess() async throws {
        let transport = FakeSSHTransport()
        let host = Host(name: "Test", address: "fixture", username: "alice", keyID: "key", defaultWorkdir: "")
        try await transport.connect(host: host, key: .init(ed25519Seed: Data(repeating: 1, count: 32))) { _ in true }
        // Some exec channels report zero without delivering the actual remote
        // exit code. Completion must be established by the upload protocol.
        transport.defaultCommandResponse = "base64: invalid input"
        await #expect(throws: SSHSetupFileUpload.Failure.self) {
            try await SSHSetupFileUpload.upload(Data("test".utf8), to: "/home/alice/helper", using: transport)
        }
        #expect(transport.writtenFiles.isEmpty)
    }

    @Test func invalidPathsAndOversizedFilesFailBeforeSSH() async throws {
        let transport = FakeSSHTransport()
        for path in ["relative", "/", "/tmp/bad\0path"] {
            await #expect(throws: SSHSetupFileUpload.Failure.self) {
                try await SSHSetupFileUpload.upload(Data(), to: path, using: transport)
            }
        }
        await #expect(throws: SSHSetupFileUpload.Failure.self) {
            try await SSHSetupFileUpload.upload(Data(repeating: 0, count: 65_537), to: "/tmp/helper", using: transport)
        }
        #expect(transport.commandsRun.isEmpty)
    }
}
