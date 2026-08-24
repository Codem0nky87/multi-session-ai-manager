import Foundation
import CryptoKit

enum KeyStoreError: Error {
    case notFound
    case malformedKey
    case unsupportedKeyType
    case encryptedKeyUnsupported
}

/// Manages SSH key material: generates Ed25519 keypairs, persists the private
/// key behind a `KeychainBacking` seam, and exports OpenSSH public keys.
final class KeyStore {
    private let backing: KeychainBacking
    init(backing: KeychainBacking) { self.backing = backing }

    @discardableResult
    func generateEd25519(label: String) throws -> String {
        let key = Curve25519.Signing.PrivateKey()
        let id = "ed25519-\(label)-\(UUID().uuidString)"
        backing.set(key.rawRepresentation, for: id)
        return id
    }

    /// Imports an existing UNENCRYPTED OpenSSH-format ed25519 private key (the
    /// `-----BEGIN OPENSSH PRIVATE KEY-----` PEM text), storing its raw 32-byte
    /// seed so imported and generated keys are indistinguishable to the rest of
    /// the app. Throws for encrypted keys, non-ed25519 keys, or malformed input.
    ///
    /// Parser implemented manually (no Citadel dependency): the unencrypted
    /// OpenSSH private-key format is fully specified and the `string` (4-byte BE
    /// length prefix) convention is the inverse of `OpenSSHPublicKey.encode`,
    /// so a self-contained parser is simpler and lower-risk than reaching for
    /// Citadel's higher-level API to recover the raw seed.
    @discardableResult
    func importOpenSSHEd25519(pem: String, label: String) throws -> String {
        let seed = try Self.parseEd25519Seed(pem: pem)
        // Validate it really is a usable Curve25519 private key.
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let id = "ed25519-\(label)-\(UUID().uuidString)"
        backing.set(key.rawRepresentation, for: id)
        return id
    }

    /// Decodes the 32-byte ed25519 private seed from an unencrypted OpenSSH PEM.
    static func parseEd25519Seed(pem: String) throws -> Data {
        // Strip armor and whitespace, base64-decode the body.
        let body = pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: body) else { throw KeyStoreError.malformedKey }

        var r = ByteReader(data)
        // magic "openssh-key-v1\0"
        let magic = "openssh-key-v1\u{0}"
        guard let header = r.read(magic.utf8.count),
              header == Data(magic.utf8) else { throw KeyStoreError.malformedKey }

        guard let cipher = r.readString(),
              let kdf = r.readString(),
              let _ = r.readString(),          // kdfoptions
              let numKeys = r.readUInt32() else { throw KeyStoreError.malformedKey }

        // Encrypted keys use a cipher/kdf other than "none".
        guard cipher == "none", kdf == "none" else { throw KeyStoreError.encryptedKeyUnsupported }
        guard numKeys == 1 else { throw KeyStoreError.malformedKey }

        guard let _ = r.readBytes(),           // public key blob (binary, not UTF-8)
              let privSection = r.readBytes() else { throw KeyStoreError.malformedKey }

        // Private section (no-op decryption for "none").
        var p = ByteReader(privSection)
        guard let c1 = p.readUInt32(), let c2 = p.readUInt32() else { throw KeyStoreError.malformedKey }
        guard c1 == c2 else { throw KeyStoreError.malformedKey }   // checkint mismatch ⇒ wrong passphrase/corrupt

        guard let keyType = p.readString() else { throw KeyStoreError.malformedKey }
        guard keyType == "ssh-ed25519" else { throw KeyStoreError.unsupportedKeyType }

        guard let _ = p.readBytes(),           // public key (32 bytes)
              let priv = p.readBytes() else { throw KeyStoreError.malformedKey }
        // priv = 32-byte seed || 32-byte public key.
        guard priv.count == 64 else { throw KeyStoreError.malformedKey }
        return priv.prefix(32)
    }

    func allKeyIDs() -> [String] { backing.ids() }

    /// Irreversible: the private key exists only here, so this cannot be undone.
    /// Callers must check `SSHKeyDeletion.canDelete` first -- this deliberately
    /// does not consult hosts, so the rule lives in one testable place rather
    /// than being re-derived at each call site.
    func delete(id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        backing.remove(trimmed)
    }

    /// The raw 32-byte ed25519 seed for `id`, for building `SSHKeyMaterial`.
    /// Throws `.notFound` if no key is stored under `id`.
    func ed25519Seed(id: String) throws -> Data {
        guard let raw = backing.get(id) else { throw KeyStoreError.notFound }
        return raw
    }

    func openSSHPublicKey(id: String, comment: String = "msam") throws -> String {
        guard let raw = backing.get(id) else { throw KeyStoreError.notFound }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        return OpenSSHPublicKey.encode(ed25519Raw: key.publicKey.rawRepresentation, comment: comment)
    }
    // signer(id:) for nio-ssh auth is added in a later task — DO NOT add it now (YAGNI).
}

/// Minimal big-endian reader for the OpenSSH binary key format. `readBytes`/
/// `readString` consume a 4-byte BE length prefix then that many bytes — the
/// inverse of `OpenSSHPublicKey.encode`'s `string()`.
private struct ByteReader {
    private let data: Data
    private var offset: Int
    init(_ data: Data) { self.data = data; self.offset = data.startIndex }

    mutating func read(_ n: Int) -> Data? {
        guard n >= 0, offset + n <= data.endIndex else { return nil }
        let chunk = data.subdata(in: offset..<(offset + n))
        offset += n
        return chunk
    }

    mutating func readUInt32() -> UInt32? {
        guard let d = read(4) else { return nil }
        return d.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readBytes() -> Data? {
        guard let len = readUInt32() else { return nil }
        return read(Int(len))
    }

    mutating func readString() -> String? {
        guard let d = readBytes() else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
