import Testing
import Foundation
@testable import MultiSessionAIManager

// Fixture generated once with:
//   ssh-keygen -t ed25519 -N "" -C importtest -f /tmp/imp_key
// The public portion below is the `ssh-ed25519 <base64>` field of /tmp/imp_key.pub
// (trailing comment dropped). Importing the private PEM must derive exactly this.
private let importFixturePEM = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACASRLrd2bcMhMKkNo4cJwDdkopfv2npGtylgdF0+v7w7gAAAJBhZJggYWSY
IAAAAAtzc2gtZWQyNTUxOQAAACASRLrd2bcMhMKkNo4cJwDdkopfv2npGtylgdF0+v7w7g
AAAEAPf7e3XKjL8KYrrV+mG1QD/6gi8Cn4j0m/pHUbKtk41xJEut3ZtwyEwqQ2jhwnAN2S
il+/aeka3KWB0XT6/vDuAAAACmltcG9ydHRlc3QBAgM=
-----END OPENSSH PRIVATE KEY-----
"""

private let importFixturePublic =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBJEut3ZtwyEwqQ2jhwnAN2Sil+/aeka3KWB0XT6/vDu"

// Encrypted fixture generated with:
//   ssh-keygen -t ed25519 -N "pass" -C enctest -f /tmp/imp_enc
private let importFixtureEncryptedPEM = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABDIrJjpnZ
7fansayln5fz1IAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIFxOSOqG52nN1mlv
MUTXhwYDIBdmSLoRkEwMAPNpyvejAAAAkGgeIvhJ0x2Gahhy9jCVIkW/HILF4gTaEGaruR
1SM2fy2+ELVt9ITfqUllEFDTRfYIyZUnBs/CV/bKgNSHGQXn1q+sBa2E3OVR2LOcaXqYBO
Aw1x+4LdvpV9SdjypQdoAXDL7ucW/JMEOBJShX9DXGBesKupEUlICdKBKTjmYQ8We3oX5c
cyPw2H/4ByHIzTSw==
-----END OPENSSH PRIVATE KEY-----
"""

@Test func importsExistingEd25519AndDerivesPublicKey() throws {
    let store = KeyStore(backing: InMemoryKeychain())
    let id = try store.importOpenSSHEd25519(pem: importFixturePEM, label: "imported")
    #expect(store.allKeyIDs().contains(id))
    let pub = try store.openSSHPublicKey(id: id)
    // Drop the comment; compare the `ssh-ed25519 <base64>` portion only.
    let portion = pub.split(separator: " ").prefix(2).joined(separator: " ")
    #expect(portion == importFixturePublic)
}

@Test func importGarbageThrows() {
    let store = KeyStore(backing: InMemoryKeychain())
    #expect(throws: KeyStoreError.self) {
        try store.importOpenSSHEd25519(pem: "not a key", label: "x")
    }
}

@Test func importEncryptedKeyThrows() {
    let store = KeyStore(backing: InMemoryKeychain())
    #expect(throws: KeyStoreError.self) {
        try store.importOpenSSHEd25519(pem: importFixtureEncryptedPEM, label: "x")
    }
}
