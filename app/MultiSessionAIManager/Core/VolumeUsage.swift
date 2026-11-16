import Foundation

/// What `msam-disk-usage.py largest-files` found on one volume of a host.
struct VolumeUsageReport: Decodable, Equatable, Sendable {
    struct File: Decodable, Equatable, Identifiable, Sendable {
        let path: String
        /// Space occupied on disk, which for a sparse or compressed file is less
        /// than its length.
        let bytes: Int64

        var id: String { path }

        var name: String {
            guard let cut = lastSeparator else { return path }
            return String(path[path.index(after: cut)...])
        }

        /// The folder the file is in, as a path the user can `cd` to.
        var folder: String {
            guard let cut = lastSeparator else { return "" }
            let folder = String(path[..<cut])
            // "/swapfile" is in "/", and "C:\pagefile.sys" in "C:\", not in "" or "C:".
            if folder.isEmpty || (isWindowsPath && folder.count == 2) { return folder + String(path[cut]) }
            return folder
        }

        /// `C:\…`, `C:/…` or a `\\server\share` path. Only those treat a backslash
        /// as a separator: elsewhere it is a legal character in a file name.
        private var isWindowsPath: Bool {
            if path.hasPrefix("\\\\") { return true }
            let start = Array(path.prefix(3))
            return start.count == 3 && start[0].isLetter && start[1] == ":" && (start[2] == "\\" || start[2] == "/")
        }

        private var lastSeparator: String.Index? {
            isWindowsPath ? path.lastIndex(where: { $0 == "\\" || $0 == "/" }) : path.lastIndex(of: "/")
        }
    }

    let mountPoint: String
    /// Largest first.
    let files: [File]
    let scannedFiles: Int
    /// Folders that could not be listed and entries that could not be examined:
    /// the scan runs as the SSH login, without sudo.
    let unreadable: Int
    /// iCloud or OneDrive placeholders, which occupy no space on this disk.
    let cloudOnly: Int
    /// False when the host stopped at its time limit before seeing every folder.
    let complete: Bool
    let seconds: Double
}

/// Asks a host which files occupy the most space on one of its volumes.
///
/// The walk happens only when asked for, never as part of metrics sampling: it
/// reads every folder of the volume, which takes from seconds to minutes.
enum VolumeUsageScan {
    static let helper = HostHelperScript(resource: "msam-disk-usage.py", folder: "msam-disk-usage",
                                         filename: "disk-usage.py", prefix: "MSAM_DISK_USAGE=")
    static let fileLimit = 20
    /// How long the host walks before it reports what it has found so far.
    static let timeLimit: Duration = .seconds(180)
    /// The helper force-stops itself ten seconds after its limit if a single system
    /// call hangs; the SSH command must still be listening when that answer comes.
    static let commandTimeout: Duration = timeLimit + .seconds(30)

    static func largestFiles(on mountPoint: String, using service: SSHService) async throws -> VolumeUsageReport {
        try await helper.execute(
            VolumeUsageReport.self,
            ["largest-files", mountPoint, "--limit", String(fileLimit),
             "--seconds", String(timeLimit.components.seconds)],
            using: service, timeout: commandTimeout, outputLimit: 512 * 1024,
            missing: "The host did not return a disk usage report.",
            failure: "The disk usage scan failed.")
    }
}

/// The wording of a volume's file list.
enum VolumeUsageFormat {
    /// Binary units, like the volume sizes around it.
    static func size(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1_073_741_824 { return String(format: "%.1f GiB", value / 1_073_741_824) }
        if value >= 1_048_576 { return String(format: "%.0f MiB", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.0f KiB", value / 1024) }
        return "\(bytes) B"
    }

    static func count(_ value: Int) -> String {
        if value >= 1_000_000 {
            let millions = Double(value) / 1_000_000
            return String(format: millions >= 10 ? "%.0fM" : "%.1fM", millions)
        }
        if value >= 1000 { return String(format: "%.0fK", Double(value) / 1000) }
        return "\(value)"
    }

    static func headline(for report: VolumeUsageReport) -> String {
        guard !report.files.isEmpty else { return "No files here that this login can read" }
        return "Largest \(report.files.count) of \(count(report.scannedFiles)) files"
    }

    /// What the list cannot vouch for, most important first.
    static func caveats(for report: VolumeUsageReport) -> [String] {
        var caveats: [String] = []
        if !report.complete {
            caveats.append("The scan ran out of time, so larger files may exist.")
        }
        if report.unreadable == 1 {
            caveats.append("1 folder or file could not be read by this login.")
        } else if report.unreadable > 1 {
            caveats.append("\(report.unreadable) folders or files could not be read by this login.")
        }
        if report.cloudOnly == 1 {
            caveats.append("1 cloud-only item skipped; it uses no space on this disk.")
        } else if report.cloudOnly > 1 {
            caveats.append("\(report.cloudOnly) cloud-only items skipped; they use no space on this disk.")
        }
        return caveats
    }
}
