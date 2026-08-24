import Foundation

/// In-memory `FileTransfer` for unit tests and previews. Lives in Core so both
/// the test target and app diagnostics can use it.
///
/// Tests drive it on a single (main) actor, but the protocol requires
/// `Sendable`; a lock guards mutable state so it is honestly `@unchecked
/// Sendable`.
final class FakeFileTransfer: FileTransfer, @unchecked Sendable {
    private let lock = NSLock()

    /// directory path -> its children
    var entries: [String: [RemoteFile]] = [:]
    /// file path -> contents
    var fileContents: [String: Data] = [:]
    /// recorded writes, in order
    private(set) var writes: [(path: String, size: Int)] = []

    // Error injection
    var listError: FileTransferError?
    var readError: FileTransferError?
    var writeError: FileTransferError?

    init() {}

    func listDirectory(_ path: String) async throws -> [RemoteFile] {
        try lock.withLock {
            if let listError { throw listError }
            guard let children = entries[path] else { throw FileTransferError.notFound }
            return children
        }
    }

    func read(_ path: String) async throws -> Data {
        try lock.withLock {
            if let readError { throw readError }
            guard let data = fileContents[path] else { throw FileTransferError.notFound }
            return data
        }
    }

    func write(_ data: Data, to path: String) async throws {
        try lock.withLock {
            if let writeError { throw writeError }
            fileContents[path] = data
            writes.append((path: path, size: data.count))
        }
    }
}
