import Foundation
import Crypto
import NIOCore
import NIOConcurrencyHelpers
import NIOSSH
@preconcurrency import Citadel

/// Real SFTP `FileTransfer` built on Citadel. Manages its OWN `SSHClient` +
/// `SFTPClient` connection (separate from `NIOSSHTransport`'s command/PTY
/// connection — see the report). Connection + auth + host-key validation mirror
/// `NIOSSHTransport` exactly (ed25519 seed, custom fingerprint validator).
///
/// Concurrency: nio delivers IO on an `EventLoop`, not the main thread. The
/// `hostKeyValidator` is `@Sendable`; mutable client/sftp state lives behind a
/// `NIOLockedValueBox`, so the class is `@unchecked Sendable`. `@preconcurrency
/// import Citadel` because not all Citadel types carry Swift 6 Sendable
/// annotations.
///
/// Runtime-unverifiable here: needs a live SSH/SFTP server, which the
/// simulator/CI does not provide. Acceptance for Task 6.2 is "compiles,
/// conforms to the seam, uses the real Citadel SFTP API"; on-device validation
/// happens in Phase 8.
final class CitadelFileTransfer: FileTransfer, @unchecked Sendable {

    private let host: Host
    private let key: SSHKeyMaterial
    private let hostKeyValidator: @Sendable (String) -> Bool

    /// Guards the lazily-established SSH + SFTP clients. Both are nil until the
    /// first `connect()`; never mutated without holding the lock.
    private struct Connection {
        var ssh: SSHClient
        var sftp: SFTPClient
    }
    private let connectionBox = NIOLockedValueBox<Connection?>(nil)

    init(host: Host, key: SSHKeyMaterial,
         hostKeyValidator: @escaping @Sendable (String) -> Bool) {
        self.host = host
        self.key = key
        self.hostKeyValidator = hostKeyValidator
    }

    // MARK: - Lazy connect

    /// Establish the SSH client and open SFTP on first use; reuse thereafter.
    private func connect() async throws -> SFTPClient {
        if let existing = connectionBox.withLockedValue({ $0 }) {
            return existing.sftp
        }

        let privateKey: Curve25519.Signing.PrivateKey
        do {
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: key.ed25519Seed)
        } catch {
            throw FileTransferError.failed("invalid ed25519 seed: \(error)")
        }

        let auth = SSHAuthenticationMethod.ed25519(username: host.username, privateKey: privateKey)
        let validator = SSHHostKeyValidator.custom(SSHFingerprintHostKeyValidator(accept: hostKeyValidator))

        let ssh: SSHClient
        do {
            ssh = try await SSHClient.connect(
                host: host.address,
                port: host.port,
                authenticationMethod: auth,
                hostKeyValidator: validator,
                reconnect: .never
            )
        } catch {
            throw FileTransferError.failed("connect failed: \(error)")
        }

        let sftp: SFTPClient
        do {
            sftp = try await ssh.openSFTP()
        } catch {
            try? await ssh.close()
            throw FileTransferError.failed("openSFTP failed: \(error)")
        }

        // Another caller may have raced us to a connection; if so, keep theirs
        // and tear down ours.
        let winner = connectionBox.withLockedValue { box -> SFTPClient in
            if let existing = box {
                return existing.sftp
            }
            box = Connection(ssh: ssh, sftp: sftp)
            return sftp
        }

        if winner !== sftp {
            try? await sftp.close()
            try? await ssh.close()
        }
        return winner
    }

    // MARK: - FileTransfer

    func listDirectory(_ path: String) async throws -> [RemoteFile] {
        let sftp = try await connect()
        let names: [SFTPMessage.Name]
        do {
            names = try await sftp.listDirectory(atPath: path)
        } catch {
            throw Self.mapError(error)
        }

        var files: [RemoteFile] = []
        for name in names {
            for entry in name.components {
                let filename = entry.filename
                if filename == "." || filename == ".." { continue }
                let isDir = Self.isDirectory(entry)
                files.append(RemoteFile(
                    name: filename,
                    path: FileBrowserModel.join(path, filename),
                    isDirectory: isDir,
                    size: isDir ? 0 : Int(entry.attributes.size ?? 0)
                ))
            }
        }
        return files
    }

    func read(_ path: String) async throws -> Data {
        let sftp = try await connect()
        do {
            let file = try await sftp.openFile(filePath: path, flags: .read)
            do {
                let buffer = try await file.readAll()
                try await file.close()
                return Data(buffer.readableBytesView)
            } catch {
                try? await file.close()
                throw error
            }
        } catch {
            throw Self.mapError(error)
        }
    }

    func write(_ data: Data, to path: String) async throws {
        let sftp = try await connect()
        do {
            let file = try await sftp.openFile(
                filePath: path,
                flags: [.write, .create, .truncate]
            )
            do {
                try await file.write(ByteBuffer(bytes: data))
                try await file.close()
            } catch {
                try? await file.close()
                throw error
            }
        } catch {
            throw Self.mapError(error)
        }
    }

    // MARK: - Disconnect

    func disconnect() async {
        let conn = connectionBox.withLockedValue { box -> Connection? in
            let existing = box
            box = nil
            return existing
        }
        if let conn {
            try? await conn.sftp.close()
            try? await conn.ssh.close()
        }
    }

    // MARK: - Helpers

    /// Determine whether an SFTP directory entry is a directory. SFTP v3 carries
    /// the full POSIX mode in `attributes.permissions` (when the server sends the
    /// permissions flag), where the file-type field is the high bits and
    /// `S_IFDIR` is `0o040000`. Fall back to the `longname` `ls -l` field whose
    /// first character is `d` for directories when permissions are absent.
    private static func isDirectory(_ entry: SFTPPathComponent) -> Bool {
        if let perms = entry.attributes.permissions {
            let sIFMT: UInt32  = 0o170000
            let sIFDIR: UInt32 = 0o040000
            return (perms & sIFMT) == sIFDIR
        }
        if let first = entry.longname.first {
            return first == "d"
        }
        return false
    }

    /// Map Citadel/SFTP errors onto the seam's `FileTransferError`.
    private static func mapError(_ error: Error) -> FileTransferError {
        if let e = error as? FileTransferError { return e }

        // Citadel surfaces SFTP non-ok statuses as SFTPError.errorStatus(Status),
        // and a raw SFTPMessage.Status is itself an Error.
        if case let SFTPError.errorStatus(status) = error {
            return mapStatus(status)
        }
        if let status = error as? SFTPMessage.Status {
            return mapStatus(status)
        }
        return .failed(String(describing: error))
    }

    private static func mapStatus(_ status: SFTPMessage.Status) -> FileTransferError {
        switch status.errorCode {
        case .noSuchFile:
            return .notFound
        case .permissionDenied:
            return .permissionDenied
        case .noConnection, .connectionLost:
            return .notConnected
        default:
            return .failed("\(status.errorCode.debugDescription): \(status.message)")
        }
    }
}
