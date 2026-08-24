import Foundation

/// Drives a remote file browser over a `FileTransfer` seam. Navigation/path
/// logic is pure (static helpers) and unit-tested directly; the async methods
/// thread that logic through the transport and publish state for the UI.
@MainActor
@Observable
final class FileBrowserModel {
    private let transfer: FileTransfer
    let root: String

    private(set) var currentPath: String
    private(set) var entries: [RemoteFile] = []
    private(set) var errorMessage: String?

    /// When false (default), dotfiles (names starting with ".") are hidden. The
    /// UI binds this to an eye toggle; flipping it re-filters the already-loaded
    /// `entries` instantly (no reload).
    var showHidden = false

    /// The entries the UI should render: all of `entries` when `showHidden`, else
    /// only the non-dotfiles. `entries` always holds the full loaded listing.
    var visibleEntries: [RemoteFile] { Self.visible(entries, showHidden: showHidden) }

    init(transfer: FileTransfer, root: String) {
        self.transfer = transfer
        self.root = root
        self.currentPath = root
    }

    /// List `currentPath`, sort, and publish. On error, set `errorMessage` and
    /// leave `entries` unchanged.
    func load() async {
        do {
            let listed = try await transfer.listDirectory(currentPath)
            entries = Self.sort(listed)
            errorMessage = nil
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// Enter a directory and load it; files are a no-op here (UI previews).
    func open(_ file: RemoteFile) async {
        guard file.isDirectory else { return }
        currentPath = file.path
        await load()
    }

    /// Go to the parent directory and load it, unless already at root or "/".
    func goUp() async {
        guard currentPath != root, currentPath != "/" else { return }
        currentPath = Self.parent(of: currentPath)
        await load()
    }

    /// Navigate directly to an absolute path (e.g. a breadcrumb) and load it.
    func navigate(to path: String) async {
        currentPath = path
        await load()
    }

    /// Read a file's bytes for preview/export. On error, set `errorMessage` and
    /// return nil.
    func readFile(_ file: RemoteFile) async -> Data? {
        do {
            let data = try await transfer.read(file.path)
            errorMessage = nil
            return data
        } catch {
            errorMessage = Self.describe(error)
            return nil
        }
    }

    /// Upload a local file into `currentPath`, then reload the listing. On
    /// error, set `errorMessage`.
    func upload(localURL: URL) async {
        let name = localURL.lastPathComponent
        let dest = Self.join(currentPath, name)
        do {
            let data = try Data(contentsOf: localURL)
            try await transfer.write(data, to: dest)
            errorMessage = nil
            await load()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    var atRoot: Bool { currentPath == root || currentPath == "/" }

    var breadcrumbs: [(name: String, path: String)] {
        Self.breadcrumbs(for: currentPath)
    }

    // MARK: - Pure helpers

    /// Join a directory and a child name with exactly one separating slash.
    nonisolated static func join(_ dir: String, _ name: String) -> String {
        if dir == "/" { return "/" + name }
        if dir.hasSuffix("/") { return dir + name }
        return dir + "/" + name
    }

    /// Parent directory of an absolute path. "/a/b/c" -> "/a/b", "/a" -> "/",
    /// "/" -> "/".
    nonisolated static func parent(of path: String) -> String {
        var comps = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !comps.isEmpty else { return "/" }
        comps.removeLast()
        if comps.isEmpty { return "/" }
        return "/" + comps.joined(separator: "/")
    }

    /// Filter the loaded entries for display: hide dotfiles (".name") unless
    /// `showHidden`. Pure so the policy is unit-tested directly.
    nonisolated static func visible(_ entries: [RemoteFile], showHidden: Bool) -> [RemoteFile] {
        showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
    }

    /// Directories first, then case-insensitive name.
    nonisolated static func sort(_ files: [RemoteFile]) -> [RemoteFile] {
        files.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Cumulative breadcrumb segments from root. "/a/b" ->
    /// [("/","/"),("a","/a"),("b","/a/b")]; "/" -> [("/","/")].
    nonisolated static func breadcrumbs(for path: String) -> [(name: String, path: String)] {
        var result: [(name: String, path: String)] = [(name: "/", path: "/")]
        var acc = ""
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            acc += "/" + comp
            result.append((name: String(comp), path: acc))
        }
        return result
    }

    nonisolated private static func describe(_ error: Error) -> String {
        switch error {
        case FileTransferError.notFound: return "Not found"
        case FileTransferError.permissionDenied: return "Permission denied"
        case FileTransferError.notConnected: return "Not connected"
        case FileTransferError.failed(let m): return m
        default: return String(describing: error)
        }
    }
}
