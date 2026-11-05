import Foundation

/// Small bundled setup resources travel over SSH exec, even on hosts without
/// SFTP. Single-command upload is used for files <= 64 KiB; files exceeding
/// 64 KiB are uploaded in verified 48 KiB chunks so command line length limits
/// (Linux MAX_ARG_STRLEN 128 KiB) are never exceeded.
enum SSHSetupFileUpload {
    static let chunkSize = 48 * 1024
    static let maximumUploadSize = 10 * 1024 * 1024

    enum Failure: Error, LocalizedError {
        case invalidPath
        case invalidPermissions
        case tooLarge
        case notConfirmed

        var errorDescription: String? {
            switch self {
            case .invalidPath: "The setup file destination is not an absolute file path."
            case .invalidPermissions: "Invalid setup file permissions."
            case .tooLarge: "The setup file exceeds the 10 MB SSH upload limit."
            case .notConfirmed: "The host did not confirm the setup file upload. Check directory permissions and base64 availability."
            }
        }
    }

    static func upload(_ data: Data, to path: String, permissions: UInt16 = 0o600, using transport: SSHTransport) async throws {
        guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("\0") else { throw Failure.invalidPath }
        guard permissions <= 0o777 else { throw Failure.invalidPermissions }
        guard data.count <= maximumUploadSize else { throw Failure.tooLarge }
        try Task.checkCancellation()

        if data.count <= 65_536 {
            let script = """
            set -eu
            PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
            umask 077
            destination=\(POSIXShell.quote(path))
            [ ! -d "$destination" ]
            temporary=$(mktemp "$destination.msam-XXXXXX")
            trap 'rm -f "$temporary"' EXIT HUP INT TERM
            case "$(uname -s)" in Darwin) decode=-D ;; *) decode=-d ;; esac
            printf '%s' '\(data.base64EncodedString())' | base64 "$decode" > "$temporary"
            [ "$(wc -c < "$temporary")" -eq \(data.count) ]
            chmod \(String(permissions, radix: 8)) "$temporary"
            mv -f "$temporary" "$destination"
            printf '\\nMSAM_SETUP_UPLOAD_OK\\n'
            """
            let result = try await transport.runCommand(.init(
                command: "/bin/sh -c \(POSIXShell.quote(script))", timeout: .seconds(30), outputLimit: 4096))
            try Task.checkCancellation()
            guard result.stdoutString.split(separator: "\n").contains("MSAM_SETUP_UPLOAD_OK") else {
                throw Failure.notConfirmed
            }
            return
        }

        // Multi-chunk upload for larger setup files (e.g. msam-metrics.py)
        let destination = POSIXShell.quote(path)
        let temporary = path + ".msam-" + UUID().uuidString
        let staging = POSIXShell.quote(temporary)
        do {
            let initScript = """
            set -eu
            PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
            umask 077
            [ ! -d \(destination) ]
            (set -C; : > \(staging))
            printf '\\nMSAM_SETUP_UPLOAD_OK\\n'
            """
            let initResult = try await transport.runCommand(.init(
                command: "/bin/sh -c \(POSIXShell.quote(initScript))", timeout: .seconds(30), outputLimit: 4096))
            try Task.checkCancellation()
            guard initResult.stdoutString.split(separator: "\n").contains("MSAM_SETUP_UPLOAD_OK") else {
                throw Failure.notConfirmed
            }

            for offset in stride(from: 0, to: data.count, by: chunkSize) {
                try Task.checkCancellation()
                let end = min(offset + chunkSize, data.count)
                let encoded = data.subdata(in: offset..<end).base64EncodedString()
                let chunkScript = """
                set -eu
                PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
                [ ! -L \(staging) ] && [ -f \(staging) ]
                [ "$(wc -c < \(staging))" -eq \(offset) ]
                case "$(uname -s)" in Darwin) decode=-D ;; *) decode=-d ;; esac
                printf '%s' '\(encoded)' | base64 "$decode" >> \(staging)
                [ "$(wc -c < \(staging))" -eq \(end) ]
                printf '\\nMSAM_SETUP_UPLOAD_OK\\n'
                """
                let chunkResult = try await transport.runCommand(.init(
                    command: "/bin/sh -c \(POSIXShell.quote(chunkScript))", timeout: .seconds(30), outputLimit: 4096))
                try Task.checkCancellation()
                guard chunkResult.stdoutString.split(separator: "\n").contains("MSAM_SETUP_UPLOAD_OK") else {
                    throw Failure.notConfirmed
                }
            }

            let finalizeScript = """
            set -eu
            PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
            [ ! -L \(staging) ] && [ -f \(staging) ]
            [ "$(wc -c < \(staging))" -eq \(data.count) ]
            [ ! -d \(destination) ]
            chmod \(String(permissions, radix: 8)) \(staging)
            mv -f \(staging) \(destination)
            printf '\\nMSAM_SETUP_UPLOAD_OK\\n'
            """
            let finalizeResult = try await transport.runCommand(.init(
                command: "/bin/sh -c \(POSIXShell.quote(finalizeScript))", timeout: .seconds(30), outputLimit: 4096))
            try Task.checkCancellation()
            guard finalizeResult.stdoutString.split(separator: "\n").contains("MSAM_SETUP_UPLOAD_OK") else {
                throw Failure.notConfirmed
            }
        } catch {
            let cleanup = Task.detached {
                _ = try? await transport.runCommand(.init(
                    command: "/bin/sh -c \(POSIXShell.quote("rm -f " + staging))",
                    timeout: .seconds(5), outputLimit: 4096))
            }
            await cleanup.value
            throw error
        }
    }
}
