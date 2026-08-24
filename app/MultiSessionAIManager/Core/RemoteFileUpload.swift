import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Sends a file from the iPad to a host and hands back the ABSOLUTE remote
/// path, so that path can be typed into a Herdr pane for an agent to read.
///
/// A terminal is a byte stream of text, so nothing but text can be pasted into
/// one. The workable shape is upload-then-reference: the bytes travel over the
/// tab's already-authenticated SSH connection and only the path goes through
/// the PTY. That also happens to be the form agents want -- they take images,
/// PDFs and source files by path.
enum RemoteFileUpload {

    /// Where uploads land, relative to the remote user's home.
    ///
    /// Home-relative rather than the pane's working directory: Herdr's active
    /// workspace has a cwd of its own that this app cannot see, so "next to
    /// whatever the agent is doing" is not a location we can name. A fixed,
    /// predictable directory is also easier to clean up.
    static let relativeDirectory = ".msam/uploads"

    /// One round trip that BOTH creates the directory and reports `$HOME`.
    ///
    /// Fused deliberately: these are two facts we need before writing a byte,
    /// and the link may be crossing a WARP tunnel where each round trip is
    /// tens of milliseconds. `$HOME` is required regardless of the mkdir --
    /// the path typed into the pane must be absolute, because it is resolved
    /// against whatever cwd the agent happens to have.
    static let prepareCommand =
        "mkdir -p \"$HOME/\(relativeDirectory)\" && printf %s \"$HOME\""

    static let prepareTimeout = Duration.seconds(20)
    static let prepareOutputLimit = 4096

    /// Refused above this. An iPad screenshot is 1-3 MB and a long PDF a few
    /// more; this is generous headroom while still catching "the picker handed
    /// us a video". The whole file is held in memory to be written in one SFTP
    /// call, which is the real reason for a ceiling.
    static let maximumByteCount = 25 * 1024 * 1024

    /// Used when a file arrives with no usable extension.
    static let defaultExtension = "bin"
    /// Extensions are truncated to this. Nothing legitimate is longer, and it
    /// bounds what a hostile filename can inject into the generated name.
    static let maximumExtensionLength = 12

    enum Failure: Error, Equatable {
        case emptyFile
        case tooLarge(byteCount: Int)
        case homeUnresolved
        case uploadFailed(String)
    }

    // MARK: - Naming

    /// Lower-cased, alphanumerics only, bounded in length.
    ///
    /// This matters more than it looks: the extension is the ONE part of the
    /// generated filename that comes from user data (a filename chosen in the
    /// Files app), and the finished path is typed into a shell prompt. Reducing
    /// it to `[a-z0-9]` is what keeps `filename(at:fileExtension:)` shell-safe
    /// by construction no matter what the file was called.
    static func sanitizedExtension(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        let cleaned = raw.lowercased().filter { allowed.contains($0) }
        guard !cleaned.isEmpty else { return defaultExtension }
        return String(cleaned.prefix(maximumExtensionLength))
    }

    /// `msam-20260823-134502-118.pdf`.
    ///
    /// Milliseconds, not seconds: two files sent in quick succession must not
    /// land on the same name, and probing the host for a free name would cost a
    /// round trip to solve a problem the clock already solves. UTC so the name
    /// means the same thing on the iPad, this Mac, and a server in another zone.
    ///
    /// The original filename is deliberately NOT preserved -- it is arbitrary
    /// user data being interpolated into a path that gets typed into a shell.
    /// The extension survives (sanitized) because tools dispatch on it.
    static func filename(at date: Date, fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "'msam-'yyyyMMdd-HHmmss-SSS"
        return "\(formatter.string(from: date)).\(sanitizedExtension(fileExtension))"
    }

    /// Join a remote home and a filename into an absolute path.
    static func path(home: String, filename: String) -> String {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return "\(base)/\(relativeDirectory)/\(filename)"
    }

    /// What gets typed into the pane once the upload lands.
    ///
    /// A trailing space and NO newline: the user still has to say what they want
    /// done with the file, and sending Enter would submit a bare path as a
    /// prompt on its own.
    static func paneInsertion(for path: String) -> String {
        path + " "
    }

    // MARK: - Upload

    /// Upload `data` and return the absolute remote path it landed on.
    static func upload(
        _ data: Data,
        fileExtension: String,
        using service: SSHService,
        at date: Date
    ) async throws -> String {
        guard !data.isEmpty else { throw Failure.emptyFile }
        guard data.count <= maximumByteCount else {
            throw Failure.tooLarge(byteCount: data.count)
        }

        let reportedHome: String
        do {
            let result = try await service.run(
                prepareCommand,
                timeout: prepareTimeout,
                outputLimit: prepareOutputLimit
            )
            reportedHome = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw Failure.uploadFailed("could not prepare the upload directory: \(error)")
        }

        // No fallback to "~" or ".": those would write the file somewhere the
        // typed absolute path does not point at, which reads as success and
        // hands the agent a path to nothing.
        guard reportedHome.hasPrefix("/") else { throw Failure.homeUnresolved }

        let target = path(
            home: reportedHome,
            filename: filename(at: date, fileExtension: fileExtension)
        )
        do {
            try await service.writeFile(data, to: target)
        } catch {
            throw Failure.uploadFailed("\(error)")
        }
        return target
    }

    // MARK: - Normalisation

    #if canImport(UIKit)
    /// Re-encode a picked or pasted image as PNG.
    ///
    /// Photos hands back HEIC on modern iPads, which many CLI tools and image
    /// readers on a Linux host cannot open. This applies only to images that
    /// arrived as pixels (clipboard, Photos); a file chosen in Files is uploaded
    /// byte-for-byte under its own extension, because re-encoding someone's
    /// document would be a surprise.
    static func pngData(from image: UIImage) -> Data? {
        image.pngData()
    }
    #endif
}
