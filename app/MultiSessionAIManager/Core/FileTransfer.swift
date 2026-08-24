import Foundation

/// A single entry returned by a remote directory listing.
struct RemoteFile: Identifiable, Equatable, Sendable {
    var id: String { path }
    let name: String
    let path: String        // absolute remote path
    let isDirectory: Bool
    let size: Int           // bytes; 0 for dirs
}

/// Seam for reading/writing files on a remote host. Concrete impls: a Citadel
/// SFTP transport (Task 6.2) and `FakeFileTransfer` for tests.
protocol FileTransfer: AnyObject, Sendable {
    func listDirectory(_ path: String) async throws -> [RemoteFile]
    func read(_ path: String) async throws -> Data
    func write(_ data: Data, to path: String) async throws
    /// Release any underlying connection (SFTP/SSH). Idempotent; called on host
    /// exit. Default no-op for transports with nothing to tear down (e.g. fakes).
    func disconnect() async
}

extension FileTransfer {
    func disconnect() async {}
}

enum FileTransferError: Error, Equatable {
    case notFound
    case permissionDenied
    case notConnected
    case failed(String)
}
