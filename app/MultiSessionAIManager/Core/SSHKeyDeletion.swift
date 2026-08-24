import Foundation

/// Decides whether an SSH key may be deleted.
///
/// Deletion is irreversible -- the private key lives only in the keychain, so
/// removing it cannot be undone and any host still pointing at it can never
/// authenticate again. The rule therefore errs towards refusing.
enum SSHKeyDeletion {

    /// Saved hosts that would be left without a usable key.
    ///
    /// The host currently being edited is excluded: clearing its own selection
    /// is recoverable in the editor (a key is required to save), whereas
    /// breaking a host the user is not looking at is silent.
    static func blockingHosts(keyID: String, hosts: [Host], editedHostID: UUID?) -> [Host] {
        let trimmed = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return hosts.filter { $0.keyID == trimmed && $0.id != editedHostID }
    }

    static func canDelete(keyID: String, hosts: [Host], editedHostID: UUID?) -> Bool {
        !keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && blockingHosts(keyID: keyID, hosts: hosts, editedHostID: editedHostID).isEmpty
    }

    /// Names the hosts standing in the way, so the refusal is actionable rather
    /// than just a "no".
    static func refusalMessage(for hosts: [Host]) -> String {
        let names = hosts.map(\.name).sorted()
        let list = names.joined(separator: ", ")
        return names.count == 1
            ? "\(list) still uses this key. Point it at another key first."
            : "\(list) still use this key. Point them at another key first."
    }

    static let confirmationTitle = "Delete this key?"
    static let confirmationMessage =
        "The private key is removed from this iPad's keychain and cannot be recovered. "
        + "Any host still authorised with it will need a new key installed."
}
