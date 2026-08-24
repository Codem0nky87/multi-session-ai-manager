import Testing
import Foundation
@testable import MultiSessionAIManager

@Test func hostStoreRoundTrips() throws {
    // Start from a clean suite so the test is deterministic across repeated runs
    // (UserDefaults suites persist on disk between test invocations).
    UserDefaults().removePersistentDomain(forName: #function)
    let store = HostStore(defaults: UserDefaults(suiteName: #function)!)
    let h = Host(name: "mac", address: "192.0.2.11", port: 22,
                 username: "alice", keyID: "key-1", defaultWorkdir: "/Users/alice/dev")
    store.add(h)
    let store2 = HostStore(defaults: UserDefaults(suiteName: #function)!)
    #expect(store2.hosts.count == 1)
    #expect(store2.hosts.first?.address == "192.0.2.11")
}

/// THE migration test for dropping Cloudflare/Access metadata from the model.
///
/// Hosts saved by an older build carry a `herdr` blob holding the origin, team
/// name, Access audience, allowlist and route preference. Those keys no longer
/// exist on `Host`. A decoder that choked on them — or a `decode` where a
/// `decodeIfPresent` was needed — would empty the user's host list on upgrade,
/// which looks exactly like data loss.
@Test func aHostSavedByTheCloudflareEraBuildStillLoads() throws {
    let id = UUID()
    let json = """
    [{
      "id": "\(id.uuidString)",
      "name": "server-24",
      "address": "192.0.2.24",
      "port": 22,
      "username": "alice",
      "keyID": "key-legacy",
      "defaultWorkdir": "/home/alice",
      "herdr": {
        "origin": "https://herdr.example.com:8443/base",
        "cloudflareTeamName": "acme-team",
        "accessAudienceTag": "aud_123",
        "allowedEmails": ["owner@example.com"],
        "routePreference": "directWARP"
      }
    }]
    """
    UserDefaults().removePersistentDomain(forName: #function)
    let defaults = UserDefaults(suiteName: #function)!
    defaults.set(Data(json.utf8), forKey: "msam.hosts")

    let store = HostStore(defaults: defaults)

    #expect(store.hosts.count == 1)
    let host = try #require(store.hosts.first)
    #expect(host.id == id)
    #expect(host.name == "server-24")
    #expect(host.address == "192.0.2.24")
    #expect(host.username == "alice")
    #expect(host.keyID == "key-legacy")
    #expect(host.defaultWorkdir == "/home/alice")
}

@Test func hostValidationRequiresSSHIdentityAndBoundedPort() {
    let valid = configuredHost()

    var missingName = valid
    missingName.name = "   "
    #expect(throws: Host.ValidationError.missingName) {
        try missingName.validated()
    }

    var missingAddress = valid
    missingAddress.address = "   "
    #expect(throws: Host.ValidationError.missingAddress) {
        try missingAddress.validated()
    }

    var missingUsername = valid
    missingUsername.username = ""
    #expect(throws: Host.ValidationError.missingUsername) {
        try missingUsername.validated()
    }

    var missingKey = valid
    missingKey.keyID = ""
    #expect(throws: Host.ValidationError.missingKey) {
        try missingKey.validated()
    }

    for invalidPort in [0, 65_536] {
        var invalid = valid
        invalid.port = invalidPort
        #expect(throws: Host.ValidationError.invalidPort) {
            try invalid.validated()
        }
    }
}

@Test func aHostNeedsNothingBeyondItsSSHIdentityToBeValid() throws {
    // The Access/Cloudflare metadata used to participate in validation, and its
    // absence must not now make a perfectly good host unsaveable.
    let host = configuredHost()
    #expect(throws: Never.self) { try host.validated() }
}

@Test func encodedHostContainsOnlyReferencesAndNoSecrets() throws {
    let host = configuredHost()
    let data = try JSONEncoder().encode(host)
    let object = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    // The key is a KeyStore/Keychain REFERENCE; private material must never
    // reach UserDefaults.
    #expect(object["keyID"] as? String == host.keyID)
    #expect(Set(object.keys) == [
        "id", "name", "address", "port", "username", "keyID", "defaultWorkdir"
    ])
}

private func configuredHost(
    name: String = "server",
    address: String = "192.0.2.22",
    port: Int = 22,
    username: String = "alice",
    keyID: String = "key-1",
    defaultWorkdir: String = "/home/alice"
) -> Host {
    Host(
        name: name,
        address: address,
        port: port,
        username: username,
        keyID: keyID,
        defaultWorkdir: defaultWorkdir
    )
}
