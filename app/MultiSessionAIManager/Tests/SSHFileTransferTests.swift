import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor
struct SSHFileTransferTests {
    private func transport() async throws -> FakeSSHTransport {
        let transport = FakeSSHTransport()
        try await transport.connect(
            host: Host(name: "Test", address: "fixture", username: "alice", keyID: "key", defaultWorkdir: ""),
            key: .init(ed25519Seed: Data(repeating: 1, count: 32))) { _ in true }
        return transport
    }

    @Test func unconfirmedUploadFailsAndAttemptsCleanup() async throws {
        let transport = try await transport()
        transport.defaultCommandResponse = "permission denied"
        await #expect(throws: SSHTransportError.self) {
            try await SSHFileTransfer.upload(Data([0, 255]), to: "/tmp/image.png", using: transport)
        }
        #expect(transport.structuredCommandsRun.count == 2)
        #expect(transport.structuredCommandsRun.last?.command.contains("rm -f") == true)
    }

    @Test func invalidPathsFailBeforeAnyCommand() async throws {
        let transport = try await transport()
        for path in ["relative", "/", "/tmp/a\0b"] {
            await #expect(throws: SSHTransportError.self) {
                try await SSHFileTransfer.upload(Data(), to: path, using: transport)
            }
        }
        #expect(transport.commandsRun.isEmpty)
    }

    @Test func oversizeDownloadFailsBeforeReadingBytes() async throws {
        let transport = try await transport()
        transport.defaultCommandResponse = "\(SSHFileTransfer.maximumDownloadSize + 1)\n\nMSAM_FILE_OK\n"
        await #expect(throws: SSHTransportError.self) {
            _ = try await SSHFileTransfer.download(at: "/tmp/large", using: transport)
        }
        #expect(transport.commandsRun.count == 1)
    }

    @Test func truncatedDownloadNeverReturnsPartialData() async throws {
        let transport = try await transport()
        transport.structuredCommandResults = [
            .success(.init(exitStatus: 0, stdout: Data("3\n\nMSAM_FILE_OK\n".utf8), stderr: Data())),
            .success(.init(exitStatus: 0, stdout: Data("AA==\n\nMSAM_FILE_OK\n".utf8), stderr: Data()))
        ]
        await #expect(throws: SSHTransportError.self) {
            _ = try await SSHFileTransfer.download(at: "/tmp/file", using: transport)
        }
    }
}
