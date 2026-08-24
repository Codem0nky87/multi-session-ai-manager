import Foundation
import Testing
@testable import MultiSessionAIManager

/// Deleting a key is irreversible — the private half exists only in this iPad's
/// keychain — so the rule errs towards refusing.
@Suite struct SSHKeyDeletionTests {

    private func host(_ name: String, keyID: String, id: UUID = UUID()) -> Host {
        Host(id: id, name: name, address: "10.0.0.1", port: 22,
             username: "alice", keyID: keyID, defaultWorkdir: "/home/alice")
    }

    @Test func anUnusedKeyCanBeDeleted() {
        let hosts = [host("a", keyID: "key-1")]
        #expect(SSHKeyDeletion.canDelete(keyID: "key-2", hosts: hosts, editedHostID: nil))
    }

    @Test func aKeyAnotherHostDependsOnIsRefused() {
        // THE guard: deleting it would leave that host unable to authenticate,
        // with nothing on screen to explain why.
        let hosts = [host("build-server", keyID: "key-1")]
        #expect(!SSHKeyDeletion.canDelete(keyID: "key-1", hosts: hosts, editedHostID: nil))
    }

    @Test func theHostBeingEditedDoesNotBlockItsOwnKey() {
        // Clearing the selection in the editor is recoverable -- a key is
        // required to save -- whereas breaking a host the user is not looking at
        // is silent.
        let id = UUID()
        let hosts = [host("this-one", keyID: "key-1", id: id)]
        #expect(SSHKeyDeletion.canDelete(keyID: "key-1", hosts: hosts, editedHostID: id))
    }

    @Test func anotherHostStillBlocksEvenWhileEditingOne() {
        let edited = UUID()
        let hosts = [host("this-one", keyID: "key-1", id: edited),
                     host("other", keyID: "key-1")]
        #expect(!SSHKeyDeletion.canDelete(keyID: "key-1", hosts: hosts, editedHostID: edited))
    }

    @Test func anEmptySelectionIsNotDeletable() {
        #expect(!SSHKeyDeletion.canDelete(keyID: "", hosts: [], editedHostID: nil))
        #expect(!SSHKeyDeletion.canDelete(keyID: "   ", hosts: [], editedHostID: nil))
    }

    @Test func theRefusalNamesTheHostsInTheWay() {
        // "Cannot delete" without saying what is using it leaves the user to
        // guess, which for an irreversible action is not good enough.
        let one = SSHKeyDeletion.refusalMessage(for: [host("build-server", keyID: "k")])
        #expect(one.contains("build-server"))
        #expect(one.contains("uses this key"))

        let many = SSHKeyDeletion.refusalMessage(
            for: [host("zeta", keyID: "k"), host("alpha", keyID: "k")]
        )
        #expect(many.contains("alpha"))
        #expect(many.contains("zeta"))
        #expect(many.contains("use this key"))
    }

    @Test func theConfirmationSaysItCannotBeUndone() {
        // The private key exists nowhere else, so the wording has to be explicit
        // rather than a generic "are you sure".
        #expect(SSHKeyDeletion.confirmationMessage.localizedCaseInsensitiveContains("cannot be recovered"))
    }
}

@Suite struct KeyStoreDeletionTests {

    @Test func aDeletedKeyIsGoneFromTheStore() throws {
        let store = KeyStore(backing: InMemoryKeychain())
        let keep = try store.generateEd25519(label: "keep")
        let drop = try store.generateEd25519(label: "drop")

        store.delete(id: drop)

        #expect(store.allKeyIDs().contains(keep))
        #expect(!store.allKeyIDs().contains(drop))
    }

    @Test func itsPrivateMaterialIsUnrecoverableAfterwards() throws {
        // Not merely hidden from the list -- the seed itself must be gone.
        let store = KeyStore(backing: InMemoryKeychain())
        let id = try store.generateEd25519(label: "temp")
        store.delete(id: id)

        #expect(throws: (any Error).self) { try store.ed25519Seed(id: id) }
    }

    @Test func deletingSomethingThatIsNotThereIsHarmless() throws {
        let store = KeyStore(backing: InMemoryKeychain())
        let id = try store.generateEd25519(label: "keep")

        store.delete(id: "never-existed")
        store.delete(id: "")

        #expect(store.allKeyIDs() == [id])
    }
}
