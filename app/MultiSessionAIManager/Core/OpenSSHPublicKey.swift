import Foundation

/// Pure encoder for the OpenSSH wire format of an ed25519 public key.
///
/// The public key blob is `string("ssh-ed25519") || string(pubkeyRaw32)`
/// where `string(x)` is a 4-byte big-endian length prefix followed by the
/// bytes. The authorized_keys line is `"ssh-ed25519 " + base64(blob) + " " + comment`.
enum OpenSSHPublicKey {
    static func encode(ed25519Raw pub: Data, comment: String) -> String {
        func string(_ d: Data) -> Data {
            var len = UInt32(d.count).bigEndian
            var out = Data(bytes: &len, count: 4)
            out.append(d)
            return out
        }
        var blob = Data()
        blob.append(string(Data("ssh-ed25519".utf8)))
        blob.append(string(pub))
        let b64 = blob.base64EncodedString()
        return "ssh-ed25519 \(b64) \(comment)"
    }
}
