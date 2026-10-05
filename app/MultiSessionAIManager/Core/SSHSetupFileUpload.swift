import Foundation

/// Small bundled setup resources travel over SSH exec, even on hosts without
/// SFTP. Write a private sibling temporary file, validate its size, then rename
/// it atomically so a failed upload never leaves a partial executable behind.
enum SSHSetupFileUpload {
    enum Failure: Error, LocalizedError {
        case invalidPath
        case tooLarge
        case notConfirmed

        var errorDescription: String? {
            switch self {
            case .invalidPath: "The setup file destination is not an absolute file path."
            case .tooLarge: "The setup file exceeds the 64 KiB SSH upload limit."
            case .notConfirmed: "The host did not confirm the setup file upload. Check directory permissions and base64 availability."
            }
        }
    }

    static func upload(_ data: Data, to path: String, using transport: SSHTransport) async throws {
        guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("\0") else { throw Failure.invalidPath }
        guard data.count <= 65_536 else { throw Failure.tooLarge }
        try Task.checkCancellation()
        let script = """
        set -eu
        PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
        umask 077
        destination=\(POSIXShell.quote(path))
        temporary=$(mktemp "$destination.msam-XXXXXX")
        trap 'rm -f "$temporary"' EXIT HUP INT TERM
        case "$(uname -s)" in Darwin) decode=-D ;; *) decode=-d ;; esac
        printf '%s' '\(data.base64EncodedString())' | base64 "$decode" > "$temporary"
        [ "$(wc -c < "$temporary")" -eq \(data.count) ]
        mv -f "$temporary" "$destination"
        printf '\\nMSAM_SETUP_UPLOAD_OK\\n'
        """
        let result = try await transport.runCommand(.init(
            command: "/bin/sh -c \(POSIXShell.quote(script))", timeout: .seconds(30), outputLimit: 4096))
        try Task.checkCancellation()
        guard result.stdoutString.split(separator: "\n").contains("MSAM_SETUP_UPLOAD_OK") else {
            throw Failure.notConfirmed
        }
    }
}
