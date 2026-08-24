import Foundation

/// A file pulled from a host to the iPad.
struct IncomingFile: Equatable, Identifiable {
    /// Absolute path it came from, kept so the sheet can say where it is from.
    let remotePath: String
    let data: Data

    var id: String { remotePath }
    var displayName: String { (remotePath as NSString).lastPathComponent }
    var byteCount: Int { data.count }
    var fileExtension: String { (remotePath as NSString).pathExtension.lowercased() }
}

/// Brings a file the other way: host -> iPad.
///
/// SSH runs iPad->host, so a host can never push. The iPad watches a queue the
/// host appends to and pulls what shows up. The queue is fed by `msam-send`,
/// which the `herdr-file-viewer` plugin invokes as its `open` command -- the
/// plugin hands the selected path to that command as a real argv element and
/// invokes no shell, so nothing here has to defend against quoting.
enum RemoteFileDownload {

    /// Home-relative, matching the upload directory's reasoning: Herdr's active
    /// workspace has a cwd the app cannot see.
    static let outboxRelativePath = ".msam/outbox"

    /// Refused above this. An iPad is not the place for a multi-gigabyte log,
    /// and the whole file is held in memory to be handed to the share sheet.
    static let maximumByteCount = 50 * 1024 * 1024

    /// Follows the queue, reporting only what arrives AFTER the watch starts.
    ///
    /// `-n 0` is what makes this a live feed rather than a replay: without it
    /// every reconnect would re-deliver the whole history. `-F` (follow by name,
    /// retry) survives the file being rotated or recreated underneath it.
    ///
    /// The app never truncates the outbox. Truncation is precisely what would
    /// make `tail -F` decide the file shrank and start over, re-delivering
    /// everything -- and the queue is one path per line, so leaving it to grow
    /// costs nothing worth reclaiming.
    /// Builds the watch command for one tab.
    ///
    /// `identity` must be stable for a given tab ACROSS APP LAUNCHES and unique
    /// between tabs -- the tab's persisted id is exactly that.
    ///
    /// Each watcher records its pid and kills whatever the previous run left
    /// behind under the same identity. That is the whole point: when the app is
    /// force-quit the TCP connection is not closed, so sshd keeps the channel
    /// open and never sends SIGHUP, and an idle `tail` never writes so it never
    /// discovers its reader is gone. The orphan then survives until the TCP
    /// timeout, which can be hours, and every relaunch adds another.
    ///
    /// `$$` is written BEFORE `exec`, which is what makes this exact rather than
    /// a `pkill` pattern hunt: `exec` replaces the shell in place, so the pid
    /// recorded here IS the pid `tail` ends up running under. Scoping the file
    /// per identity keeps a second tab -- or a second device -- from evicting a
    /// watcher that is not its own.
    static func watchCommand(identity: String) -> String {
        let safe = sanitizedIdentity(identity)
        return """
            mkdir -p "$HOME/.msam"
            pidfile="$HOME/.msam/watch-\(safe).pid"
            if [ -f "$pidfile" ]; then kill "$(cat "$pidfile")" 2>/dev/null || true; fi
            : >> "$HOME/.msam/outbox"
            printf '%s' $$ > "$pidfile"
            exec tail -n 0 -F "$HOME/.msam/outbox"
            """
    }

    /// The identity reaches a shell command and a filename, so it is reduced to
    /// characters that need no quoting in either.
    static func sanitizedIdentity(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let cleaned = raw.lowercased().filter { allowed.contains($0) }
        return cleaned.isEmpty ? "default" : String(cleaned.prefix(64))
    }

    enum Failure: Error, Equatable {
        case tooLarge(byteCount: Int)
        case notFound(String)
        case downloadFailed(String)
    }

    /// Splits streamed output into complete lines.
    ///
    /// The watch runs on a PTY, which translates `\n` to `\r\n` and delivers
    /// arbitrary chunks -- a path can and will be split across two reads. This
    /// holds the partial tail until its newline arrives.
    struct LineAccumulator {
        private var buffer = Data()

        mutating func consume(_ data: Data) -> [String] {
            buffer.append(data)
            var lines: [String] = []
            while let index = buffer.firstIndex(of: 0x0A) {
                let raw = buffer[buffer.startIndex..<index]
                buffer = buffer[buffer.index(after: index)...]
                let line = String(decoding: raw, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { lines.append(line) }
            }
            return lines
        }
    }

    /// Only absolute paths are honoured.
    ///
    /// `msam-send` resolves to an absolute path before queueing, so a relative
    /// entry means something else wrote to the outbox. Resolving it here against
    /// a guessed directory would download the wrong file and look like it worked.
    static func isAcceptable(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\n")
    }

    /// Fetch `path`, refusing an oversize file BEFORE reading a byte of it.
    static func download(
        _ path: String,
        using service: SSHService
    ) async throws -> IncomingFile {
        guard isAcceptable(path) else { throw Failure.notFound(path) }

        let size: Int
        do {
            size = try await service.fileSize(at: path)
        } catch {
            throw Failure.notFound(path)
        }
        // Before the read, not after: the point is not to pull the bytes at all.
        guard size <= maximumByteCount else { throw Failure.tooLarge(byteCount: size) }

        do {
            let data = try await service.readFile(at: path)
            return IncomingFile(remotePath: path, data: data)
        } catch {
            throw Failure.downloadFailed("\(error)")
        }
    }
}

/// User-facing wording for a failed download.
enum IncomingFileFailure {
    static func message(for error: Error) -> String {
        guard let failure = error as? RemoteFileDownload.Failure else {
            return "Could not fetch that file: \(error.localizedDescription)"
        }
        switch failure {
        case .tooLarge(let byteCount):
            let mb = Double(byteCount) / 1_048_576
            let limit = RemoteFileDownload.maximumByteCount / 1_048_576
            return String(format: "That file is %.1f MB; the limit is %d MB.", mb, limit)
        case .notFound(let path):
            return "The host queued \(path), but it could not be read."
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        }
    }
}
