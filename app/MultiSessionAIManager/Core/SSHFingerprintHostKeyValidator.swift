import Foundation
import Crypto
import NIOCore
import NIOSSH

/// Shared SHA256 (base64, unpadded) host-key fingerprint validator. Computes the
/// fingerprint of the server's host key in standard SSH wire format — the same
/// bytes `ssh-keygen -lf` hashes, matching OpenSSH's `SHA256:` form — and defers
/// the accept/reject decision to the seam's `@Sendable (String) -> Bool` closure.
///
/// Used by `NIOSSHTransport`, `CitadelFileTransfer`, and `CitadelKeyInstaller`
/// (previously each carried its own `private` copy). Wrap with
/// `SSHHostKeyValidator.custom(_:)` at the call site.
final class SSHFingerprintHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let accept: @Sendable (String) -> Bool
    init(accept: @escaping @Sendable (String) -> Bool) { self.accept = accept }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        var buffer = ByteBuffer()
        hostKey.write(to: &buffer)
        let digest = SHA256.hash(data: Data(buffer.readableBytesView))
        let fingerprint = Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")   // unpadded, per the seam contract
        if accept(fingerprint) {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(SSHHostKeyRejected())
        }
    }
}

/// Marker error for a fingerprint the seam validator rejected.
struct SSHHostKeyRejected: Error {}
