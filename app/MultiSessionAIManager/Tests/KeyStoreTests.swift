import Testing
import Foundation
@testable import MultiSessionAIManager

@Test func generatesAndExportsPublicKey() throws {
    let store = KeyStore(backing: InMemoryKeychain())
    let id = try store.generateEd25519(label: "ipad")
    let pub = try store.openSSHPublicKey(id: id)
    #expect(pub.hasPrefix("ssh-ed25519 "))
    #expect(store.allKeyIDs().contains(id))
    // round-trip: generated key's exported pubkey is stable across calls
    #expect(try store.openSSHPublicKey(id: id) == pub)
}

@Test func unknownKeyThrows() {
    let store = KeyStore(backing: InMemoryKeychain())
    #expect(throws: KeyStoreError.self) { try store.openSSHPublicKey(id: "nope") }
}

@Test func ed25519SeedReturnsStored32ByteSeed() throws {
    let store = KeyStore(backing: InMemoryKeychain())
    let id = try store.generateEd25519(label: "ipad")
    let seed = try store.ed25519Seed(id: id)
    #expect(seed.count == 32)
}

@Test func ed25519SeedThrowsForUnknownID() {
    let store = KeyStore(backing: InMemoryKeychain())
    #expect(throws: KeyStoreError.self) { try store.ed25519Seed(id: "nope") }
}
