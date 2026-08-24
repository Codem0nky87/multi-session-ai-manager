import Testing
import Foundation
@testable import MultiSessionAIManager

// Known-answer: expected base64 computed independently via python3:
//   python3 -c "import struct,base64; pk=bytes(range(32)); \
//     blob=struct.pack('>I',11)+b'ssh-ed25519'+struct.pack('>I',32)+pk; \
//     print(base64.b64encode(blob).decode())"
// => AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f
@Test func knownAnswerLine() {
    let pub = Data(0..<32)
    let expectedB64 = "AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f"
    let line = OpenSSHPublicKey.encode(ed25519Raw: pub, comment: "x")
    #expect(line == "ssh-ed25519 \(expectedB64) x")
}

@Test func lineStructureRoundTrips() throws {
    let pub = Data(0..<32)
    let line = OpenSSHPublicKey.encode(ed25519Raw: pub, comment: "msam")
    let parts = line.split(separator: " ").map(String.init)
    #expect(parts.count == 3)
    #expect(parts[0] == "ssh-ed25519")

    let blob = try #require(Data(base64Encoded: parts[1]))

    // Read string field: 4-byte BE length prefix + bytes.
    func readField(_ data: Data, at offset: Int) -> (Data, Int) {
        let len = data.subdata(in: offset..<offset + 4).reduce(0) { ($0 << 8) | Int($1) }
        let start = offset + 4
        return (data.subdata(in: start..<start + len), start + len)
    }
    let (typeField, next) = readField(blob, at: 0)
    #expect(String(data: typeField, encoding: .utf8) == "ssh-ed25519")
    let (keyField, _) = readField(blob, at: next)
    #expect(keyField == pub)
}
