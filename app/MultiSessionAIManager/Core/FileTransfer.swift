import Foundation

/// A single entry returned by a remote directory listing.
struct RemoteFile: Identifiable, Equatable, Sendable {
    var id: String { path }
    let name: String
    let path: String        // absolute remote path
    let isDirectory: Bool
    let size: Int           // bytes; 0 for dirs
}

struct RemoteDirectoryListing: Equatable, Sendable {
    let path: String
    let entries: [RemoteFile]
}

/// Seam for browsing and transferring files. Folder selection uses SSH exec;
/// file-transfer implementations and tests can also supply directory listings.
protocol FileTransfer: AnyObject, Sendable {
    func listDirectory(_ path: String) async throws -> [RemoteFile]
    /// Return the resolved absolute path along with its children (e.g. for ~).
    func directoryListing(_ path: String) async throws -> RemoteDirectoryListing
    func read(_ path: String) async throws -> Data
    func write(_ data: Data, to path: String) async throws
    /// Release any underlying connection (SFTP/SSH). Idempotent; called on host
    /// exit. Default no-op for transports with nothing to tear down (e.g. fakes).
    func disconnect() async
}

extension FileTransfer {
    func directoryListing(_ path: String) async throws -> RemoteDirectoryListing {
        .init(path: path, entries: try await listDirectory(path))
    }
    func disconnect() async {}
}

enum FileTransferError: Error, Equatable {
    case notFound
    case permissionDenied
    case notConnected
    case failed(String)
}
