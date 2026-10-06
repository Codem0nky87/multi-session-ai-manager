import Foundation

/// Binary transfers over bounded POSIX SSH exec commands. Each upload uses a
/// private sibling file and publishes it only after all chunks are confirmed.
enum SSHFileTransfer {
    static let chunkSize = 48 * 1024
    static let maximumUploadSize = 100 * 1024 * 1024
    static let maximumDownloadSize = 50 * 1024 * 1024

    private static func validate(_ path: String) throws {
        guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("\0") else {
            throw SSHTransportError.commandFailed("Invalid absolute file path")
        }
    }

    private static func execute(_ script: String, using transport: SSHTransport,
                                outputLimit: Int = 4096) async throws -> Data {
        try Task.checkCancellation()
        let wrapped = "set -eu\nPATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH\n" + script
        let result = try await transport.runCommand(.init(
            command: "/bin/sh -c \(POSIXShell.quote(wrapped))",
            timeout: .seconds(30), outputLimit: outputLimit))
        try Task.checkCancellation()
        let marker = Data("\nMSAM_FILE_OK\n".utf8)
        guard result.exitStatus == 0, result.stdout.suffix(marker.count) == marker else {
            throw SSHTransportError.commandFailed("SSH file transfer failed or was not confirmed. Check file permissions and base64 availability.")
        }
        return result.stdout.dropLast(marker.count)
    }

    static func upload(_ data: Data, to path: String, using transport: SSHTransport) async throws {
        try validate(path)
        guard data.count <= maximumUploadSize else {
            throw SSHTransportError.commandFailed("File exceeds the 100 MB upload limit")
        }
        // The caller chooses the random name so cleanup remains possible even
        // when the creation channel disconnects before returning its output.
        let temporary = path + ".msam-" + UUID().uuidString
        let destination = POSIXShell.quote(path)
        let staging = POSIXShell.quote(temporary)
        do {
            _ = try await execute("""
            umask 077
            [ ! -d \(destination) ]
            (set -C; : > \(staging))
            printf '\\nMSAM_FILE_OK\\n'
            """, using: transport)
            for offset in stride(from: 0, to: data.count, by: chunkSize) {
                let end = min(offset + chunkSize, data.count)
                let encoded = data.subdata(in: offset..<end).base64EncodedString()
                _ = try await execute("""
                [ ! -L \(staging) ] && [ -f \(staging) ]
                [ "$(wc -c < \(staging))" -eq \(offset) ]
                case "$(uname -s)" in Darwin) decode=-D ;; *) decode=-d ;; esac
                printf '%s' '\(encoded)' | base64 "$decode" >> \(staging)
                [ "$(wc -c < \(staging))" -eq \(end) ]
                printf '\\nMSAM_FILE_OK\\n'
                """, using: transport)
            }
            _ = try await execute("""
            [ ! -L \(staging) ] && [ -f \(staging) ]
            [ "$(wc -c < \(staging))" -eq \(data.count) ]
            [ ! -d \(destination) ]
            mv -f \(staging) \(destination)
            printf '\\nMSAM_FILE_OK\\n'
            """, using: transport)
        } catch {
            // Cleanup must still run when the initiating task was cancelled.
            let cleanup = Task.detached {
                _ = try? await transport.runCommand(.init(
                    command: "/bin/sh -c \(POSIXShell.quote("rm -f " + staging))",
                    timeout: .seconds(5), outputLimit: 4096))
            }
            await cleanup.value
            throw error
        }
    }

    static func size(at path: String, using transport: SSHTransport) async throws -> Int {
        try validate(path)
        let quoted = POSIXShell.quote(path)
        let bytes = try await execute("""
        [ -f \(quoted) ] && [ -r \(quoted) ]
        wc -c < \(quoted)
        printf '\\nMSAM_FILE_OK\\n'
        """, using: transport)
        guard let size = Int(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), size >= 0 else {
            throw SSHTransportError.commandFailed("Invalid remote file size")
        }
        return size
    }

    static func download(at path: String, using transport: SSHTransport) async throws -> Data {
        let count = try await size(at: path, using: transport)
        guard count <= maximumDownloadSize else {
            throw SSHTransportError.commandFailed("File exceeds the 50 MB download limit")
        }
        let quoted = POSIXShell.quote(path)
        var data = Data()
        for offset in stride(from: 0, to: count, by: chunkSize) {
            let length = min(chunkSize, count - offset)
            let encoded = try await execute("""
            [ -f \(quoted) ] && [ -r \(quoted) ]
            [ "$(wc -c < \(quoted))" -eq \(count) ]
            dd if=\(quoted) bs=\(chunkSize) skip=\(offset / chunkSize) count=1 2>/dev/null | base64
            printf '\\nMSAM_FILE_OK\\n'
            """, using: transport, outputLimit: chunkSize * 2)
            guard let chunk = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), chunk.count == length else {
                throw SSHTransportError.commandFailed("Incomplete remote file download")
            }
            data.append(chunk)
        }
        return data
    }
}
